// The CUDA spellings av1gpu's kernels use, for Metal (Glass Act). Device
// functions port as they are; kernels, thread indices and barriers are
// rewritten by hand where they're used, so they aren't mapped here.
#ifndef GA_CUDA_COMPAT_H
#define GA_CUDA_COMPAT_H

#define __device__
#define __host__
#define __forceinline__ __attribute__((always_inline))

#endif
