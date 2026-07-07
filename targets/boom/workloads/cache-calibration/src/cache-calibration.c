#include <stdio.h>
#include <stdint.h>

#include "rv64_spectre.h"

#ifndef CALIBRATION_ROUNDS
#define CALIBRATION_ROUNDS 8
#endif

int main(void)
{
  if (spectre_runtime_init() != 0)
    return 1;

  uint8_t *probe = (uint8_t *)spectre_alloc_aligned(PROBE_BYTES, L1_BLOCK_SZ_BYTES);
  if (probe == NULL)
    return 1;

  probe_init(probe);

  printf("[cal] entries=%u stride=%u eviction_multiplier=%u\n",
         (unsigned)PROBE_ENTRIES,
         (unsigned)PROBE_STRIDE,
         (unsigned)EVICTION_MULTIPLIER);

  for (unsigned int i = 0; i < CALIBRATION_ROUNDS; ++i)
  {
    volatile uint8_t *hot = &probe[0];
    volatile uint8_t *cold = &probe[PROBE_STRIDE];

    rv64_sink ^= *hot;
    const uint64_t hot_time = probe_time(hot);
    flush_line((const void *)cold);
    const uint64_t cold_time = probe_time(cold);

    printf("[cal] round %u hot=%lu cold=%lu\n",
           i,
           (unsigned long)hot_time,
           (unsigned long)cold_time);
  }

  return 0;
}
