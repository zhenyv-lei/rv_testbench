# Spectre V1/V2 Calibrated Testbench

This testbench runs calibrated Spectre V1/V2 smoke tests on BOOM and
XiangShan. Attack code is organized by target processor.

## Layout

- `targets/boom/`: BOOM env, scripts, workloads, generated build output, and logs.
- `targets/xiangshan/`: XiangShan env, scripts, workloads, generated build output, and logs.
- `targets/*/workloads/spectre-v1/src/spectre-v1.c`: target-specific Spectre V1 source.
- `targets/*/workloads/spectre-v2/src/spectre-v2.c`: target-specific Spectre V2 source.
- `targets/*/workloads/cache-calibration/src/`: target-specific cache timing calibration source.
- `scripts/`: top-level runners that dispatch to targets.
- `artifacts/logs/legacy/`: historical logs from the pre-normalized layout.

## Entrypoints

```bash
scripts/toolchain.sh
scripts/run.sh
scripts/run-spectre-v1-v2-calibrated.sh
scripts/run-boom-v4-v5-asm.sh
```

Full calibration-and-attack workflow:

```bash
TARGETS=boom VARIANTS="v1 v2" \
BOOM_CONFIGS="MediumBoomV3Config MediumBoomV4Config" \
SECRET_SZ=1 ATTACK_REPEATS=3 ROUND_CANDIDATES="1 2 3 5 8 10" \
scripts/toolchain.sh

TARGETS=xiangshan VARIANTS="v1 v2" \
SECRET_SZ=1 ATTACK_REPEATS=3 \
ROUND_CANDIDATES="1 2 3 5" V2_TRY_CANDIDATES="1 2 4 8 16" \
scripts/toolchain.sh
```

`scripts/toolchain.sh` runs two phases:

1. Cache hit/miss calibration. It builds and runs the target's
   `cache-calibration` workload, derives `CACHE_HIT_THRESHOLD`, and records
   hit/miss averages.
2. Spectre attack sweep. It runs Spectre V1/V2 with candidate parameters,
   repeats each candidate `ATTACK_REPEATS` times, and writes a TSV summary with
   pass count and success-rate percentage.

BOOM defaults to `BOOM_CONFIGS="MediumBoomV3Config MediumBoomV4Config"`.
BOOM supports `VARIANTS="v1 v2 v4 v5"` in `scripts/toolchain.sh`.
For direct smoke runs, `scripts/run.sh` also supports BOOM V4/V5:

```bash
TARGETS=boom VARIANTS="v4 v5" scripts/run.sh
```

XiangShan uses the local `targets/xiangshan/env.sh` simulator setting.

Useful environment controls:

- `ATTACK_REPEATS`: repetitions per parameter candidate, default `3`.
- `MIN_SUCCESS_PCT`: acceptance threshold, default `100`.
- `STOP_ON_ACCEPT`: stop sweeping a variant once a candidate is accepted,
  default `1`.
- `SUMMARY_TSV`: optional explicit summary output path.
- `TOOLCHAIN_TAG`: optional log/summary tag for reproducible filenames.
- `V4_ROUND_CANDIDATES`: BOOM V4 round sweep, default `1 2 4 8 16 32 64 128`.
- `V5_PROFILE_CANDIDATES`: BOOM V5 profile sweep as
  `mode,V5_ROUNDS,V5_TRAIN_PASSES,V5_RAS_DEPTH,V5_IN_PLACE_DELAY` tuples.
  The legacy 4-field form is still accepted and maps to `recursive`.

BOOM V4/V5 use C harnesses with assembly gadgets. The current verified
`SmallBoomV4Config` smoke settings are:

```bash
cd targets/boom
CONFIG=SmallBoomV4Config SECRET_SZ=1 V4_ROUNDS=1 \
  RUN_TAG=verify-v4-asm scripts/run-workloads.sh v4

CONFIG=SmallBoomV4Config SECRET_SZ=1 \
  V5_GADGET_MODE=loop V5_ROUNDS=1 V5_TRAIN_PASSES=1 \
  V5_RAS_DEPTH=16 V5_IN_PLACE_DELAY=8 \
  RUN_TAG=verify-v5-loop scripts/run-workloads.sh v5
```

The V5 `recursive` gadget is retained for comparison, but the verified leak
uses the vusec-style loop-predictor gadget.

The summary TSV columns are:

```text
target config variant threshold hit_or_hot_avg miss_or_cold_avg param_name param_value repeats passes success_rate_pct accepted elapsed_s log_glob
```

Useful selectors:

```bash
TARGETS=boom VARIANTS="v1 v2" scripts/run.sh
TARGETS=xiangshan VARIANTS="v1 v2" scripts/run.sh
```

Parameter tuning:

```bash
TARGETS=boom VARIANTS="v1 v2" SECRET_SZ=1 scripts/tune.sh
TARGETS=xiangshan VARIANTS="v1 v2" SECRET_SZ=1 scripts/tune.sh
```

The tuning scripts first run a cache hit/miss calibration, derive a
`CACHE_HIT_THRESHOLD`, then sweep short 1-byte attacks to find the smallest
passing `ATTACK_SAME_ROUNDS` or `V2_ATTACK_TRIES`. They print recommended
environment variables for the full `SECRET_SZ=6` run.

The default smoke setting is `SECRET_SZ=1` for the top-level runner. Set
`SECRET_SZ=6` for the full current test secret. The attack sources use
`S3CreT` and probe only digit/uppercase/lowercase candidates (`0-9A-Za-z`) to
reduce runtime.

## Calibration

- BOOM runs `cache-calibration-smoke.riscv`, parses `[cal] hot/cold` lines, and
  passes the derived `CACHE_HIT_THRESHOLD` into the BOOM V1/V2 PoCs.
- XiangShan V1/V2 calibrate the threshold inside the guest program by default.
  For tuning, `USE_FIXED_CACHE_HIT_THRESHOLD=1` makes the attack use the
  threshold derived from the standalone `cache-calibration` workload.

## Verified Smoke Logs

- BOOM V1: `artifacts/logs/legacy/boom-calibrated-v1-rerun/SmallBoomV4Config-condBranchMispred-secret1-rounds10.log`
- BOOM V2: `artifacts/logs/legacy/boom-calibrated-v2-rerun/SmallBoomV4Config-indirBranchMispred-secret1-rounds10.log`
- XiangShan V1: `targets/xiangshan/logs/spectre-v1-run-cal-v1-sz1-r5-t10.log`
- XiangShan V2: `targets/xiangshan/logs/spectre-v2-run-cal-v2-sz1-tries16-train16-flushfix.log`

These verified logs are from the previous 1-byte smoke configuration. Re-run
the scripts to generate logs for the reduced-round `S3CreT` configuration.

BOOM V4/V5 are experimental. The current minimal smoke profiles compile and
execute on `SmallBoomV4Config`, but do not yet recover `S`:

- V4 minimal profile recovers the overwrite byte `#`.
- V5 minimal profile currently reports no cache hit for byte 0.
