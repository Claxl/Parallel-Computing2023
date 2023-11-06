#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <math.h>
#include <sys/time.h>
#include <cooperative_groups.h>

#include "../inc/argument_utils.h"
using namespace cooperative_groups;

// Convert 'struct timeval' into seconds in double prec. floating point
#define WALLTIME(t) ((double)(t).tv_sec + 1e-6 * (double)(t).tv_usec)

typedef int64_t int_t;
typedef double real_t;

int_t
    M,
    N,
    max_iteration,
    snapshot_frequency;

real_t
    dt,
    *temp,
    *thermal_diffusivity,
    // TODO 1: Declare device side pointers to store host-side data.
    *d_temp,
    *d_thermal_diffusivity;

#define T(x,y)                      temp[(y) * (N + 2) + (x)]
#define THERMAL_DIFFUSIVITY(x,y)    thermal_diffusivity[(y) * (N + 2) + (x)]

#define cudaErrorCheck(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort=true)
{
    if (code != cudaSuccess)
    {
        fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
        if (abort) exit(code);
    }
}

// Namespace name for the cooperative groups namespace, which gives
// classes and methods for thread cooperation in CUDA kernels.
namespace cg = cooperative_groups;

__global__ void time_step ( real_t* temp, real_t* thermal_diffusivity, int_t M, int_t N, real_t dt );

__device__ void boundary_condition ( real_t* temp, int x, int y, int_t M, int_t N );
void domain_init ( void );
void domain_save ( int_t iteration );
void domain_finalize ( void );


int main ( int argc, char **argv ){
    OPTIONS *options = parse_args( argc, argv );
    if ( !options ){
        fprintf( stderr, "Argument parsing failed\n" );
        exit(1);
    }

    M = options->M;
    N = options->N;
    max_iteration = options->max_iteration;
    snapshot_frequency = options->snapshot_frequency;

    domain_init();

    struct timeval t_start, t_end;
    gettimeofday ( &t_start, NULL );

    // Main simulation loop
    for (int_t iteration = 0; iteration <= max_iteration; iteration++)
    {
        // Define the number of threads per block
        dim3 block_size(32, 32);

        // Calculate the number of blocks needed in the grid for both dimensions
        // The grid size accounts for the boundary cells (ghost cells) as well
        dim3 grid_size((N + 2 + block_size.x - 1) / block_size.x,
                    (M + 2 + block_size.y - 1) / block_size.y);

        // Kernel arguments
        void* args[] = {
            &d_temp,
            &d_thermal_diffusivity,
            &N,
            &M,
            &dt
        };

        // Launch the cooperative kernel
        // The time_step function is a __global__ function that will be defined elsewhere in the code
        cudaLaunchCooperativeKernel((void*)time_step, grid_size, block_size, args);

        // Check for errors in kernel launch or execution
        cudaError_t cudaStatus = cudaGetLastError();
        if (cudaStatus != cudaSuccess) {
            fprintf(stderr, "time_step launch failed: %s\n", cudaGetErrorString(cudaStatus));
            break; // If kernel launch failed, exit the loop
        }

        // Synchronize the device to ensure that all threads have completed execution
        cudaStatus = cudaDeviceSynchronize();
        if (cudaStatus != cudaSuccess) {
            fprintf(stderr, "cudaDeviceSynchronize returned error code %d after launching time_step!\n", cudaStatus);
            break;
        }

        // Every snapshot_frequency iterations, copy the data back to the host and save the domain state
        if (iteration % snapshot_frequency == 0)
        {
            printf("Iteration %ld of %ld (%.2lf%% complete)\n",
                iteration,
                max_iteration,
                100.0 * (real_t)iteration / (real_t)max_iteration);

            // Copy data from device memory to host memory
            cudaStatus = cudaMemcpy(temp, d_temp, (M + 2) * (N + 2) * sizeof(real_t), cudaMemcpyDeviceToHost);
            if (cudaStatus != cudaSuccess) {
                fprintf(stderr, "cudaMemcpy Device to Host failed: %s\n", cudaGetErrorString(cudaStatus));
                break;
            }

            // Save the current state of the simulation
            domain_save(iteration);
        }
    }
    // After the loop, you should also handle any cleanup and finalization needed for your application.

    gettimeofday ( &t_end, NULL );
    printf ( "Total elapsed time: %lf seconds\n",
            WALLTIME(t_end) - WALLTIME(t_start)
            );


    domain_finalize();

    exit ( EXIT_SUCCESS );
}

// Determines if a given grid coordinate lies on the boundary of the grid.
// The boundary is defined as the first and last row/column of the grid.
__device__ inline bool in_boundary(int x, int y, int N, int M)
{
    return x == 1 || x == N || y == 1 || y == M;
}

// Checks if the given grid coordinates are outside the valid range.
// A point is considered outside if it lies beyond the grid dimensions, including the ghost cells.
__device__ inline bool outside_grid(int x, int y, int_t N, int_t M)
{
    return x >= (N + 1) || y >= (M + 1) || x == 0 || y == 0;
}

// Determines if a given grid point should be colored black in a red-black ordering scheme.
// In red-black ordering, grid points are colored in a pattern to simplify
// parallel updates.
__device__ inline bool black(int x, int y)
{
    return (x + y) % 2 == 0;
}

// Determines if a given grid point should be colored red.
// This function returns the negation of the 'black' function result.
__device__ inline bool red(int x, int y)
{
    return !black(x, y);
}

__device__ inline void compute_dot(real_t* temp, real_t* thermal_diffusivity, int x, int y, int_t N, int_t M, real_t dt)
{
    // checks first if it is within the grid itself
    if (outside_grid(x, y, N, M)) return;
    // if it is it proceeds with calculations
    real_t c, t, b, l, r, K, A, D, new_value;

    c = T(x, y);

    t = T(x - 1, y);
    b = T(x + 1, y);
    l = T(x, y - 1);
    r = T(x, y + 1);
    K = THERMAL_DIFFUSIVITY(x, y);

    A = - K * dt;
    D = 1.0f + 4.0f * K * dt;
    new_value = (c - A * (t + b + l + r)) / D;

    T(x, y) = new_value;
}

// TODO 4: Make time_step() a cooperative CUDA kernel
//         where one thread is responsible for one grid point.
__global__ void
time_step ( real_t* temp, real_t* thermal_diffusivity, int_t N, int_t M, real_t dt )
{
    int x = blockDim.x * blockIdx.x + threadIdx.x;
    int y = blockDim.y * blockIdx.y + threadIdx.y;

    cg::grid_group grid = cg::this_grid();
    // If it is in the grid values and within the boundary
    // it proceeds to first compute all red and then all black

    if(!outside_grid(x,y,N,M) && in_boundary(x, y, N, M))
    {
        boundary_condition(temp, x, y, N, M);
    }
    if (red(x, y))
    {
        compute_dot(temp, thermal_diffusivity, x, y, N, M, dt);
    }
    grid.sync();
    if (black(x, y))
    {
        compute_dot(temp, thermal_diffusivity, x, y, N, M, dt);
    }

}


// TODO 5: Make boundary_condition() a device function and
//         call it from the time_step-kernel.
//         Chose appropriate threads to set the boundary values.

// Applies boundary conditions to the edges of the simulation grid to ensure
// consistent thermal properties at the grid boundaries. 
__device__ void boundary_condition(real_t* temp, int x, int y, int_t M, int_t N)
{
    // If we're at the left boundary, set the ghost cell to the left (x=0)
    // to the value of the cell to the right of the boundary (x=2)
    if (x == 1)
        T(0, y) = T(2, y);

    // If we're at the right boundary, set the ghost cell to the right (x=N+1)
    // to the value of the cell to the left of the boundary (x=N-1)
    if (x == N)
        T(N + 1, y) = T(N - 1, y);

    // If we're at the top boundary, set the ghost cell above (y=0)
    // to the value of the cell below the boundary (y=2)
    if (y == 1)
        T(x, 0) = T(x, 2);

    // If we're at the bottom boundary, set the ghost cell below (y=M+1)
    // to the value of the cell above the boundary (y=M-1)
    if (y == M)
        T(x, M + 1) = T(x, M - 1);
}


void
domain_init ( void )
{
    int malloc_size = (M+2)*(N+2) * sizeof(real_t);
    temp = (real_t*) malloc ( malloc_size );
    thermal_diffusivity = (real_t*) malloc ( malloc_size );

    // TODO 2: Allocate device memory.
    cudaMalloc((void**) &d_temp, malloc_size);
    cudaMalloc((void**) &d_thermal_diffusivity, malloc_size);

    dt = 0.1;

    for ( int_t y = 1; y <= M; y++ )
    {
        for ( int_t x = 1; x <= N; x++ )
        {
            real_t temperature = 30 + 30 * sin((x + y) / 20.0);
            real_t diffusivity = 0.05 + (30 + 30 * sin((N - x + y) / 20.0)) / 605.0;

            T(x,y) = temperature;
            THERMAL_DIFFUSIVITY(x,y) = diffusivity;
        }
    }

    // TODO 3: Copy data from host to device.
    cudaMemcpy((void*) d_temp, (void*) temp, malloc_size, cudaMemcpyHostToDevice);
    cudaMemcpy((void*) d_thermal_diffusivity, (void*) thermal_diffusivity, malloc_size, cudaMemcpyHostToDevice);
}


void
domain_save ( int_t iteration )
{
    int_t index = iteration / snapshot_frequency;
    char filename[256];
    memset ( filename, 0, 256*sizeof(char) );
    sprintf ( filename, "data/%.5ld.bin", index );

    FILE *out = fopen ( filename, "wb" );
    if ( ! out )
    {
        fprintf(stderr, "Failed to open file: %s\n", filename);
        exit(1);
    }
    fwrite( temp, sizeof(real_t), (N + 2) * (M + 2), out );
    fclose ( out );
}


void
domain_finalize ( void )
{
    free ( temp );
    free ( thermal_diffusivity );

    // TODO 8: Free device memory.
    cudaFree(d_temp);
    cudaFree(d_thermal_diffusivity);
}
