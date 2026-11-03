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

#define rintf(x) rint((float)(x))
#define __noinline__  // Metal inlines; k_recon calls rc_luma / rc_chroma once each

// a warp is a SIMD-group: 32 lanes on Apple GPUs
#define __syncwarp() simdgroup_barrier(mem_flags::mem_threadgroup)
#define __syncthreads() threadgroup_barrier(mem_flags::mem_threadgroup | mem_flags::mem_device)


// CUDA's atomics on threadgroup and device integers (Metal's need atomic types: the
// address is reinterpreted, as Metal allows for these). Floats only where the sums are
// exact (integers or quarter-integers), so their order can't change the result.
inline int atomicAdd(threadgroup int *p, int v) {
    return atomic_fetch_add_explicit((threadgroup atomic_int *)p, v, memory_order_relaxed);
}
inline float atomicAdd(threadgroup float *p, float v) {
    return atomic_fetch_add_explicit((threadgroup atomic_float *)p, v, memory_order_relaxed);
}
inline uint atomicAdd(device uint *p, uint v) {
    return atomic_fetch_add_explicit((device atomic_uint *)p, v, memory_order_relaxed);
}
inline int atomicOr(threadgroup int *p, int v) {
    return atomic_fetch_or_explicit((threadgroup atomic_int *)p, v, memory_order_relaxed);
}
inline uint atomicOr(threadgroup uint *p, uint v) {
    return atomic_fetch_or_explicit((threadgroup atomic_uint *)p, v, memory_order_relaxed);
}
inline int atomicMax(threadgroup int *p, int v) {
    return atomic_fetch_max_explicit((threadgroup atomic_int *)p, v, memory_order_relaxed);
}

#endif
