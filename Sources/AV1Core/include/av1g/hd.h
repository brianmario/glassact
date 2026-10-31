/* av1g/hd.h - host/device portability macros shared by all av1core headers.
 *
 * AV1G_HD      marks functions callable from both host and CUDA device code.
 * AV1G_TABLE   defines a constant lookup table twice when compiled by nvcc: a host
 *              copy (name_host) and a device copy (name_dev).  Plain C/C++ builds
 *              only get the host copy.
 * AV1G_T(n)    selects the right copy at the use site (device pass vs host pass).
 * AV1G_CONST   the address space of a pointer into those tables: Metal keeps them in
 *              `constant`, which no other pointer converts to or from (Glass Act).
 *
 * Glass Act: the Metal branch (__METAL_VERSION__) is added; the rest is av1gpu's.
 * In MSL 4.1 an unqualified pointer is generic, like CUDA's: thread, threadgroup and
 * device pointers all convert to it, so the shared functions compile as they are.
 * `constant` doesn't, so a pointer to a table that is kept, returned or passed says
 * AV1G_CONST.
 */
#ifndef AV1G_HD_H
#define AV1G_HD_H

#if defined(__CUDACC__)
#define AV1G_HD __host__ __device__ __forceinline__
#define AV1G_HDI __host__ __device__ inline
#define AV1G_TABLE(T, name, dims, ...)                 \
    static const T name##_host dims = __VA_ARGS__;     \
    static __device__ const T name##_dev dims = __VA_ARGS__;
#elif defined(__METAL_VERSION__)
#define AV1G_HD static inline
#define AV1G_HDI static inline
/* stored flat, read through av1g_view (below) */
#define AV1G_TABLE(T, name, dims, ...)   \
    typedef T name##_elem;               \
    typedef T name##_shape dims;         \
    constant T name##_dev[sizeof(name##_shape) / sizeof(T)] = __VA_ARGS__;
#else
#define AV1G_HD static inline
#define AV1G_HDI static inline
#define AV1G_TABLE(T, name, dims, ...) static const T name##_host dims = __VA_ARGS__;
#endif

#if defined(__METAL_VERSION__)
#define AV1G_CONST constant
#else
#define AV1G_CONST
#endif

#if defined(__METAL_VERSION__)
/* Metal miscompiles some reads of multi-dimensional `constant` arrays whose rows aren't a
 * multiple of 4 bytes, which is most CDF tables (uint16_t rows of 3, 5, 11 entries): with
 * two runtime index terms, T[x][z][0][0] of a uint16_t [4][5][13][3] table reads element
 * 191 for x = 1, not 195 (macOS 27.2, M4 Pro, MSL 3.2 to 4.1, every optimization level).
 * Flat tables, int elements, padded rows and device memory all read correctly.  So Metal
 * keeps each table flat, and AV1G_T() is a view that indexes it with 1-D pointer
 * arithmetic only, and converts to a `constant` pointer where code takes a (sub-)table's
 * address.  DSPEquivalenceTests catches it (the CDF defaults are among these tables). */
template <typename T, typename A> struct av1g_view;
template <typename T, size_t N> struct av1g_view<T, T[N]> {
    constant const T *p;
    constant const T &operator[](int i) const { return p[i]; }
    operator constant const T *() const { return p; }
};
template <typename T, typename E, size_t N> struct av1g_view<T, E[N]> {
    constant const T *p;
    av1g_view<T, E> operator[](int i) const { return av1g_view<T, E>{p + i * (int)(sizeof(E) / sizeof(T))}; }
    operator constant const T *() const { return p; }
};
#define AV1G_T(name) (av1g_view<name##_elem, name##_shape>{name##_dev})
#elif defined(__CUDA_ARCH__)
#define AV1G_T(name) name##_dev
#else
#define AV1G_T(name) name##_host
#endif

#endif
