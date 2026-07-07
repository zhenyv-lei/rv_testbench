# BOOM V4 Inline Gadget Validation

Date: 2026-07-07

This records the first repeated validation sweep for the Spectre V4 inline
assembly gadget in `workloads/spectre-v4/src/spectre-v4.c`.

Command:

```bash
TARGETS=boom VARIANTS=v4 \
BOOM_CONFIGS=SmallBoomV4Config \
SECRET_SZ=1 ATTACK_REPEATS=3 STOP_ON_ACCEPT=0 MIN_SUCCESS_PCT=100 \
V4_ROUND_CANDIDATES="inline,1 inline,2 inline,4" \
TOOLCHAIN_TAG=v4-inline-sweep-r1-r2-r4 \
TIMEOUT=10m MAX_CYCLES=3000000000 \
scripts/toolchain.sh
```

Calibration:

| Config | Threshold | Hot Avg | Cold Avg | Calibration Time |
| --- | ---: | ---: | ---: | ---: |
| `SmallBoomV4Config` | 50 | 34.00 | 64.00 | 30 s |

Attack sweep:

| V4 Profile | Repeats | Passes | Success Rate | Candidate Time | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| `inline,1` | 3 | 0 | 0% | 433 s | unstable, `#` wins tie |
| `inline,2` | 3 | 3 | 100% | 787 s | recommended |
| `inline,4` | 3 | 3 | 100% | 1481 s | slower, higher score margin |

Total wall time reported by `/usr/bin/time -p`: 2731.21 s.

The `inline,2` profile is the current default recommendation for 1-byte V4
inline smoke runs because it reaches 3/3 success with much lower cost than
`inline,4`. The `inline,4` profile produced a slightly larger score gap
(`S=3`, overwrite `#=2` in the observed runs), but took about 1.9x longer than
`inline,2`.
