///nvcc -o fil main.cu -O3 -m=64 -arch=compute_61 -code=sm_61 -Xptxas -allow-expensive-optimizations=true -Xptxas -v
#include <iostream>
#include <chrono>
#include <fstream>
#include <algorithm>
#include <inttypes.h>
#include <bitset>
#include <iostream>
#include <vector>
#include <map>
#include <iomanip>
#include <fstream>
#include <chrono>
#include <mutex>
#include "lcg.h"
uint64_t millis() {return (std::chrono::duration_cast< std::chrono::milliseconds >(std::chrono::system_clock::now().time_since_epoch())).count();}


#define GPU_ASSERT(code) gpuAssert((code), __FILE__, __LINE__)
inline void gpuAssert(cudaError_t code, const char *file, int line) {
  if (code != cudaSuccess) {
    fprintf(stderr, "GPUassert: %s (code %d) %s %d\n", cudaGetErrorString(code), code, file, line);
    exit(code);
  }
}



// ===== LCG IMPLEMENTATION ===== //

namespace java_lcg { //region Java LCG
    #define Random uint64_t
    #define RANDOM_MULTIPLIER 0x5DEECE66DULL
    #define RANDOM_ADDEND 0xBULL
    #define RANDOM_MASK ((1ULL << 48u) - 1)
    #define get_random(seed) ((Random)((seed ^ RANDOM_MULTIPLIER) & RANDOM_MASK))


    __host__ __device__ __forceinline__ static int32_t random_next(Random *random, int bits) {
        *random = (*random * RANDOM_MULTIPLIER + RANDOM_ADDEND) & RANDOM_MASK;
        return (int32_t) (*random >> (48u - bits));
    }
    __device__ __forceinline__ static int32_t random_next_int(Random *random, const uint16_t bound) {
        int32_t r = random_next(random, 31);
        const uint16_t m = bound - 1u;
        if ((bound & m) == 0) {
            r = (int32_t) ((bound * (uint64_t) r) >> 31u);
        } else {
            for (int32_t u = r;
                 u - (r = u % bound) + m < 0;
                 u = random_next(random, 31));
        }
        return r;
    }
    
    __device__ __host__ __forceinline__ static int32_t random_next_int_nonpow(Random *random, const uint16_t bound) {
        int32_t r = random_next(random, 31);
        const uint16_t m = bound - 1u;
        for (int32_t u = r;
             u - (r = u % bound) + m < 0;
             u = random_next(random, 31));
      return r;
    }
    __host__ __device__ __forceinline__ static double next_double(Random *random) {
        return (double) ((((uint64_t) ((uint32_t) random_next(random, 26)) << 27u)) + random_next(random, 27)) / (double)(1ULL << 53);
    }
    __host__ __device__ __forceinline__ static uint64_t random_next_long (Random *random) {
        return (((uint64_t)random_next(random, 32)) << 32u) + (int32_t)random_next(random, 32);
    }
    __host__ __device__ __forceinline__ static void advance2(Random *random) {
        *random = (*random * 0xBB20B4600A69LLU + 0x40942DE6BALLU) & RANDOM_MASK;
    }
    __host__ __device__ __forceinline__ static void advance3759(Random *random) {
        *random = (*random * 0x6FE85C031F25LLU + 0x8F50ECFF899LLU) & RANDOM_MASK;
    }

}
using namespace java_lcg;


namespace device_intrinsics { //region DEVICE INTRINSICS
    #define DEVICE_STATIC_INTRINSIC_QUALIFIERS  static __device__ __forceinline__

    #if (defined(_MSC_VER) && defined(_WIN64)) || defined(__LP64__)
    #define PXL_GLOBAL_PTR   "l"
    #else
    #define PXL_GLOBAL_PTR   "r"
    #endif

    DEVICE_STATIC_INTRINSIC_QUALIFIERS void __prefetch_local_l1(const void* const ptr)
    {
      asm("prefetch.local.L1 [%0];" : : PXL_GLOBAL_PTR(ptr));
    }

    DEVICE_STATIC_INTRINSIC_QUALIFIERS void __prefetch_global_uniform(const void* const ptr)
    {
      asm("prefetchu.L1 [%0];" : : PXL_GLOBAL_PTR(ptr));
    }

    DEVICE_STATIC_INTRINSIC_QUALIFIERS void __prefetch_local_l2(const void* const ptr)
    {
      asm("prefetch.local.L2 [%0];" : : PXL_GLOBAL_PTR(ptr));
    }

    #if __CUDA__ < 10
    #define __ldg(ptr) (*(ptr))
    #endif
}
using namespace device_intrinsics;






#define BLOCK_SIZE (128)
//#define BLOCK_SIZE (128)
#define WORK_SIZE_BITS 15
#define SEEDS_PER_CALL ((1ULL << (WORK_SIZE_BITS)) * (BLOCK_SIZE))





//Specifying where the (1 = dirt/grass, 0 = sand) is

// This will match the seed 76261196830436 (not pack.png ofc)
#define CHUNK_X 6
#define CHUNK_Z -1

#define INNER_X_START 4
#define INNER_Z_START 0

#define INNER_X_END 13
#define INNER_Z_END 2
__constant__ uint8_t DIRT_HEIGHT_2D[INNER_Z_END - INNER_Z_START + 1][INNER_X_END - INNER_X_START + 1] = {{1,15,15,15,1,15,0,15,15,15},
                                                                                                         {15,1,15,15,15,1,15,1,15,15},
                                                                                                         {15,15,1,1,15,15,1,1,1,0}};
__constant__ double LocalNoise2D[INNER_Z_END - INNER_Z_START + 1][INNER_X_END - INNER_X_START + 1];

#define EARLY_RETURN (INNER_Z_END * 16 + INNER_X_END)

/*
//Old test: matches 104703450999364
#define CHUNK_X 2
#define CHUNK_Z 11

#define INNER_X_START 2
#define INNER_Z_START 0

#define INNER_X_END 11
#define INNER_Z_END 0


__constant__ uint8_t DIRT_HEIGHT_2D[INNER_Z_END - INNER_Z_START + 1][INNER_X_END - INNER_X_START + 1] = {{0,15,0,1,0,15,15,15,15,1}};
__constant__ double LocalNoise2D[INNER_Z_END - INNER_Z_START + 1][INNER_X_END - INNER_X_START + 1];
*/



//The generation of the simplex layers and noise
namespace noise { //region Simplex layer gen
    /* End of constant for simplex noise*/
    
    struct Octave {
        double xo;
        double yo;
        double zo;
        uint8_t permutations[256];
    };

    __shared__ uint8_t permutations[256][BLOCK_SIZE];


    #define getValue(array, index) array[index][threadIdx.x]
    #define setValue(array, index, value) array[index][threadIdx.x] = value


    __device__ static inline void setupNoise(const uint8_t nbOctaves, Random *random, Octave resultArray[]) {
        for (int j = 0; j < nbOctaves; ++j) {
            __prefetch_local_l2(&resultArray[j]);
            resultArray[j].xo = next_double(random) * 256.0;
            resultArray[j].yo = next_double(random) * 256.0;
            resultArray[j].zo = next_double(random) * 256.0;
            
            #pragma unroll
            for(int w = 0; w<256; w++) {
                setValue(permutations, w, w);
            }
            for(int index = 0; index<256; index++) {
                uint32_t randomIndex = random_next_int(random, 256ull - index) + index;
                //if (randomIndex != index) {
                    // swap
                    uint8_t v1 = getValue(permutations,index);
                    //uint8_t v2 = getValue(permutations,randomIndex);
                    setValue(permutations,index, getValue(permutations,randomIndex));
                    setValue(permutations, randomIndex, v1);
                //}
            }
            #pragma unroll
            for(int c = 0; c<256;c++) {
                __prefetch_local_l1(&(resultArray[j].permutations[c+1]));
                resultArray[j].permutations[c] = getValue(permutations,c);
            }
            //resultArray[j].xo = xo;
            //resultArray[j].yo = yo;
            //resultArray[j].zo = zo;
        }
    }
    __device__ static inline void SkipNoiseGen(const uint8_t nbOctaves, Random* random) {
        for (int j = 0; j < nbOctaves; ++j) {
            lcg::advance<2*3>(*random);
            for(int index = 0; index<256; index++) {
                random_next_int(random, 256ull - index);
            }
        }
    }
    
    __device__ static inline double lerp(double x, double a, double b) {
        return a + x * (b - a);
    }

    __device__ static inline double grad(uint8_t hash, double x, double y, double z) {
        switch (hash & 0xFu) {
            case 0x0:
                return x + y;
            case 0x1:
                return -x + y;
            case 0x2:
                return x - y;
            case 0x3:
                return -x - y;
            case 0x4:
                return x + z;
            case 0x5:
                return -x + z;
            case 0x6:
                return x - z;
            case 0x7:
                return -x - z;
            case 0x8:
                return y + z;
            case 0x9:
                return -y + z;
            case 0xA:
                return y - z;
            case 0xB:
                return -y - z;
            case 0xC:
                return y + x;
            case 0xD:
                return -y + z;
            case 0xE:
                return y - x;
            case 0xF:
                return -y - z;
            default:
                return 0; // never happens
        }
    }


    __device__ static inline void generateNormalPermutations(double *buffer, double x, double y, double z, int sizeX, int sizeY, int sizeZ, double noiseFactorX, double noiseFactorY, double noiseFactorZ, double octaveSize, Octave permutationTable) {
        double octaveWidth = 1.0 / octaveSize;
        int32_t i2 = -1;
        double x1 = 0.0;
        double x2 = 0.0;
        double xx1 = 0.0;
        double xx2 = 0.0;
        double t;
        double w;
        int columnIndex = 0;
        for (int X = 0; X < sizeX; X++) {
            double xCoord = (x + (double) X) * noiseFactorX + permutationTable.xo;
            auto clampedXcoord = (int32_t) xCoord;
            if (xCoord < (double) clampedXcoord) {
                clampedXcoord--;
            }
            auto xBottoms = (uint8_t) ((uint32_t) clampedXcoord & 0xffu);
            xCoord -= clampedXcoord;
            t = xCoord * 6 - 15;
            w = (xCoord * t + 10);
            double fadeX = xCoord * xCoord * xCoord * w;
            for (int Z = 0; Z < sizeZ; Z++) {
                double zCoord = permutationTable.zo;
                auto clampedZCoord = (int32_t) zCoord;
                if (zCoord < (double) clampedZCoord) {
                    clampedZCoord--;
                }
                auto zBottoms = (uint8_t) ((uint32_t) clampedZCoord & 0xffu);
                zCoord -= clampedZCoord;
                t = zCoord * 6 - 15;
                w = (zCoord * t + 10);
                double fadeZ = zCoord * zCoord * zCoord * w;
                for (int Y = 0; Y < sizeY; Y++) {
                    double yCoords = (y + (double) Y) * noiseFactorY + permutationTable.yo;
                    auto clampedYCoords = (int32_t) yCoords;
                    if (yCoords < (double) clampedYCoords) {
                        clampedYCoords--;
                    }
                    auto yBottoms = (uint8_t) ((uint32_t) clampedYCoords & 0xffu);
                    yCoords -= clampedYCoords;
                    t = yCoords * 6 - 15;
                    w = yCoords * t + 10;
                    double fadeY = yCoords * yCoords * yCoords * w;
                    // ZCoord

                    if (Y == 0 || yBottoms != i2) { // this is wrong on so many levels, same ybottoms doesnt mean x and z were the same...
                        i2 = yBottoms;

                        uint16_t k2 = permutationTable.permutations[(uint8_t)((uint16_t)(permutationTable.permutations[(uint8_t)(xBottoms& 0xffu)] + yBottoms)& 0xffu)] + zBottoms;
                        uint16_t l2 = permutationTable.permutations[(uint8_t)((uint16_t)(permutationTable.permutations[(uint8_t)(xBottoms& 0xffu)] + yBottoms + 1u )& 0xffu)] + zBottoms;
                        uint16_t k3 = permutationTable.permutations[(uint8_t)((uint16_t)(permutationTable.permutations[(uint8_t)((xBottoms + 1u)& 0xffu)] + yBottoms )& 0xffu)] + zBottoms;
                        uint16_t l3 = permutationTable.permutations[(uint8_t)((uint16_t)(permutationTable.permutations[(uint8_t)((xBottoms + 1u)& 0xffu)] + yBottoms + 1u) & 0xffu)] + zBottoms;
                        x1 = lerp(fadeX, grad(permutationTable.permutations[(uint8_t)(k2& 0xffu)], xCoord, yCoords, zCoord), grad(permutationTable.permutations[(uint8_t)(k3& 0xffu)], xCoord - 1.0, yCoords, zCoord));
                        x2 = lerp(fadeX, grad(permutationTable.permutations[(uint8_t)(l2& 0xffu)], xCoord, yCoords - 1.0, zCoord), grad(permutationTable.permutations[(uint8_t)(l3& 0xffu)], xCoord - 1.0, yCoords - 1.0, zCoord));
                        xx1 = lerp(fadeX, grad(permutationTable.permutations[(uint8_t)((k2+1u)& 0xffu)], xCoord, yCoords, zCoord - 1.0), grad(permutationTable.permutations[(uint8_t)((k3+1u)& 0xffu)], xCoord - 1.0, yCoords, zCoord - 1.0));
                        xx2 = lerp(fadeX, grad(permutationTable.permutations[(uint8_t)((l2+1u)& 0xffu)], xCoord, yCoords - 1.0, zCoord - 1.0), grad(permutationTable.permutations[(uint8_t)((l3+1u)& 0xffu)], xCoord - 1.0, yCoords - 1.0, zCoord - 1.0));
                    }

                    if (columnIndex%16 >= INNER_X_START && columnIndex%16 <= INNER_X_END &&
                        DIRT_HEIGHT_2D[columnIndex/16 - INNER_Z_START][columnIndex%16 - INNER_X_START] != 15){
                        double y1 = lerp(fadeY, x1, x2);
                        double y2 = lerp(fadeY, xx1, xx2);
                        (buffer)[columnIndex] = (buffer)[columnIndex] + lerp(fadeZ, y1, y2) * octaveWidth;
                    }

                    if (columnIndex == EARLY_RETURN) return;
                    
                    columnIndex++;

                }
            }
        }
    }


    __device__ static inline void generateNoise(double *buffer, double chunkX, double chunkY, double chunkZ, int sizeX, int sizeY, int sizeZ, double offsetX, double offsetY, double offsetZ, Octave *permutationTable, int nbOctaves) {
        //memset(buffer, 0, sizeof(double) * sizeX * sizeZ * sizeY);
        double octavesFactor = 1.0;
        for (int octave = 0; octave < nbOctaves; octave++) {
            generateNormalPermutations(buffer, chunkX, chunkY, chunkZ, sizeX, sizeY, sizeZ, offsetX * octavesFactor, offsetY * octavesFactor, offsetZ * octavesFactor, octavesFactor, permutationTable[octave]);
            octavesFactor /= 2.0;
        }
    }
}
using namespace noise;


__device__ static inline bool match(uint64_t seed) {
    seed = get_random(seed);
    //SkipNoiseGen(16+16+8, &seed);
    lcg::advance<10480>(seed);//VERY VERY DODGY
    
    Octave surfaceElevation[4];
    setupNoise(4,(Random*)&seed,surfaceElevation);
    
    double heightField[EARLY_RETURN+1];
    #pragma unroll
    for(uint16_t i = 0; i<EARLY_RETURN+1;i++)
        heightField[i] = 0;
    
    const double noiseFactor = 0.03125;
    generateNoise(heightField, (double) (CHUNK_X <<4), (double) (CHUNK_Z<<4), 0.0, 16, 16, 1, noiseFactor, noiseFactor, 1.0, surfaceElevation, 4);

    for(uint8_t z = 0; z < INNER_Z_END - INNER_Z_START + 1; z++) {
        for(uint8_t x = 0; x < INNER_X_END - INNER_X_START + 1; x++) {
            if (DIRT_HEIGHT_2D[z][x] != 15) {
                uint8_t dirty = heightField[INNER_X_START + x + (INNER_Z_START + z) * 16] + LocalNoise2D[z][x] * 0.2 > 0.0 ? 0 : 1;
                if (dirty!=(int8_t)DIRT_HEIGHT_2D[z][x]) 
                    return false;
            }
        }
    }
    return true;
}


__global__ __launch_bounds__(BLOCK_SIZE,2) static void tempCheck(uint64_t worldSeedOffset, uint32_t count, uint64_t* buffer) {
    uint64_t seedIndex = blockIdx.x * blockDim.x + threadIdx.x + worldSeedOffset;
    if (seedIndex>=count)
        return;
    if (!match(buffer[seedIndex])) {
        buffer[seedIndex] = 0;
    }
}






std::ifstream inSeeds;
std::ofstream outSeeds;

uint64_t* buffer;

double getNextDoubleForLocNoise(int x, int z);
void setup() {
    cudaSetDevice(0);
    GPU_ASSERT(cudaPeekAtLastError());
    GPU_ASSERT(cudaDeviceSynchronize());
    
    double locNoise2D[INNER_Z_END - INNER_Z_START + 1][INNER_X_END - INNER_X_START + 1];
    for(uint8_t z = 0; z < INNER_Z_END - INNER_Z_START + 1; z++) {
        for (uint8_t x = 0; x < INNER_X_END - INNER_X_START + 1; x++) {
            locNoise2D[z][x] = getNextDoubleForLocNoise((CHUNK_X<<4) + INNER_X_START + x, (CHUNK_Z<<4) + INNER_Z_START + z);
        }
    }

    GPU_ASSERT(cudaMemcpyToSymbol(LocalNoise2D, &locNoise2D, sizeof(locNoise2D)));
    GPU_ASSERT(cudaPeekAtLastError());
}

int main2() {
    setup();
    uint64_t seed = 167796511507956LLU;
    GPU_ASSERT(cudaMallocManaged(&buffer, sizeof(*buffer)));
    GPU_ASSERT(cudaPeekAtLastError());
    buffer[0] = seed;
    tempCheck<<<1ULL<<WORK_SIZE_BITS,BLOCK_SIZE>>>(0, 1, buffer);
    GPU_ASSERT(cudaPeekAtLastError());
    GPU_ASSERT(cudaDeviceSynchronize());
}


int main() {
    setup();
    
    inSeeds.open("SandWorldSeeds.txt");
    std::vector<uint64_t> seeds;
    uint64_t curr;
    while (inSeeds >> curr)
        seeds.push_back(curr);
    inSeeds.close();
    
    const uint32_t seedCount = seeds.size();
    std::cout << "Processing " << seedCount << " seeds" << std::endl;
    
    GPU_ASSERT(cudaMallocManaged(&buffer, sizeof(*buffer) * seedCount));
    GPU_ASSERT(cudaPeekAtLastError());
    
    
    for(int i=0;i<seedCount;i++)
        buffer[i]=seeds[i];
    
    
    for(uint64_t offset =0;offset<seedCount;offset+=SEEDS_PER_CALL) {
        tempCheck<<<1ULL<<WORK_SIZE_BITS,BLOCK_SIZE>>>(offset, seedCount, buffer);
        std::cout << "Seeds left:" << seedCount - offset << std::endl;
        GPU_ASSERT(cudaPeekAtLastError());
        GPU_ASSERT(cudaDeviceSynchronize());    
    }   
    std::cout << "Done processing" << std::endl;    
    
    outSeeds.open("seeds_sand_out.txt");
    int outCount = 0;
    for(int i=0;i<seedCount;i++) {
        if (buffer[i]!=0) {
            uint64_t seed = buffer[i];
            //std::cout << "Seed found:" << seed << std::endl;
            outCount++;
            outSeeds << seed << std::endl;
        }
    }
    
    
    std::cout << "Have " << outCount << " output seeds" << std::endl;   
    outSeeds.close();
}









double getNextDoubleForLocNoise(int x, int z) {
    Random rand = get_random((((int64_t)x) >> 4) * 341873128712LL + (((int64_t)z) >> 4) * 132897987541LL);
    for (int dx = 0; dx < 16; dx++) {
      for (int dz = 0; dz < 16; dz++) {
        if (dx == (x & 15) && dz == (z & 15)) {
          //advance2(&rand);
          //advance2(&rand);
          return next_double(&rand);
        }
        advance2(&rand);
        advance2(&rand);
        advance2(&rand);
        for(int k1 = 127; k1 >= 0; k1--) {
          random_next_int_nonpow(&rand,5);
        }
        //for (int i = 0; i < 67; i++) {
        //  advance2(&rand);
        //}
      }
    }
    exit(-99);
}



























