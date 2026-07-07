# Three-Goal Validation Record

Date: 2026-07-07

This document records the sequential validation requested for BOOM, XiangShan,
and later Meltdown-style RISC-V experiments.

## Goal 1: Spectre V1/V2

Scope:

- BOOM v3: `MediumBoomV3Config`
- BOOM v4: `MediumBoomV4Config`
- XiangShan v2: local `/nfs/home/leizhenyu/opt/DUTs/XiangShan/build/emu`

### BOOM V1/V2

Initial command:

```bash
TARGETS=boom VARIANTS="v1 v2" \
BOOM_CONFIGS="MediumBoomV3Config MediumBoomV4Config" \
SECRET_SZ=1 ATTACK_REPEATS=1 STOP_ON_ACCEPT=0 MIN_SUCCESS_PCT=100 \
ROUND_CANDIDATES=2 TOOLCHAIN_TAG=goal1-boom-v1v2 \
TIMEOUT=30m MAX_CYCLES=3000000000 \
scripts/toolchain.sh
```

Wall time reported by `/usr/bin/time -p`: 457.09 s.

| Target | Variant | Threshold | Parameter | Result | Attack Time |
| --- | --- | ---: | --- | --- | ---: |
| `MediumBoomV3Config` | Spectre V1 | 48 | `ATTACK_SAME_ROUNDS=2` | PASS | 48 s |
| `MediumBoomV3Config` | Spectre V2 | 48 | `ATTACK_SAME_ROUNDS=2` | FAIL | 50 s |
| `MediumBoomV4Config` | Spectre V1 | 50 | `ATTACK_SAME_ROUNDS=2` | FAIL | 155 s |
| `MediumBoomV4Config` | Spectre V2 | 50 | `ATTACK_SAME_ROUNDS=2` | PASS | 155 s |

Additional BOOM tuning:

```bash
TARGETS=boom VARIANTS=v2 BOOM_CONFIGS=MediumBoomV3Config \
SECRET_SZ=1 ATTACK_REPEATS=1 STOP_ON_ACCEPT=1 MIN_SUCCESS_PCT=100 \
ROUND_CANDIDATES="3 5 8 10" TOOLCHAIN_TAG=goal1-boom-v3-v2-tune \
TIMEOUT=30m MAX_CYCLES=3000000000 \
scripts/toolchain.sh
```

`MediumBoomV3Config` Spectre V2 passed with `ATTACK_SAME_ROUNDS=3`; the attack
candidate took 72 s, and the full tuning command took 86.90 s.

```bash
TARGETS=boom VARIANTS=v1 BOOM_CONFIGS=MediumBoomV4Config \
SECRET_SZ=1 ATTACK_REPEATS=1 STOP_ON_ACCEPT=1 MIN_SUCCESS_PCT=100 \
ROUND_CANDIDATES="3 5 8 10" TOOLCHAIN_TAG=goal1-boom-v4-v1-tune \
TIMEOUT=30m MAX_CYCLES=3000000000 \
scripts/toolchain.sh
```

`MediumBoomV4Config` Spectre V1 did not pass with rounds 3, 5, 8, or 10:

| Parameter | Result | Attack Time |
| --- | --- | ---: |
| `ATTACK_SAME_ROUNDS=3` | FAIL | 220 s |
| `ATTACK_SAME_ROUNDS=5` | FAIL | 354 s |
| `ATTACK_SAME_ROUNDS=8` | FAIL | 554 s |
| `ATTACK_SAME_ROUNDS=10` | FAIL | 689 s |

Full V4 V1 tuning command wall time: 1852.03 s.

### XiangShan V2 V1/V2

Command:

```bash
TARGETS=xiangshan VARIANTS="v1 v2" \
SECRET_SZ=1 ATTACK_REPEATS=1 STOP_ON_ACCEPT=1 MIN_SUCCESS_PCT=100 \
ROUND_CANDIDATES=2 V2_TRY_CANDIDATES=2 \
TOOLCHAIN_TAG=goal1-xs-v1v2 \
TIMEOUT=8h CAL_TIMEOUT=10m \
scripts/toolchain.sh
```

The first sandboxed attempt failed because the XiangShan build writes under
`/nfs/home/leizhenyu/opt/DUTs/XiangShan/third_party/nexus-am`. The command was
rerun with filesystem escalation.

Wall time reported by `/usr/bin/time -p`: 219.28 s.

Calibration: threshold 82, hit average 56.41, miss average 106.50, elapsed
112 s.

| Target | Variant | Parameter | Result | Attack Time |
| --- | --- | --- | --- | ---: |
| XiangShan v2 | Spectre V1 | `ATTACK_SAME_ROUNDS=2` | PASS | 41 s |
| XiangShan v2 | Spectre V2 | `V2_ATTACK_TRIES=2` | PASS | 66 s |

### Goal 1 Summary

- BOOM v3: Spectre V1 and V2 both work after tuning V2 to
  `ATTACK_SAME_ROUNDS=3`.
- BOOM v4: Spectre V2 works at `ATTACK_SAME_ROUNDS=2`; Spectre V1 executed but
  did not leak successfully up to `ATTACK_SAME_ROUNDS=10`.
- XiangShan v2: Spectre V1 and V2 both work with the current tuned parameters.

## Goal 2: Spectre V4/V5

Scope:

- BOOM v3: `MediumBoomV3Config`
- BOOM v4: `MediumBoomV4Config`
- XiangShan v2: local `/nfs/home/leizhenyu/opt/DUTs/XiangShan/build/emu`

### BOOM V4/V5

Initial command:

```bash
TARGETS=boom VARIANTS="v4 v5" \
BOOM_CONFIGS="MediumBoomV3Config MediumBoomV4Config" \
SECRET_SZ=1 ATTACK_REPEATS=1 STOP_ON_ACCEPT=0 MIN_SUCCESS_PCT=100 \
V4_ROUND_CANDIDATES="inline,2" \
V5_PROFILE_CANDIDATES="loop,1,1,16,8" \
TOOLCHAIN_TAG=goal2-boom-v4v5 TIMEOUT=30m \
MAX_CYCLES=3000000000 \
scripts/toolchain.sh
```

Wall time reported by `/usr/bin/time -p`: 730.56 s.

| Target | Variant | Parameter | Result | Attack Time | Notes |
| --- | --- | --- | --- | ---: | --- |
| `MediumBoomV3Config` | Spectre V4 | `inline,2` | FAIL | 94 s | Top candidate was `#`; second was `S`. |
| `MediumBoomV3Config` | Spectre V5 | `loop,1,1,16,8` | PASS | 57 s | Loop predictor gadget leaked successfully. |
| `MediumBoomV4Config` | Spectre V4 | `inline,2` | FAIL | 338 s | Executed, but did not leak successfully. |
| `MediumBoomV4Config` | Spectre V5 | `loop,1,1,16,8` | FAIL | 191 s | Executed, but did not leak successfully. |

Additional BOOM V4 tuning:

```bash
TARGETS=boom VARIANTS=v4 \
BOOM_CONFIGS="MediumBoomV3Config MediumBoomV4Config" \
SECRET_SZ=1 ATTACK_REPEATS=1 STOP_ON_ACCEPT=0 MIN_SUCCESS_PCT=100 \
V4_ROUND_CANDIDATES="inline,4" TOOLCHAIN_TAG=goal2-boom-v4-inline4 \
TIMEOUT=30m MAX_CYCLES=3000000000 \
scripts/toolchain.sh
```

Wall time reported by `/usr/bin/time -p`: 863.62 s.

| Target | Variant | Parameter | Result | Attack Time |
| --- | --- | --- | --- | ---: |
| `MediumBoomV3Config` | Spectre V4 | `inline,4` | PASS | 174 s |
| `MediumBoomV4Config` | Spectre V4 | `inline,4` | PASS | 641 s |

Additional BOOM v4 V5 tuning:

```bash
TARGETS=boom VARIANTS=v5 \
BOOM_CONFIGS=MediumBoomV4Config SECRET_SZ=1 ATTACK_REPEATS=1 \
STOP_ON_ACCEPT=1 MIN_SUCCESS_PCT=100 \
V5_PROFILE_CANDIDATES="loop,2,1,16,8 loop,1,1,32,8 loop,2,1,32,8" \
TOOLCHAIN_TAG=goal2-boom-v4-v5-tune TIMEOUT=30m \
MAX_CYCLES=3000000000 \
scripts/toolchain.sh
```

Wall time reported by `/usr/bin/time -p`: 908.07 s.

| Target | Variant | Parameter | Result | Attack Time |
| --- | --- | --- | --- | ---: |
| `MediumBoomV4Config` | Spectre V5 | `loop,2,1,16,8` | FAIL | 344 s |
| `MediumBoomV4Config` | Spectre V5 | `loop,1,1,32,8` | FAIL | 188 s |
| `MediumBoomV4Config` | Spectre V5 | `loop,2,1,32,8` | FAIL | 342 s |

### XiangShan V2 V4/V5

Command:

```bash
TARGETS=xiangshan VARIANTS="v4 v5" TOOLCHAIN_TAG=goal2-xs-v4v5 \
scripts/toolchain.sh
```

Result:

```text
error: XiangShan toolchain supports v1/v2 only: v4 v5
```

The current XiangShan target contains only `cache-calibration`, `spectre-v1`,
and `spectre-v2` workloads. Spectre V4/V5 still need to be ported before this
goal can be fully validated on XiangShan v2.

### Goal 2 Summary

- BOOM v3: Spectre V4 works with `inline,4`; Spectre V5 works with
  `loop,1,1,16,8`.
- BOOM v4: Spectre V4 works with `inline,4`; Spectre V5 executed but did not
  leak successfully with the tested loop profiles.
- XiangShan v2: Spectre V4/V5 are not yet available in the XiangShan
  toolchain path, so this part remains a porting task rather than a failed
  attack result.

## Goal 3: Meltdown-Style Faulting Load Experiment

Scope:

- BOOM v3: `MediumBoomV3Config`
- XiangShan v2: local `/nfs/home/leizhenyu/opt/DUTs/XiangShan/build/emu`

### Reference Search

The local checkout of `vusec/riscv-transient-attacks` contains RISC-V
Meltdown-style assembly references:

- `/tmp/riscv-transient-attacks/src/pocs/meltdown-us.S`
- `/tmp/riscv-transient-attacks/src/misc/manual-analysis/meltdown-noinit.S`

The referenced `meltdown-us.S` PoC assumes a user/supervisor memory split and a
faulting access to a supervisor page. This testbench currently runs bare-metal
workloads directly on the BOOM runtime or XiangShan AM runtime, so there is no
ready user/kernel page-table setup to reuse directly. The implemented local
experiment therefore uses a PMP-denied data page to create the same essential
primitive: a faulting load whose loaded byte is then used transiently to encode
into a cache probe array.

Implemented files:

- BOOM: `targets/boom/workloads/meltdown/src/meltdown.c`
- XiangShan: `targets/xiangshan/workloads/meltdown/src/meltdown.c`
- XiangShan runner: `targets/xiangshan/scripts/run-meltdown.sh`

Both versions use inline assembly for the critical sequence:

1. faulting byte load from the protected address;
2. shift byte value by one cache-line stride;
3. access `probe[value * 64]`;
4. recover through the trap handler and measure the probe array.

### BOOM V3

Initial long attempt:

```bash
CONFIG=MediumBoomV3Config MELTDOWN_ATTEMPTS=64 SECRET_SZ=1 \
CACHE_HIT_THRESHOLD=48 TIMEOUT=30m MAX_CYCLES=3000000000 \
RUN_TAG=goal3-boom-v3-meltdown \
targets/boom/scripts/run-workloads.sh meltdown
```

This run was interrupted after about 4 minutes because it had reached the
faulting-load loop but had not completed. The log showed successful startup and
calibration:

```text
[meltdown] calibration fallback=48 measured=78 threshold=48 attempts=64
[meltdown] secret_page=0x80022000 secret=0x53
```

Fast validation run:

```bash
CONFIG=MediumBoomV3Config MELTDOWN_ATTEMPTS=4 SECRET_SZ=1 \
CACHE_HIT_THRESHOLD=48 TIMEOUT=10m MAX_CYCLES=1000000000 \
RUN_TAG=goal3-boom-v3-meltdown-a4 \
targets/boom/scripts/run-workloads.sh meltdown
```

Wall time reported by `/usr/bin/time -p`: 173.29 s.

Result:

```text
[meltdown] traps=4 last_cause=5
[meltdown] byte  0: ? (0x00) score=0
[meltdown] expected: S (0x53) second=? (0x00) score=0
[meltdown] check 0 0x00 0x53 traps=4
```

Threshold follow-up:

```bash
CONFIG=MediumBoomV3Config MELTDOWN_ATTEMPTS=4 SECRET_SZ=1 \
CACHE_HIT_THRESHOLD=78 TIMEOUT=10m MAX_CYCLES=1000000000 \
RUN_TAG=goal3-boom-v3-meltdown-a4-th78 \
targets/boom/scripts/run-workloads.sh meltdown
```

Wall time reported by `/usr/bin/time -p`: 173.53 s.

Result:

```text
[meltdown] calibration fallback=78 measured=78 threshold=78 attempts=4
[meltdown] traps=4 last_cause=5
[meltdown] byte  0: ? (0x00) score=0
[meltdown] expected: S (0x53) second=? (0x00) score=0
[meltdown] check 0 0x00 0x53 traps=4
```

Conclusion: BOOM v3 traps and recovers correctly from the PMP-denied load
(`mcause=5`, load access fault), but the protected byte `0x53` did not appear in
the cache side channel with the tested parameters.

### XiangShan V2

Command:

```bash
MELTDOWN_ATTEMPTS=4 CACHE_HIT_THRESHOLD=82 \
USE_FIXED_CACHE_HIT_THRESHOLD=1 TIMEOUT=20m \
TAG=goal3-xs-meltdown-a4-th82 \
targets/xiangshan/scripts/run-meltdown.sh
```

Wall time reported by `/usr/bin/time -p`: 239.32 s.

Result:

```text
[meltdown] mode=xs-pmp-fault-inline
[meltdown] calibration fallback=82 measured=1152921503533094880 threshold=82 fixed=1 attempts=4
[meltdown] fault_addr=0000000090000010 secret=0x53
[meltdown] traps=4 last_cause=5
[meltdown] byte  0: ? (0x00) score=0
[meltdown] expected: S (0x53) second=? (0x00) score=0
[meltdown] check 0 0x00 0x53 traps=4
```

The XiangShan run used a fixed threshold because the in-workload calibration
returned an invalidly large measured value. The architectural behavior was still
valid for this experiment: the PMP-denied load triggered four load access faults
and the CTE handler recovered each time.

Conclusion: XiangShan v2 traps and recovers correctly from the PMP-denied load,
but the protected byte `0x53` did not appear in the cache side channel with the
tested parameters.

### Goal 3 Summary

- A Meltdown-style PMP faulting-load workload now exists for both BOOM and
  XiangShan.
- BOOM v3: fault/recovery works; no successful transient leak observed.
- XiangShan v2: fault/recovery works; no successful transient leak observed.
- The current result is therefore an executable negative result, not a working
  Meltdown attack. A stronger follow-up would need either a true U/S virtual
  memory setup matching `meltdown-us.S`, or a more specific microarchitectural
  fault source known to forward data transiently on the target core.
