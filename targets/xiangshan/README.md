# XiangShan Spectre V1/V2 Testbench

This directory packages Spectre V1/V2 PoCs for the local XiangShan
`kunminghu-v2` Verilator simulator.

## Layout

- `workloads/spectre-v1/src/spectre-v1.c`: PoC source derived from `https://github.com/necst/xiangshan-spectre.git`.
- `workloads/spectre-v1-priv/src/spectre-v1-priv.c`: privileged-interface Spectre V1 workload with U-mode attacker, M-mode victim service, and Sv39 page-table isolation.
- `workloads/spectre-v2/src/spectre-v2.c`: experimental indirect-branch PoC adapted for XiangShan.
- `workloads/cache-calibration/src/cache-calibration.c`: standalone cache timing calibration workload.
- `scripts/run-spectre-v1.sh`: build and run Spectre V1 against the local XiangShan DUT.
- `scripts/run-spectre-v1-priv.sh`: build and run the page-table isolated Spectre V1 privileged-interface workload.
- `scripts/run-spectre-v2.sh`: build and run Spectre V2 against the local XiangShan DUT.
- `build/legacy`: build outputs from the pre-normalized layout.
- `logs/`: generated build and run logs.

## Prerequisites

The XiangShan DUT is expected at:

`/nfs/home/leizhenyu/opt/DUTs/XiangShan`

The script uses the existing XiangShan `build/emu`, `scripts/local-env.sh`, and
`third_party/nexus-am` environment.

## Reproduce

```bash
cd /nfs/home/leizhenyu/opt/testbench/targets/xiangshan
SECRET_SZ=6 TIMEOUT=8h scripts/run-spectre-v1.sh
scripts/run-spectre-v1-priv.sh
SECRET_SZ=6 TIMEOUT=8h scripts/run-spectre-v2.sh
```

Both PoCs calibrate the cache-hit threshold at runtime and print a calibration
line in the run log, for example:

```text
[v1] calibration fallback=70 threshold=85
[v2] calibration fallback=70 threshold=95
```

To inspect result lines and thresholds:

```bash
grep -E 'calibration|want\\(|^\\[v[12]\\] check' logs/spectre-v*-run-*.log
```

Current validation status:

- Spectre V1: one-byte smoke run starts, calibrates the threshold, and leaks
  `S` successfully.
- Spectre V1 privileged interface: default three-byte run verifies U-mode direct
  access to the M-mode secret faults, then leaks `S3C` through the M-mode victim
  service side channel.
- Spectre V2: one-byte smoke run starts, calibrates the threshold, and leaks
  `S` successfully.

The attack secret is `S3CreT`. Current defaults use `SECRET_SZ=6`,
`ATTACK_SAME_ROUNDS=2` for V1, and `V2_ATTACK_TRIES=2` for V2. Both PoCs probe
only digit/uppercase/lowercase candidates (`0-9A-Za-z`) to reduce runtime.

## Spectre V1 Privileged Interface

The `spectre-v1-priv` workload models an attacker/victim privilege boundary:

- A is a U-mode attacker.
- B is an M-mode victim service entered through `ecall`.
- The attacker text/data/probe pages are mapped with `PTE_U`.
- The victim secret is placed in a non-`PTE_U` page.
- A direct U-mode load from the secret page must fault before the Spectre run is
  accepted.
- The victim service does not return the secret; the attacker recovers it through
  the cache side channel.

This is a page-table interface-isolation test. It is not a PMP bypass claim; PMP
is left open so the Sv39 page-table permission check is the isolation mechanism.

Build and run:

```bash
cd /nfs/home/leizhenyu/opt/testbench
targets/xiangshan/scripts/run-spectre-v1-priv.sh
```

Run an already-built ELF directly:

```bash
/nfs/home/leizhenyu/opt/DUTs/XiangShan/build/emu \
  --no-diff \
  -i /nfs/home/leizhenyu/opt/testbench/targets/xiangshan/workloads/spectre-v1-priv/build/spectre-v1-priv-riscv64-xs.elf
```

Successful logs include:

```text
[v1-priv] model=page-table-interface A=U B=M pmp=open satp=sv39
[v1-priv] isolation direct_secret_fault=1 direct_secret_completed=0
[v1-priv] check=PASS
```

Useful knobs:

```bash
EARLY_STOP=0 targets/xiangshan/scripts/run-spectre-v1-priv.sh
FULL_BYTE_PROBE=1 targets/xiangshan/scripts/run-spectre-v1-priv.sh
EARLY_STOP_MIN_SCORE=2 EARLY_STOP_GAP=1 targets/xiangshan/scripts/run-spectre-v1-priv.sh
```

Default runs use the faster 62-candidate probe set. `FULL_BYTE_PROBE=1` switches
to the classic full-byte mixed probe order `((i * 167) + 13) & 255`.

## Tune

```bash
cd /nfs/home/leizhenyu/opt/testbench/targets/xiangshan
SECRET_SZ=1 ROUND_CANDIDATES="1 2 3 5" V2_TRY_CANDIDATES="1 2 4 8 16" scripts/tune-spectre-v1-v2.sh all
```

The tuner first runs the standalone `cache-calibration` workload to derive a
cache-hit threshold, then runs one-byte V1/V2 sweeps with
`USE_FIXED_CACHE_HIT_THRESHOLD=1`. It prints the recommended environment
variables for the full `SECRET_SZ=6` run.

Current 1-byte tuning with standalone `cache-calibration` found
`CACHE_HIT_THRESHOLD=82`, `ATTACK_SAME_ROUNDS=2`, and `V2_ATTACK_TRIES=2`.

Verified smoke logs:

- `logs/spectre-v1-run-cal-v1-sz1-r5-t10.log`
- `logs/spectre-v2-run-cal-v2-sz1-tries16-train16-flushfix.log`

These verified logs are from the previous 1-byte smoke configuration. Re-run
the scripts to generate logs for the reduced-round `S3CreT` configuration.

## Toolchain

Run cache calibration, parameter sweep, repeated attacks, and TSV summary:

```bash
cd /nfs/home/leizhenyu/opt/testbench
TARGETS=xiangshan VARIANTS="v1 v2" \
SECRET_SZ=1 ATTACK_REPEATS=3 \
ROUND_CANDIDATES="1 2 3 5" V2_TRY_CANDIDATES="1 2 4 8 16" \
scripts/toolchain.sh
```

The XiangShan summary records `CACHE_HIT_THRESHOLD`, hit/miss averages, the V1
`ATTACK_SAME_ROUNDS` or V2 `V2_ATTACK_TRIES` candidate, repeat count, pass
count, success rate, and the log glob for each candidate.
