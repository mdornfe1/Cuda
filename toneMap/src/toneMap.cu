#include <iostream>
#include "timer.h"
#include "utils.h"
#include "loadSaveImage.h"
#include <string>
#include <stdio.h>
#include <math.h>
#include <assert.h>

//chroma-LogLuminance Spaces
static float *d_x__;
static float *d_y__;
static float *d_logY__;

//memory for the cdf
static unsigned int *d_cdf__;

static const int numBins = 1024;

size_t numRows__;
size_t numCols__;

__global__ void rgb_to_xyY(
    float* d_r,
    float* d_g,
    float* d_b,
    float* d_x,
    float* d_y,
    float* d_log_Y,
    float  delta,
    int    num_pixels_y,
    int    num_pixels_x )
{
  int  ny             = num_pixels_y;
  int  nx             = num_pixels_x;
  int2 image_index_2d = make_int2( ( blockIdx.x * blockDim.x ) + threadIdx.x, ( blockIdx.y * blockDim.y ) + threadIdx.y );
  int  image_index_1d = ( nx * image_index_2d.y ) + image_index_2d.x;

  if ( image_index_2d.x < nx && image_index_2d.y < ny )
  {
    float r = d_r[ image_index_1d ];
    float g = d_g[ image_index_1d ];
    float b = d_b[ image_index_1d ];

    float X = ( r * 0.4124f ) + ( g * 0.3576f ) + ( b * 0.1805f );
    float Y = ( r * 0.2126f ) + ( g * 0.7152f ) + ( b * 0.0722f );
    float Z = ( r * 0.0193f ) + ( g * 0.1192f ) + ( b * 0.9505f );

    float L = X + Y + Z;
    float x = X / L;
    float y = Y / L;

    float log_Y = log10f( delta + Y );

    d_x[ image_index_1d ]     = x;
    d_y[ image_index_1d ]     = y;
    d_log_Y[ image_index_1d ] = log_Y;
  }
}

/* Copied from Mike's IPython notebook *
   Modified just by having threads read the
   normalization constant directly from device memory
   instead of copying it back                          */


__global__ void normalize_cdf(
    unsigned int* d_input_cdf,
    float*        d_output_cdf,
    int           n
    )
{
  const float normalization_constant = 1.f / d_input_cdf[n - 1];

  int global_index_1d = ( blockIdx.x * blockDim.x ) + threadIdx.x;

  if ( global_index_1d < n )
  {
    unsigned int input_value  = d_input_cdf[ global_index_1d ];
    float        output_value = input_value * normalization_constant;

    d_output_cdf[ global_index_1d ] = output_value;
  }
}


/* Copied from Mike's IPython notebook *
   Modified double constants -> float  *
   Perform tone mapping based upon new *
   luminance scaling                   */

__global__ void tonemap(
    float* d_x,
    float* d_y,
    float* d_log_Y,
    float* d_cdf_norm,
    float* d_r_new,
    float* d_g_new,
    float* d_b_new,
    float  min_log_Y,
    float  max_log_Y,
    float  log_Y_range,
    int    num_bins,
    int    num_pixels_y,
    int    num_pixels_x )
{
  int  ny             = num_pixels_y;
  int  nx             = num_pixels_x;
  int2 image_index_2d = make_int2( ( blockIdx.x * blockDim.x ) + threadIdx.x, ( blockIdx.y * blockDim.y ) + threadIdx.y );
  int  image_index_1d = ( nx * image_index_2d.y ) + image_index_2d.x;

  if ( image_index_2d.x < nx && image_index_2d.y < ny )
  {
    float x         = d_x[ image_index_1d ];
    float y         = d_y[ image_index_1d ];
    float log_Y     = d_log_Y[ image_index_1d ];
    int   bin_index = min( num_bins - 1, int( (num_bins * ( log_Y - min_log_Y ) ) / log_Y_range ) );
    float Y_new     = d_cdf_norm[ bin_index ];

    float X_new = x * ( Y_new / y );
    float Z_new = ( 1 - x - y ) * ( Y_new / y );

    float r_new = ( X_new *  3.2406f ) + ( Y_new * -1.5372f ) + ( Z_new * -0.4986f );
    float g_new = ( X_new * -0.9689f ) + ( Y_new *  1.8758f ) + ( Z_new *  0.0415f );
    float b_new = ( X_new *  0.0557f ) + ( Y_new * -0.2040f ) + ( Z_new *  1.0570f );

    d_r_new[ image_index_1d ] = r_new;
    d_g_new[ image_index_1d ] = g_new;
    d_b_new[ image_index_1d ] = b_new;
  }
}

//return types are void since any internal error will be handled by quitting
//no point in returning error codes...
void preProcess(float** d_luminance, unsigned int** d_cdf,
                size_t *numRows, size_t *numCols,
                unsigned int *numberOfBins,
                const std::string &filename) {
  //make sure the context initializes ok
  checkCudaErrors(cudaFree(0));

  float *imgPtr; //we will become responsible for this pointer
  loadImageHDR(filename, &imgPtr, &numRows__, &numCols__);
  *numRows = numRows__;
  *numCols = numCols__;

  //first thing to do is split incoming BGR float data into separate channels
  size_t numPixels = numRows__ * numCols__;
  float *red   = new float[numPixels];
  float *green = new float[numPixels];
  float *blue  = new float[numPixels];

  //Remeber image is loaded BGR
  for (size_t i = 0; i < numPixels; ++i) {
    blue[i]  = imgPtr[3 * i + 0];
    green[i] = imgPtr[3 * i + 1];
    red[i]   = imgPtr[3 * i + 2];
  }

  delete[] imgPtr; //being good citizens are releasing resources
                   //allocated in loadImageHDR

  float *d_red, *d_green, *d_blue;  //RGB space

  size_t channelSize = sizeof(float) * numPixels;

  checkCudaErrors(cudaMalloc(&d_red,    channelSize));
  checkCudaErrors(cudaMalloc(&d_green,  channelSize));
  checkCudaErrors(cudaMalloc(&d_blue,   channelSize));
  checkCudaErrors(cudaMalloc(&d_x__,    channelSize));
  checkCudaErrors(cudaMalloc(&d_y__,    channelSize));
  checkCudaErrors(cudaMalloc(&d_logY__, channelSize));

  checkCudaErrors(cudaMemcpy(d_red,   red,   channelSize, cudaMemcpyHostToDevice));
  checkCudaErrors(cudaMemcpy(d_green, green, channelSize, cudaMemcpyHostToDevice));
  checkCudaErrors(cudaMemcpy(d_blue,  blue,  channelSize, cudaMemcpyHostToDevice));

  //convert from RGB space to chrominance/luminance space xyY
  const dim3 blockSize(32, 16, 1);
  const dim3 gridSize( (numCols__ + blockSize.x - 1) / blockSize.x,
                       (numRows__ + blockSize.y - 1) / blockSize.y, 1);
  rgb_to_xyY<<<gridSize, blockSize>>>(d_red, d_green, d_blue,
                                      d_x__, d_y__,   d_logY__,
                                      .0001f, numRows__, numCols__);

  cudaDeviceSynchronize(); checkCudaErrors(cudaGetLastError());

  *d_luminance = d_logY__;

  //allocate memory for the cdf of the histogram
  *numberOfBins = numBins;
  checkCudaErrors(cudaMalloc(&d_cdf__, sizeof(unsigned int) * numBins));
  checkCudaErrors(cudaMemset(d_cdf__, 0, sizeof(unsigned int) * numBins));

  *d_cdf = d_cdf__;

  checkCudaErrors(cudaFree(d_red));
  checkCudaErrors(cudaFree(d_green));
  checkCudaErrors(cudaFree(d_blue));

  delete[] red;
  delete[] green;
  delete[] blue;
}

void postProcess(const std::string& output_file,
                 size_t numRows, size_t numCols,
                 float min_log_Y, float max_log_Y) {
  const int numPixels = numRows__ * numCols__;

  const int numThreads = 192;

  float *d_cdf_normalized;

  checkCudaErrors(cudaMalloc(&d_cdf_normalized, sizeof(float) * numBins));

  //first normalize the cdf to a maximum value of 1
  //this is how we compress the range of the luminance channel
  normalize_cdf<<< (numBins + numThreads - 1) / numThreads,
                    numThreads>>>(d_cdf__,
                                  d_cdf_normalized,
                                  numBins);

  cudaDeviceSynchronize(); checkCudaErrors(cudaGetLastError());

  //allocate memory for the output RGB channels
  float *h_red, *h_green, *h_blue;
  float *d_red, *d_green, *d_blue;

  h_red   = new float[numPixels];
  h_green = new float[numPixels];
  h_blue  = new float[numPixels];

  checkCudaErrors(cudaMalloc(&d_red,   sizeof(float) * numPixels));
  checkCudaErrors(cudaMalloc(&d_green, sizeof(float) * numPixels));
  checkCudaErrors(cudaMalloc(&d_blue,  sizeof(float) * numPixels));

  float log_Y_range = max_log_Y - min_log_Y;

  const dim3 blockSize(32, 16, 1);
  const dim3 gridSize( (numCols + blockSize.x - 1) / blockSize.x,
                       (numRows + blockSize.y - 1) / blockSize.y );
  //next perform the actual tone-mapping
  //we map each luminance value to its new value
  //and then transform back to RGB space
  tonemap<<<gridSize, blockSize>>>(d_x__, d_y__, d_logY__,
                                   d_cdf_normalized,
                                   d_red, d_green, d_blue,
                                   min_log_Y, max_log_Y,
                                   log_Y_range, numBins,
                                   numRows, numCols);

  cudaDeviceSynchronize(); checkCudaErrors(cudaGetLastError());

  checkCudaErrors(cudaMemcpy(h_red,   d_red,   sizeof(float) * numPixels, cudaMemcpyDeviceToHost));
  checkCudaErrors(cudaMemcpy(h_green, d_green, sizeof(float) * numPixels, cudaMemcpyDeviceToHost));
  checkCudaErrors(cudaMemcpy(h_blue,  d_blue,  sizeof(float) * numPixels, cudaMemcpyDeviceToHost));

  //recombine the image channels
  float *imageHDR = new float[numPixels * 3];

  for (int i = 0; i < numPixels; ++i) {
    imageHDR[3 * i + 0] = h_blue[i];
    imageHDR[3 * i + 1] = h_green[i];
    imageHDR[3 * i + 2] = h_red[i];
  }

  saveImageHDR(imageHDR, numRows, numCols, output_file);

  delete[] imageHDR;
  delete[] h_red;
  delete[] h_green;
  delete[] h_blue;

  //cleanup
  checkCudaErrors(cudaFree(d_x__));
  checkCudaErrors(cudaFree(d_y__));
  checkCudaErrors(cudaFree(d_logY__));
  checkCudaErrors(cudaFree(d_cdf__));
  checkCudaErrors(cudaFree(d_cdf_normalized));
}

__global__ void block_min(const float* const d_logLuminance,
                          float* d_extrema,
                          const size_t num_elements)
{
  extern __shared__ float sdata[];

  unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;

  // load input into __shared__ memory
  float x = 0;
  if(i < num_elements)
  {
    x = d_logLuminance[i];
  }
  sdata[threadIdx.x] = x;
  __syncthreads();

  // Do reduction on data loaded into shared mem
  for(int offset = blockDim.x / 2; offset > 0; offset >>= 1) {
    if(threadIdx.x < offset)
    {
      // compute min of data[thread] and data[thread+offset]_
      sdata[threadIdx.x] = min(sdata[threadIdx.x], sdata[threadIdx.x + offset]);
    }

    // wait until all threads in the block have
    // updated their partial sums
    __syncthreads();
  }

  // thread 0 writes the final result
  if(threadIdx.x == 0)
  {
    d_extrema[blockIdx.x] = sdata[0];
  }
}

__global__ void block_max(const float* const d_logLuminance,
                          float* d_extrema,
                          const size_t num_elements)
{
  extern __shared__ float sdata[];

  unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;

  // load input into __shared__ memory
  float x = 0;
  if(i < num_elements)
  {
    x = d_logLuminance[i];
  }
  sdata[threadIdx.x] = x;
  __syncthreads();

  // Do reduction on data loaded into shared mem
  for(int s = blockDim.x / 2; s > 0; s >>= 1) {
    if(threadIdx.x < s)
    {
    	// compute max of data[thread] and data[thread+offset]_
      sdata[threadIdx.x] = max(sdata[threadIdx.x], sdata[threadIdx.x + s]);
    }

    // wait until all threads in the block have
    // updated their partial sums
    __syncthreads();

  }

  // thread 0 writes the final result
  if(threadIdx.x == 0)
  {
    d_extrema[blockIdx.x] = sdata[0];
  }
}

//calculate_histo<<<gridSize, blockSize>>>(d_min, d_logLuminance, d_histogram, lumRange, numBins);
__global__
void calculate_histo(const float* const d_logLuminance,
					unsigned int* d_histogram,
					float min_logLum,
					float lumRange,
					int numBins,
					int num_elements){
	extern __shared__ float sdata[];
	int tid = threadIdx.x;
    int bid = blockIdx.x;
    int gid = tid * blockDim.x + bid;

    // load input into __shared__ memory
	if(gid < num_elements)
	{
		sdata[tid] = d_logLuminance[gid];
		__syncthreads();

		//compute bin value of input
		int bin = static_cast <int> (floor((sdata[tid]-min_logLum)/ lumRange * numBins)); //replace with sdat
		//increment histogram at bin value
		atomicAdd(&(d_histogram[bin]), 1);
	}
}

__global__
void blelloch_scan(unsigned int* const d_cdf, unsigned int* d_histogram, int numBins) {
	extern __shared__ unsigned int sdata2[];// allocated on invocation
	int thid = threadIdx.x;
	//printf("%i \n", thid);
	//printf("%i \n", d_histogram[thid]);

	int offset = 1;


	sdata2[2*thid] = d_histogram[2*thid]; // load input into shared memory
	sdata2[2*thid+1] = d_histogram[2*thid+1];

	// build sum in place up the tree
	for (int d = numBins>>1; d > 0; d >>= 1) {
		__syncthreads();
		if (thid < d) {
			int ai = offset*(2*thid+1)-1;
			int bi = offset*(2*thid+2)-1;
			sdata2[bi] += sdata2[ai];
		}
		offset *= 2;
	}
	if (thid == 0) { sdata2[numBins - 1] = 0; } // clear the last element
	// traverse down tree & build scan
	for (int d = 1; d < numBins; d *= 2) {
		offset >>= 1;
		printf("%d \n", offset);
		__syncthreads();
		if (thid < d) {
			int ai = offset*(2*thid+1)-1;
			int bi = offset*(2*thid+2)-1;
			//printf("%s %d %s %d \n", "ai=",ai,",   bi=",bi);
			float t = sdata2[ai];
			sdata2[ai] = sdata2[bi];
			sdata2[bi] += t;
		}
	__syncthreads();
	d_cdf[2*thid] = sdata2[2*thid]; // write results to device memory
	d_cdf[2*thid+1] = sdata2[2*thid+1];
	}

}

void your_histogram_and_prefixsum(const float* const d_logLuminance,
                                  unsigned int* const d_cdf,
                                  float &min_logLum,
                                  float &max_logLum,
                                  const size_t numRows,
                                  const size_t numCols,
                                  const size_t numBins)
{
	const int max_num_blocks = 384; //max for nvidia quadro k2000m
	const dim3 blockSize(1, numCols, 1);
	const dim3 gridSize(numRows, 1, 1);

	//copy d_logLuminance into d_min and d_max
	//after calculate_minmax is called the results will be in d_min[0] and d_max[0]
	unsigned int* d_histogram;
	unsigned int* h_histogram;
	unsigned int* h_cdf;

	const int num_elements = numRows * numCols;
	const size_t block_size = 1024;
	const size_t num_blocks = (num_elements/block_size) + ((num_elements%block_size) ? 1 : 0);
	assert(num_blocks <= max_num_blocks);

	//Each instance of the min, and max kernels will load a portion of the data into shared memory equal to block_size
	//The will then compute the min and max of each portion and save it to d_extrema.
	//The program will then launch one more kernel and compute the min/max of the elements in d_extrema
	//and save it to last position in d_extrema
	float *d_extrema;
	checkCudaErrors(cudaMalloc((void**)&d_extrema, sizeof(float) * (num_blocks + 1)));

	// launch one kernel to compute, per-block min
	block_min<<<num_blocks,block_size,block_size * sizeof(float)>>>(d_logLuminance, d_extrema, num_elements);

	// launch a single block to compute the min of all per-block mins
	block_min<<<1,num_blocks,num_blocks * sizeof(float)>>>(d_extrema, d_extrema + num_blocks, num_blocks);

	cudaDeviceSynchronize(); checkCudaErrors(cudaGetLastError());

	checkCudaErrors(cudaMemcpy(&min_logLum, d_extrema + num_blocks, sizeof(float), cudaMemcpyDeviceToHost));

	// launch one kernel to compute, per-block max
	block_max<<<num_blocks,block_size,block_size * sizeof(float)>>>(d_logLuminance, d_extrema, num_elements);

	// launch a single block to compute the max of all per-block maxs
	block_max<<<1,num_blocks,num_blocks * sizeof(float)>>>(d_extrema, d_extrema + num_blocks, num_blocks);

	cudaDeviceSynchronize(); checkCudaErrors(cudaGetLastError());

	checkCudaErrors(cudaMemcpy(&max_logLum, d_extrema + num_blocks, sizeof(float), cudaMemcpyDeviceToHost));

	//std::cout << min_logLum << "\n" << max_logLum << "\n";


	h_histogram = (unsigned int*) malloc(sizeof(unsigned int) * numBins);
	h_cdf = (unsigned int*) malloc(sizeof(unsigned int) * numBins);

	checkCudaErrors(cudaMalloc(&d_histogram, sizeof(unsigned int) * numBins));
	checkCudaErrors(cudaMemset(d_histogram, 0, sizeof(unsigned int) * numBins));
	float lumRange = max_logLum - min_logLum;

	calculate_histo<<<num_blocks, block_size, block_size * sizeof(float)>>>(d_logLuminance, d_histogram, min_logLum, lumRange, numBins, num_elements);


	cudaDeviceSynchronize(); checkCudaErrors(cudaGetLastError());


	checkCudaErrors(cudaMemcpy(h_histogram, d_histogram, sizeof(unsigned int) * numBins, cudaMemcpyDeviceToHost));

	/*
	for (int i = 0 ; i < numBins ; i++){
		std::cout << *(h_histogram+i) << "\n";
	}
	*/
	std::cout << numBins << "\n";
	blelloch_scan<<<1, numBins/2, sizeof(unsigned int) * numBins>>>(d_cdf, d_histogram, numBins);

	cudaDeviceSynchronize(); checkCudaErrors(cudaGetLastError());

	checkCudaErrors(cudaMemcpy(h_cdf, d_cdf, sizeof(unsigned int)* numBins, cudaMemcpyDeviceToHost));

	checkCudaErrors(cudaFree(d_histogram)); //free up histogram



	/*
	for (int i = 0 ; i < numBins; i++){
		std::cout << *(h_cdf+i) << "\n";
	}
	*/

	//TODO
  /*Here are the steps you need to implement
    1) find the minimum and maximum value in the input logLuminance channel
       store in min_logLum and max_logLum...check
    2) subtract them to find the range...check
    3) generate a histogram of all the values in the logLuminance channel using
       the formula: bin = (lum[i] - lumMin) / lumRange * numBins
    4) Perform an exclusive scan (prefix sum) on the histogram to get
       the cumulative distribution of luminance values (this should go in the
       incoming d_cdf pointer which already has been allocated for you)       */
}



int main(int argc, char **argv) {
  float *d_luminance;
  unsigned int *d_cdf;

  size_t numRows, numCols;
  unsigned int numBins;

  std::string input_file;
  std::string output_file;
  if (argc == 3) {
    input_file  = std::string(argv[1]);
    output_file = std::string(argv[2]);
  }
  else {
    std::cerr << "Usage: ./hw input_file output_file" << std::endl;
    exit(1);
  }
  //load the image and give us our input and output pointers
  preProcess(&d_luminance, &d_cdf,
             &numRows, &numCols, &numBins, input_file);

  GpuTimer timer;

  float min_logLum, max_logLum;

  min_logLum = 0.f;
  max_logLum = 1.f;
  timer.Start();
  //call the students' code
  your_histogram_and_prefixsum(d_luminance, d_cdf, min_logLum, max_logLum,
                               numRows, numCols, numBins);
  timer.Stop();
  cudaDeviceSynchronize(); checkCudaErrors(cudaGetLastError());
  int err = printf("%f msecs.\n", timer.Elapsed());

  if (err < 0) {
    //Couldn't print! Probably the student closed stdout - bad news
    std::cerr << "Couldn't print timing information! STDOUT Closed!" << std::endl;
    exit(1);
  }

  //check results and output the tone-mapped image
  postProcess(output_file, numRows, numCols, min_logLum, max_logLum);

  return 0;
}
