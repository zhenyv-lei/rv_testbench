# BOOM Spectre Testbench

This directory contains BOOM-specific Spectre V1/V2/V4/V5 experiment code.

## Layout

- `env.sh`: BOOM simulator, toolchain, source, and log environment.
- `workloads/spectre-v1/src/spectre-v1.c`: Spectre V1 / bounds-check bypass PoC.
- `workloads/spectre-v2/src/spectre-v2.c`: Spectre V2 / branch-target injection PoC.
- `workloads/spectre-v4/src/spectre-v4.c`: speculative store bypass PoC with
  `asm` and `inline` gadget modes.
- `workloads/spectre-v4/src/spectre-v4-gadget.S`: V4 store-to-load assembly gadget.
- `workloads/spectre-v5/src/spectre-v5.c`: loop/return-predictor PoC.
- `workloads/spectre-v5/src/spectre-v5-gadget.S`: V5 assembly gadgets.
- `workloads/cache-calibration`: cache hit/miss calibration workload.
- `runtime`: minimal bare-metal runtime used by BOOM attack workloads.
- `include` and `link`: shared BOOM helper headers and linker script.
- `scripts/run-spectre-v1-v2-calibrated.sh`: calibrated V1/V2 runner.
- `logs`: generated run logs.
- `build`: generated ELF, object, dump, dependency, and legacy build outputs.

## Smoke

```bash
cd /nfs/home/leizhenyu/opt/testbench/targets/boom
SECRET_SZ=1 ATTACK_SAME_ROUNDS=2 scripts/run-spectre-v1-v2-calibrated.sh all
```

The script first runs the calibration workload, derives `CACHE_HIT_THRESHOLD`,
then rebuilds and runs the BOOM V1/V2 PoCs with that threshold. The attack
secret is `S3CreT`. Current defaults use `ATTACK_SAME_ROUNDS=2`; set
`SECRET_SZ=6` to run the full secret. The PoCs probe only digit/uppercase/
lowercase candidates (`0-9A-Za-z`) to reduce runtime.

## Tune

```bash
cd /nfs/home/leizhenyu/opt/testbench/targets/boom
SECRET_SZ=1 ROUND_CANDIDATES="1 2 3 5 8 10" scripts/tune-spectre-v1-v2.sh all
```

The tuner runs cache hit/miss calibration first, then sweeps
`ATTACK_SAME_ROUNDS` with a one-byte attack and prints the recommended
environment variables for the full `SECRET_SZ=6` run. Current 1-byte tuning on
`SmallBoomV4Config` found `CACHE_HIT_THRESHOLD=50` and
`ATTACK_SAME_ROUNDS=2`.

## Toolchain

Run cache calibration, parameter sweep, repeated attacks, and TSV summary:

```bash
cd /nfs/home/leizhenyu/opt/testbench
TARGETS=boom VARIANTS="v1 v2" \
BOOM_CONFIGS="MediumBoomV3Config MediumBoomV4Config" \
SECRET_SZ=1 ATTACK_REPEATS=3 ROUND_CANDIDATES="1 2 3 5 8 10" \
scripts/toolchain.sh
```

The BOOM summary records `CACHE_HIT_THRESHOLD`, hot/cold averages,
`ATTACK_SAME_ROUNDS`, repeat count, pass count, success rate, and the log glob
for each candidate.

V4/V5 can be included in the BOOM toolchain:

```bash
cd /nfs/home/leizhenyu/opt/testbench
TARGETS=boom VARIANTS="v4 v5" \
BOOM_CONFIGS="MediumBoomV3Config MediumBoomV4Config" \
SECRET_SZ=1 ATTACK_REPEATS=3 \
V4_ROUND_CANDIDATES="asm,1 inline,2 asm,2 inline,4 asm,4" \
V5_PROFILE_CANDIDATES="loop,1,1,16,8 recursive,1,1,1,4 recursive,8,2,2,16" \
scripts/toolchain.sh
```

`V4_ROUND_CANDIDATES` accepts either the legacy `rounds` form or the preferred
`mode,rounds` form. `mode` is `asm` for `spectre-v4-gadget.S` or `inline` for
the inline-assembly gadget in `spectre-v4.c`.

`V5_PROFILE_CANDIDATES` accepts either the legacy
`rounds,train,ras_depth,delay` form or the preferred
`mode,rounds,train,ras_depth,delay` form. `mode` is `loop` for the vusec-style
LoopPredictor gadget or `recursive` for the recursive-ret comparison gadget.

Current `SmallBoomV4Config` 1-byte smoke status:

```bash
cd /nfs/home/leizhenyu/opt/testbench
TARGETS=boom VARIANTS="v4 v5" scripts/run.sh
```

Equivalent direct BOOM commands:

```bash
CONFIG=SmallBoomV4Config SECRET_SZ=1 V4_ROUNDS=1 \
  RUN_TAG=verify-v4-asm scripts/run-workloads.sh v4

CONFIG=SmallBoomV4Config SECRET_SZ=1 V4_GADGET_MODE=inline V4_ROUNDS=2 \
  RUN_TAG=verify-v4-inline scripts/run-workloads.sh v4

CONFIG=SmallBoomV4Config SECRET_SZ=1 \
  V5_GADGET_MODE=loop V5_ROUNDS=1 V5_TRAIN_PASSES=1 \
  V5_RAS_DEPTH=16 V5_IN_PLACE_DELAY=8 \
  RUN_TAG=verify-v5-loop scripts/run-workloads.sh v5
```

Both commands recover `S` as byte 0. The V5 recursive-ret mode executes but did
not recover byte 0 in the minimal smoke profile.
