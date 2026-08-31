#ifndef C_AKASHIC_ATOMICS_H
#define C_AKASHIC_ATOMICS_H

#include <stdbool.h>
#include <stdint.h>

typedef struct {
  int64_t value;
} AkashicAtomicInt64;

static inline __attribute__((always_inline)) void
AkashicAtomicInt64Store(AkashicAtomicInt64 *state, int64_t value) {
  __atomic_store_n(&state->value, value, __ATOMIC_RELEASE);
}

static inline __attribute__((always_inline)) int64_t
AkashicAtomicInt64Load(AkashicAtomicInt64 *state) {
  return __atomic_load_n(&state->value, __ATOMIC_ACQUIRE);
}

static inline __attribute__((always_inline)) int64_t
AkashicAtomicInt64TakeUpTo(AkashicAtomicInt64 *state, int64_t amount) {
  if (amount <= 0) {
    return 0;
  }
  int64_t current = __atomic_load_n(&state->value, __ATOMIC_ACQUIRE);
  while (current > 0) {
    const int64_t taken = current < amount ? current : amount;
    const int64_t desired = current - taken;
    if (__atomic_compare_exchange_n(
          &state->value,
          &current,
          desired,
          true,
          __ATOMIC_ACQ_REL,
          __ATOMIC_ACQUIRE)) {
      return taken;
    }
  }
  return 0;
}

static inline __attribute__((always_inline)) void
AkashicAtomicInt64Add(AkashicAtomicInt64 *state, int64_t amount) {
  if (amount <= 0) {
    return;
  }
  (void)__atomic_fetch_add(&state->value, amount, __ATOMIC_ACQ_REL);
}

#endif
