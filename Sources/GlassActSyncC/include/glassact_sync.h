// C11 atomics on a 64-bit word, for GlassActSync's Atomic: Swift's own
// (Synchronization) needs macOS 15, and the Host runs on 14.4. Static inline,
// so each call compiles to the same single instruction Swift's Atomic emits.
#ifndef GLASSACT_SYNC_H
#define GLASSACT_SYNC_H

#include <stdatomic.h>
#include <stdint.h>

#define GA_WORD(p) ((_Atomic(int64_t) *)(p))

static inline int64_t ga_atomic_load_relaxed(int64_t *p) {
    return atomic_load_explicit(GA_WORD(p), memory_order_relaxed);
}
static inline int64_t ga_atomic_load_seq_cst(int64_t *p) {
    return atomic_load_explicit(GA_WORD(p), memory_order_seq_cst);
}
static inline void ga_atomic_store_relaxed(int64_t *p, int64_t v) {
    atomic_store_explicit(GA_WORD(p), v, memory_order_relaxed);
}
static inline void ga_atomic_store_seq_cst(int64_t *p, int64_t v) {
    atomic_store_explicit(GA_WORD(p), v, memory_order_seq_cst);
}
// The value before the add (fetch-and-add, wrapping like Swift's &+).
static inline int64_t ga_atomic_fetch_add_relaxed(int64_t *p, int64_t v) {
    return atomic_fetch_add_explicit(GA_WORD(p), v, memory_order_relaxed);
}
static inline int64_t ga_atomic_fetch_add_seq_cst(int64_t *p, int64_t v) {
    return atomic_fetch_add_explicit(GA_WORD(p), v, memory_order_seq_cst);
}

#undef GA_WORD
#endif
