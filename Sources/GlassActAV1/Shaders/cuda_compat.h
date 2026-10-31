// The CUDA spellings av1gpu's kernels use, for Metal (Glass Act). Device
// functions port as they are; kernels, thread indices and threadgroup memory
// are rewritten by hand where they're used, so they aren't mapped here.
#ifndef GA_CUDA_COMPAT_H
#define GA_CUDA_COMPAT_H

#define __device__
#define __host__
#define __forceinline__ __attribute__((always_inline))

// read-only loads (a cache hint on NVIDIA; Metal decides by address space)
#define __ldg(p) (*(p))
#define __clz(x) ((int)clz((uint)(x)))
#define fmaf(a, b, c) fma((float)(a), (float)(b), (float)(c))
#define fabsf(x) fabs((float)(x))
#define fmaxf(a, b) fmax((float)(a), (float)(b))
#define fminf(a, b) fmin((float)(a), (float)(b))
#define __expf(x) exp((float)(x))
#define sqrtf(x) sqrt((float)(x))
#define log2f(x) log2((float)(x))

// a warp is a SIMD-group: 32 lanes on Apple GPUs
#define __syncwarp() simdgroup_barrier(mem_flags::mem_threadgroup)
#define __syncthreads() threadgroup_barrier(mem_flags::mem_threadgroup | mem_flags::mem_device)

#endif
