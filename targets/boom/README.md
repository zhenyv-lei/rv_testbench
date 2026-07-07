# BOOM Spectre Testbench

This directory contains BOOM-specific Spectre V1/V2 experiment code.

## Layout

- `env.sh`: BOOM simulator, toolchain, source, and log environment.
- `workloads/spectre-v1/src/spectre-v1.c`: Spectre V1 / bounds-check bypass PoC.
- `workloads/spectre-v2/src/spectre-v2.c`: Spectre V2 / branch-target injection PoC.
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
