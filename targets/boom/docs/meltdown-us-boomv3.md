# BOOM v3 Meltdown-US Mini-OS Notes

Date: 2026-07-08

This document records the first mini-OS style attempt to reproduce a
Meltdown-US primitive on BOOM v3.

## Goal

Build a bare-metal workload that creates the privilege environment required by
`meltdown-us.S` style attacks:

1. M-mode initializes PMP and Sv39 page tables.
2. U-mode code and probe array are mapped with `PTE_U=1`.
3. A secret page is mapped readable but supervisor-only, with `PTE_U=0`.
4. U-mode runs a faulting load gadget:

```asm
lb   t0, 0(a0)
slli t0, t0, 6
add  t0, t0, a1
ld   t1, 0(t0)
```

5. The trap path recovers to M-mode and measures the probe array.

## Implemented

New workload:

- `targets/boom/workloads/meltdown-us/src/meltdown-us.c`
- `targets/boom/workloads/meltdown-us/src/meltdown-us-start.S`
- `targets/boom/workloads/meltdown-us/src/meltdown-us-gadget.S`

Build/run integration:

- `make -C targets/boom meltdown-us`
- `targets/boom/scripts/run-workloads.sh meltdown-us`
- `VARIANTS=meltdown-us TARGETS=boom scripts/toolchain.sh`

The workload has a private startup/trap path instead of using the shared BOOM
runtime because the shared `crt.S` forces trap returns back to M-mode and is not
suitable for U-mode page-fault experiments.

## Current BOOM v3 Result

Representative command:

```bash
CONFIG=MediumBoomV3Config MELTDOWN_ATTEMPTS=4 CACHE_HIT_THRESHOLD=78 \
TIMEOUT=10m MAX_CYCLES=1000000000 \
RUN_TAG=meltdown-us-boomv3-mret-satp0-a4 \
targets/boom/scripts/run-workloads.sh meltdown-us
```

Wall time: 136.50 s.

Observed output:

```text
[meltdown-us] mode=sv39-u-s
[meltdown-us] threshold=78 measured=80 attempts=4
[meltdown-us] pte user=0x00000000200098df secret=0x0000000020009cc7
[meltdown-us] smoke user_read_ok
[meltdown-us] smoke user_fault
[meltdown-us] unexpected trap cause=12 epc=0x000000301a2607fc mtval=0x000000301a2607fc return=0x00000000800010aa dbg_ra=0x0000000000000000 dbg_sp=0x0000000000000000 tgt=0x00000000800010aa tsp=0x0000000080047e70
```

Interpretation:

- The page table entries are formed as intended:
  - user page PTE includes `PTE_U`.
  - secret page PTE does not include `PTE_U`.
- U-mode instruction fetch and a normal U-readable load start successfully.
- U-mode access to the S-only secret page triggers a fault path.
- The current blocker is the recovery path from the fault trap back to the
  M-mode trampoline continuation. It reaches the direct-return target
  (`0x800010aa`) but then trips an instruction page fault with a corrupted PC
  (`0x000000301a2607fc`).

The attack has therefore not yet reached a stable probe-measurement phase. This
is a mini-OS/trap-return blocker, not evidence for or against BOOM v3 Meltdown
leakage.

## Next Debug Direction

The next implementation should avoid returning from M-mode trap into a C call
frame. A cleaner design is:

- use a dedicated M-mode trap stack via `mscratch`;
- save the M-mode continuation context explicitly in assembly;
- return from U-mode fault into a pure assembly state machine;
- call C only after the trap stack and privilege state are fully restored.

This should remove the current C-frame/trampoline ambiguity before running
larger `MELTDOWN_ATTEMPTS` sweeps.

## miniOS Follow-up

The arch-fuzz miniOS at
`/nfs/home/leizhenyu/opt/arch-fuzz-add-am-system/generators/system/minios`
already provides the missing U/S trapframe structure. A first incremental patch
is recorded in `targets/boom/patches/minios-meltdown-us-smoke.patch`, with
notes in `targets/boom/docs/meltdown-minios-integration.md`.

That patch has now passed Spike and BOOM v3 smoke tests for:

- mapping a secret page into the user page table with `PTE_U=0`;
- triggering a U-mode load page fault on that address;
- recovering through the miniOS trap path back to user code.

BOOM v3 command:

```bash
/usr/bin/time -p timeout 10m \
  /nfs/home/leizhenyu/opt/DUTs/boom/chipyard/sims/verilator/simulator-chipyard.harness-MediumBoomV3Config \
  +permissive +max-cycles=3000000000 \
  +loadmem=/tmp/minios-meltdown-work2-build-halt/minios.spike.elf \
  +permissive-off /tmp/minios-meltdown-work2-build-halt/minios.spike.elf \
  2>&1 | tee targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-smoke-tiny-halt.log
```

BOOM v3 output:

```text
meltdown-us: secret_va=0x20000000 attempts=8
meltdown-us: fault recovery ok
meltdown-us: done
Verilog $finish
real 213.79
```

It does not yet claim BOOM cache-timing leakage.

## Kernel-Timing Follow-up

The miniOS patch now includes an optional `MELTDOWN_US_TIMING=1` path. Because
U-mode `rdcycle` and S-mode `cycle` CSR access were unstable or trapped, the
current timing path measures in S-mode through `SYS_meltdown_probe` using the
CLINT `mtime` MMIO counter.

BOOM v3 command:

```bash
/usr/bin/time -p timeout 10m \
  /nfs/home/leizhenyu/opt/DUTs/boom/chipyard/sims/verilator/simulator-chipyard.harness-MediumBoomV3Config \
  +permissive +max-cycles=3000000000 \
  +loadmem=/tmp/minios-meltdown-work2-build-ktiming-r4096/minios.spike.elf \
  +permissive-off /tmp/minios-meltdown-work2-build-ktiming-r4096/minios.spike.elf \
  2>&1 | tee targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-ktiming-r4096.log
```

Parameters:

```text
MELTDOWN_US_TIMING=1
MELTDOWN_US_ATTEMPTS=1
MELTDOWN_US_TIME_REPS=4096
```

Observed output:

```text
meltdown-us: timing hit=9 miss=8 threshold=8
meltdown-us: fault recovery ok
meltdown-us: score best=0x9/1 second=0xa/1 secret=0x53
meltdown-us: leak candidate miss
real 569.17
```

This reaches the measurement phase on BOOM v3, but it does not recover the
secret byte. The current best candidate is noise, not `0x53`.

The follow-up `kflush-r4096` run adds a dedicated
`SYS_meltdown_flush_probe` syscall before each faulting attempt:

```bash
/usr/bin/time -p timeout 10m \
  /nfs/home/leizhenyu/opt/DUTs/boom/chipyard/sims/verilator/simulator-chipyard.harness-MediumBoomV3Config \
  +permissive +max-cycles=3000000000 \
  +loadmem=/tmp/minios-meltdown-work2-build-kflush-r4096/minios.spike.elf \
  +permissive-off /tmp/minios-meltdown-work2-build-kflush-r4096/minios.spike.elf \
  2>&1 | tee targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-kflush-r4096.log
```

Observed output:

```text
meltdown-us: timing hit=9 miss=9 threshold=9
meltdown-us: fault recovery ok
meltdown-us: score best=0x0/1 second=0x1/1 secret=0x53
meltdown-us: leak candidate miss
meltdown-us: done
real 594.03
```

Interpretation: fault/recovery remains stable, but the explicit flush does not
make the side channel distinguish `0x53`. The `mtime` timing source reports
equal hit/miss calibration on this run, so the current demo is a working
Meltdown-US privilege/fault harness, not a successful BOOM v3 leakage demo.

## Raw Timing Diagnostic

A guarded cycle-counter prototype was added as
`MELTDOWN_US_CYCLE_TIMING=1`, but it is not currently usable. On Spike it
reaches the scheduler and then times out before the user program prints
`meltdown-us: main begin`:

```text
minios booting on core 0
minios core 0 installed sv39 kpt 0x807f7000 satp 0x80000000000807f7
SPIKE: FAIL (timeout waiting for meltdown-us: done)
real 104.69
```

The cycle-counter failure was split into smaller cases:

- `MELTDOWN_US_ENABLE_COUNTEREN=1` while still measuring with `mtime` also
  timed out after kernel page-table installation:

```text
minios booting on core 0
minios core 0 installed sv39 kpt 0x807f7000 satp 0x80000000000807f7
SPIKE: FAIL (timeout waiting for meltdown-us: done)
real 104.75
```

- `MELTDOWN_US_MCYCLE_TIMING=1` skips `mcounteren` and reads `mcycle` directly
  inside the S-mode syscall. Spike rejects it as an illegal instruction:

```text
meltdown-us: main begin
meltdown-us: secret_va=0x20000000 attempts=1
[trap] unexpected kernel trap scause=0x2 sepc=0x80006512 stval=0xb0002873
panic: [trap] unexpected kernel trap
real 4.76
```

This rules out both simple cycle-counter variants for BOOM follow-up: one
prevents user scheduling in the Spike baseline, and the other traps before any
measurement can complete.

The next diagnostic therefore keeps the stable `mtime` path and adds
`SYS_meltdown_probe_time_one`, controlled by `MELTDOWN_US_DEBUG_TIMES=1`.
With the full 256-bucket scan still enabled, BOOM v3 printed raw selected
buckets but hit the 10-minute outer timeout before `meltdown-us: done`:

```text
meltdown-us: timing hit=9 miss=9 threshold=9
meltdown-us: raw attempt=0 i0=9 i1=9 i52=9 i53=9 i54=9
real 600.01
```

With `MELTDOWN_US_DEBUG_ONLY=1`, the program skips the full scan after printing
the selected raw buckets and halts cleanly:

```text
meltdown-us: timing hit=9 miss=9 threshold=9
meltdown-us: raw attempt=0 i0=10 i1=9 i52=9 i53=9 i54=9
meltdown-us: fault recovery ok
meltdown-us: debug-only done secret=0x53
meltdown-us: done
real 316.49
```

This is a negative leakage result. Bucket `0x53` is not faster than the control
buckets under the current `mtime` measurement path.

## M-mode Cycle Timing Diagnostic

The latest miniOS patch adds `MELTDOWN_US_MMODE_CYCLE_TIMING=1`: S-mode asks
M-mode for `mcycle` through a magic ecall (`a7=0x4d435943`). This keeps the
earlier Spike baseline healthy while giving BOOM v3 cycle-level timing.

Spike sanity run:

```text
MELTDOWN_US_TIME_REPS=64
meltdown-us: timing hit=292 miss=292 threshold=292
meltdown-us: raw attempt=0 i0=292 i1=292 i52=292 i53=292 i54=292
meltdown-us: fault recovery ok
meltdown-us: debug-only done secret=0x53
meltdown-us: done
SPIKE: PASS
real 4.76
```

BOOM v3, original gadget:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-mmodecycle-debugonly-r64.log
MELTDOWN_US_TIME_REPS=64
meltdown-us: timing hit=352 miss=411 threshold=381
meltdown-us: raw attempt=0 i0=377 i1=418 i52=383 i53=391 i54=389
meltdown-us: fault recovery ok
meltdown-us: debug-only done secret=0x53
meltdown-us: done
real 311.62
```

The hit/miss calibration is finally visible on BOOM v3, but bucket `0x53` is
not faster than the controls.

The user gadget was then adjusted from signed `lb` plus `ld zero, 0(t0)` to
unsigned `lbu` plus a dependent `lb` into `t1`. This avoids a possible special
case around loads with `rd=x0`.

BOOM v3, adjusted gadget:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-mmodecycle-gadget1-debugonly-r1.log
MELTDOWN_US_TIME_REPS=1
meltdown-us: timing hit=236 miss=223 threshold=229
meltdown-us: raw attempt=0 i0=240 i1=282 i52=272 i53=240 i54=240
meltdown-us: fault recovery ok
meltdown-us: debug-only done secret=0x53
meltdown-us: done
real 345.21

log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-mmodecycle-gadget1-debugonly-r8.log
MELTDOWN_US_TIME_REPS=8
meltdown-us: timing hit=254 miss=246 threshold=250
meltdown-us: raw attempt=0 i0=257 i1=273 i52=265 i53=249 i54=249
meltdown-us: fault recovery ok
meltdown-us: debug-only done secret=0x53
meltdown-us: done
real 336.30
```

Current conclusion: the miniOS Meltdown-US harness now works through
supervisor-only mapping, U-mode fault, trap recovery, probe flush, and
cycle-level timing on BOOM v3. It still has not recovered secret byte `0x53`.
The remaining work is not OS setup; it is finding a BOOM v3 gadget/calibration
combination where the faulting load forwards data far enough to touch the
secret-indexed probe line before trap recovery squashes the path.

## Calibration And Stride Follow-up

`MELTDOWN_US_CAL_REPS=5` was added so calibration measures multiple hot/cold
samples in S-mode and reports a conservative pair: minimum hot timing and
maximum cold timing. This removed the hit/miss reversal seen in earlier
single-sample runs.

BOOM v3, adjusted gadget, `PROBE_STRIDE=64`, `CAL_REPS=5`:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-mmodecycle-cal5-gadget1-debugonly-r8.log
MELTDOWN_US_ATTEMPTS=1
MELTDOWN_US_TIME_REPS=8
meltdown-us: timing hit=208 miss=274 threshold=241
meltdown-us: raw attempt=0 i0=286 i1=290 i52=271 i53=248 i54=248
real 285.62
```

With four attempts, `i53` remained near hit latency, but `i54` did too:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-mmodecycle-cal5-gadget1-debugonly-r8-a4.log
meltdown-us: timing hit=208 miss=239 threshold=223
meltdown-us: raw attempt=0 i0=286 i1=302 i52=275 i53=259 i54=248
meltdown-us: raw attempt=1 i0=300 i1=290 i52=290 i53=248 i54=248
meltdown-us: raw attempt=2 i0=287 i1=290 i52=280 i53=248 i54=248
meltdown-us: raw attempt=3 i0=286 i1=314 i52=271 i53=248 i54=248
real 416.33
```

A wider raw debug window confirmed this is not a clean `0x53` signal:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-mmodecycle-cal5-gadget1-debugonly-r8-wide-a2.log
meltdown-us: timing hit=208 miss=273 threshold=240
meltdown-us: raw attempt=0 i0=308 i1=289 i50=264 i51=252 i52=248 i53=248 i54=248 i55=248 i56=248
meltdown-us: raw attempt=1 i0=314 i1=255 i50=264 i51=248 i52=248 i53=255 i54=255 i55=255 i56=255
real 337.57
```

The probe stride was then parameterized as `MELTDOWN_US_PROBE_STRIDE`.
`PROBE_STRIDE=4096` passes Spike smoke but is too slow for the current BOOM
debug path: the BOOM run reached `meltdown-us: main begin` but timed out at
480 seconds before calibration finished.

`PROBE_STRIDE=512` keeps runtime practical but still shows multi-bucket hits:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-mmodecycle-cal5-gadget1-debugonly-r8-s512-a2.log
meltdown-us: timing hit=209 miss=239 threshold=224
meltdown-us: raw attempt=0 i0=286 i1=255 i50=255 i51=255 i52=248 i53=248 i54=248 i55=259 i56=248
meltdown-us: raw attempt=1 i0=255 i1=255 i50=285 i51=259 i52=248 i53=248 i54=248 i55=259 i56=248
real 382.37
```

Interpretation: `CAL_REPS=5` is worth keeping because it makes thresholding
more stable. The wider debug output and stride sweep show that the current
gadget/probe setup still produces clustered nearby bucket hits, not a
secret-specific `0x53` hit. The next useful increment should change the
faulting gadget's speculative window/dependency chain rather than only tuning
threshold or stride.

## Gadget Delay Sweep

`MELTDOWN_US_GADGET_DELAY` was added to insert a small independent ALU chain
between the faulting secret load and the dependent probe load. The intent is to
give the dependent probe access more opportunity to execute before the trap
recovery path squashes the faulting sequence.

BOOM v3, `GADGET_DELAY=16`, `PROBE_STRIDE=64`:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-mmodecycle-cal5-gadgetd16-debugonly-r8-a2.log
meltdown-us: timing hit=208 miss=274 threshold=241
meltdown-us: raw attempt=0 i0=271 i1=259 i50=295 i51=255 i52=255 i53=255 i54=255 i55=248 i56=264
meltdown-us: raw attempt=1 i0=255 i1=260 i50=283 i51=248 i52=248 i53=248 i54=248 i55=248 i56=259
real 338.97
```

BOOM v3, `GADGET_DELAY=4`, `PROBE_STRIDE=64`:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-mmodecycle-cal5-gadgetd4-debugonly-r8-a2.log
meltdown-us: timing hit=208 miss=273 threshold=240
meltdown-us: raw attempt=0 i0=261 i1=248 i50=264 i51=248 i52=248 i53=248 i54=255 i55=255 i56=259
meltdown-us: raw attempt=1 i0=255 i1=265 i50=283 i51=255 i52=255 i53=248 i54=248 i55=255 i56=255
real 336.83
```

Both delay points are still negative leakage results. They preserve stable
fault recovery and timing, but several nearby buckets remain at hit latency.
The evidence now points away from simple independent delay tuning. The next
gadget change should alter the dependency chain itself, for example by using a
dependent address mask/serialization pattern or by testing a different
permission-fault sequence.

## Mixed-order And Dependency-chain Checks

The raw debug print order was changed to measure `i53` first, followed by
controls and neighboring buckets. This checks whether earlier adjacent hits
were produced by sequential `meltdown_probe_time_one()` measurement pollution
rather than by the faulting gadget.

BOOM v3, mixed-order debug, direct gadget:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-mmodecycle-cal5-mixed-debugonly-r8-a2.log
MELTDOWN_US_ATTEMPTS=2
MELTDOWN_US_TIME_REPS=8
MELTDOWN_US_CAL_REPS=5
MELTDOWN_US_PROBE_STRIDE=64
MELTDOWN_US_GADGET_DELAY=0
meltdown-us: timing hit=208 miss=274 threshold=241
meltdown-us: raw attempt=0 i53=298 i0=255 i80=285 i1=248 i55=248 i51=248 i56=248 i50=255 i54=259 i52=248
meltdown-us: raw attempt=1 i53=300 i0=255 i80=255 i1=255 i55=248 i51=248 i56=260 i50=255 i54=248 i52=248
real 355.45
```

This is a negative result. When `i53` is measured first it is clearly cold,
while later controls and neighboring buckets are faster. The earlier
`i53/i54`-fast observations were therefore not reliable evidence of a
secret-specific leak.

`MELTDOWN_US_GADGET_VARIANT` was then added:

- `0`: direct dependent probe, `lbu secret; andi; slli; add probe; lb`.
- `1`: pointer-table dependent probe, `lbu secret; andi; slli 3; ld ptr; lb`.

BOOM v3, pointer-table gadget:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-mmodecycle-cal5-var1-debugonly-r8-a2.log
MELTDOWN_US_GADGET_VARIANT=1
meltdown-us: timing hit=208 miss=274 threshold=241
meltdown-us: raw attempt=0 i53=271 i0=285 i80=248 i1=314 i55=254 i51=254 i56=248 i50=248 i54=255 i52=248
meltdown-us: raw attempt=1 i53=271 i0=276 i80=285 i1=259 i55=248 i51=264 i56=248 i50=255 i54=255 i52=248
real 403.68
```

This is also negative: the two-level dependency chain does not make bucket
`0x53` fast on BOOM v3.

Finally, `MELTDOWN_US_TOUCH_SECRET_ON_ARM=1` was added. With this enabled,
`SYS_meltdown_arm` touches the supervisor-only secret page in S-mode immediately
before returning to U-mode, so the subsequent faulting load should see a hot
secret cache line.

BOOM v3, direct gadget plus secret pre-touch:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-mmodecycle-cal5-touch-debugonly-r8-a2.log
MELTDOWN_US_TOUCH_SECRET_ON_ARM=1
meltdown-us: timing hit=209 miss=239 threshold=224
meltdown-us: raw attempt=0 i53=272 i0=256 i80=256 i1=272 i55=256 i51=256 i56=256 i50=256 i54=256 i52=262
meltdown-us: raw attempt=1 i53=272 i0=256 i80=249 i1=291 i55=256 i51=249 i56=260 i50=249 i54=249 i52=249
real 416.85
```

This remains negative. At this point the miniOS page-table setup, U-mode fault
recovery, BOOM v3 cycle timing, probe flushing, mixed-order diagnostics,
alternative dependency chain, and secret pre-touch have all been validated.
The missing condition is still the Meltdown leak itself: BOOM v3 has not
forwarded the supervisor-only load value far enough for a secret-indexed probe
access to leave a clean cache footprint for byte `0x53`.

## U-access Training Then Clear-U Check

`MELTDOWN_US_TRAIN_USER_ACCESS=1` was added to test a different permission
sequence. For each attempt the user program asks S-mode to set `PTE_U` on the
secret page, performs a real U-mode load from the same virtual address, then
asks S-mode to clear `PTE_U` and runs the faulting gadget. This verifies that
the same VA/data path can return `0x53` immediately before the supervisor-only
faulting load.

Spike smoke confirms the training read sees the secret and the fault/recovery
path still exits normally:

```text
MELTDOWN_US_TRAIN_USER_ACCESS=1
meltdown-us: training value=0x53
meltdown-us: fault recovery ok
meltdown-us: debug-only done secret=0x53
meltdown-us: done
SPIKE: PASS
real 4.82
```

BOOM v3 result:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-mmodecycle-cal5-trainu-debugonly-r8-a2.log
MELTDOWN_US_TRAIN_USER_ACCESS=1
MELTDOWN_US_TOUCH_SECRET_ON_ARM=1
MELTDOWN_US_GADGET_VARIANT=0
meltdown-us: timing hit=209 miss=245 threshold=227
meltdown-us: training value=0x53
meltdown-us: raw attempt=0 i53=291 i0=261 i80=256 i1=272 i55=272 i51=256 i56=256 i50=249 i54=260 i52=256
meltdown-us: raw attempt=1 i53=272 i0=256 i80=256 i1=285 i55=256 i51=256 i56=256 i50=256 i54=249 i52=249
real 414.88
```

This is also negative. The trained U-mode load proves the page contents and VA
translation are correct immediately before the attack, but after `PTE_U` is
cleared the BOOM v3 faulting load still does not produce a secret-specific
probe hit for `0x53`.

## Residency Diagnostic

`MELTDOWN_US_DEBUG_RESIDENCY=1` adds `SYS_meltdown_residency`, an S-mode timing
diagnostic that measures three lines:

- the supervisor-only secret page line;
- `probe[0x53]`;
- `probe[0]`.

The user test prints residency once after the U-access training/clear-U
sequence and once after the faulting gadget. This diagnostic intentionally
touches `probe[0x53]` and `probe[0]`, so any following raw bucket timing in the
same attempt is only a reference and cannot be counted as a leak result.

Spike smoke:

```text
MELTDOWN_US_DEBUG_RESIDENCY=1
MELTDOWN_US_TRAIN_USER_ACCESS=1
MELTDOWN_US_ATTEMPTS=1
meltdown-us: training value=0x53
meltdown-us: residency pre attempt=0 secret=76 p53=68 p0=68
meltdown-us: residency post attempt=0 secret=76 p53=68 p0=68
meltdown-us: done
SPIKE: PASS
real 4.84
```

BOOM v3 result:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-mmodecycle-cal5-resid-debugonly-r8-a1.log
MELTDOWN_US_DEBUG_RESIDENCY=1
MELTDOWN_US_TRAIN_USER_ACCESS=1
MELTDOWN_US_ATTEMPTS=1
meltdown-us: timing hit=208 miss=274 threshold=241
meltdown-us: training value=0x53
meltdown-us: residency pre attempt=0 secret=301 p53=278 p0=245
meltdown-us: residency post attempt=0 secret=268 p53=227 p0=261
meltdown-us: raw attempt=0 i53=239 i0=271 i80=254 i1=264 i55=248 i51=248 i56=254 i50=248 i54=248 i52=255
real 379.95
```

Interpretation: the U-mode training read still returns `0x53`, but the S-mode
residency check does not see the secret line as hot on BOOM v3
(`secret=301` before the gadget, `268` after it). `p53=227` after the gadget is
not valid leak evidence because the residency syscall itself touched
`probe[0x53]` before the raw timing print. This strengthens the current
diagnosis: the remaining blocker is not the user VA content or trap recovery,
but the specific BOOM v3 behavior around the supervisor-only faulting load and
the cache/TLB effects of the training/permission-change sequence.

## Clear-U Preload Check

`MELTDOWN_US_PRELOAD_ON_CLEAR=1` extends `SYS_meltdown_set_secret_user`: passing
argument `2` clears `PTE_U`, executes `sfence.vma`, and immediately touches the
secret page in S-mode before returning to U-mode. This tests the cleanest
secret-only preload path without touching any probe bucket before raw timing.

Spike smoke:

```text
MELTDOWN_US_PRELOAD_ON_CLEAR=1
MELTDOWN_US_TRAIN_USER_ACCESS=1
MELTDOWN_US_DEBUG_RESIDENCY=0
meltdown-us: training value=0x53
meltdown-us: raw attempt=0 i53=68 i0=68 i80=68 i1=68 i55=68 i51=68 i56=68 i50=68 i54=68 i52=68
meltdown-us: done
SPIKE: PASS
real 4.83
```

BOOM v3 with two attempts timed out at the 420-second wrapper timeout after
printing only attempt 0, but the first attempt was already negative:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-mmodecycle-cal5-preloadclear-debugonly-r8-a2.log
MELTDOWN_US_ATTEMPTS=2
meltdown-us: timing hit=208 miss=274 threshold=241
meltdown-us: training value=0x53
meltdown-us: raw attempt=0 i53=290 i0=255 i80=255 i1=248 i55=248 i51=248 i56=259 i50=248 i54=248 i52=248
real 420.01
```

BOOM v3 with one attempt exits cleanly and is also negative:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-mmodecycle-cal5-preloadclear-debugonly-r8-a1.log
MELTDOWN_US_ATTEMPTS=1
meltdown-us: timing hit=208 miss=281 threshold=244
meltdown-us: training value=0x53
meltdown-us: raw attempt=0 i53=300 i0=248 i80=248 i1=259 i55=248 i51=248 i56=248 i50=248 i54=248 i52=248
meltdown-us: fault recovery ok
meltdown-us: done
real 391.45
```

The secret-only preload does not improve leakage. Bucket `0x53` remains colder
than the controls even when S-mode touches the secret immediately after clearing
`PTE_U` and before returning to the faulting U-mode gadget.

## User Alias Training

`MELTDOWN_US_TRAIN_ALIAS=1` maps the same secret physical page at a second
user-readable VA, `0x20001000`, while keeping the attacked VA at `0x20000000`
supervisor-only. Each attempt reads the alias first, then faults on the
supervisor-only VA.

Spike smoke:

```text
meltdown-us: timing hit=68 miss=89 threshold=78
meltdown-us: alias_va=0x20001000 training value=0x53
meltdown-us: raw attempt=0 i53=68 i0=68 i80=68 i1=68 i55=68 i51=68 i56=68 i50=68 i54=68 i52=68
meltdown-us: done
SPIKE: PASS
real 4.83
```

BOOM v3:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-mmodecycle-cal5-alias-debugonly-r8-a1.log
MELTDOWN_US_TRAIN_ALIAS=1
meltdown-us: timing hit=208 miss=274 threshold=241
meltdown-us: alias_va=0x20001000 training value=0x53
meltdown-us: raw attempt=0 i53=294 i0=259 i80=264 i1=248 i55=248 i51=248 i56=248 i50=248 i54=248 i52=248
meltdown-us: fault recovery ok
meltdown-us: debug-only done secret=0x53
meltdown-us: done
real 352.93
```

This is negative. The user alias proves that the same physical secret page can
be read as `0x53`, but the supervisor-only faulting VA still does not create a
fast `probe[0x53]` bucket.

## PMP Access-Fault Variant

`MELTDOWN_US_PMP_FAULT=1` tests a different fault source. In this mode the
secret VA is mapped user-readable, and an M-mode magic ecall configures PMP as
three TOR ranges: allow before the secret page, deny the secret page, and allow
after it. This turns the attack load into a load access fault rather than a
U/S page-permission fault.

Spike non-timing smoke:

```text
meltdown-us: fault_mode=pmp-access
meltdown-us: pmp training value=0x53
meltdown-us: pmp deny armed
meltdown-us: fault recovery ok
meltdown-us: done
SPIKE: PASS
real 0.22
```

Spike timing smoke:

```text
meltdown-us: fault_mode=pmp-access
meltdown-us: timing hit=68 miss=68 threshold=68
meltdown-us: pmp training value=0x53
meltdown-us: pmp deny armed
meltdown-us: raw attempt=0 i53=68 i0=68 i80=68 i1=68 i55=68 i51=68 i56=68 i50=68 i54=68 i52=68
meltdown-us: fault recovery ok
meltdown-us: debug-only done secret=0x53
meltdown-us: done
SPIKE: PASS
real 0.34
```

BOOM v3 timing run:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-pmp-debugonly-r8-a1.log
MELTDOWN_US_PMP_FAULT=1
MELTDOWN_US_TIMING=1
MELTDOWN_US_MMODE_CYCLE_TIMING=1
MELTDOWN_US_DEBUG_TIMES=1
MELTDOWN_US_DEBUG_ONLY=1
meltdown-us: fault_mode=pmp-access
meltdown-us: timing hit=210 miss=274 threshold=242
meltdown-us: pmp training value=0x53
meltdown-us: pmp deny armed
real 420.01
```

BOOM v3 non-timing smoke:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-pmp-smoke-a1.log
MELTDOWN_US_PMP_FAULT=1
MELTDOWN_US_TIMING=0
meltdown-us: fault_mode=pmp-access
meltdown-us: pmp training value=0x53
meltdown-us: pmp deny armed
real 300.01
```

The PMP route works in Spike, including trap recovery, but BOOM v3 does not
complete after PMP deny in either the timing or non-timing build. This is not a
successful Meltdown demo. It indicates that the next blocker is BOOM's dynamic
PMP access-fault path or the miniOS recovery handling for that path on BOOM,
not the cache timing code.

## PMP Fault Delegation Diagnostic

`MELTDOWN_US_PMP_SIMPLE_FAULT=1` removes the transient gadget and executes only
one `lbu` from the PMP-denied secret VA after arming recovery.
`MELTDOWN_US_TRAP_DEBUG=1` prints the trap metadata when the S-mode recovery
branch is reached.

Spike reaches S-mode `usertrap()` as expected:

```text
meltdown-us: pmp_simple_fault=1
meltdown-us: pmp training value=0x53
meltdown-us: pmp deny armed
meltdown-us: trap recover scause=0x5 sepc=0x2c stval=0x20000000 recover=0x30
meltdown-us: fault recovery ok
meltdown-us: done
SPIKE: PASS
real 4.87
```

BOOM v3 without M-mode skip does not print the S-mode trap line:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-pmp-simple-debug-a1.log
MELTDOWN_US_PMP_SIMPLE_FAULT=1
MELTDOWN_US_TRAP_DEBUG=1
meltdown-us: pmp_simple_fault=1
meltdown-us: pmp training value=0x53
meltdown-us: pmp deny armed
real 300.01
```

`MELTDOWN_US_MMODE_FAULT_SKIP=1` adds a diagnostic M-mode machinevec branch
that skips load access faults reaching M-mode. With that enabled, the same
simple fault completes on BOOM v3:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-pmp-simple-mskip-a1.log
MELTDOWN_US_MMODE_FAULT_SKIP=1
meltdown-us: pmp_simple_fault=1
meltdown-us: pmp training value=0x53
meltdown-us: pmp deny armed
meltdown-us: fault recovery ok
meltdown-us: done
real 290.37
```

Interpretation: the earlier BOOM PMP hang is the M-mode unknown-trap loop.
Spike delegates the PMP load access fault to S-mode, while this BOOM v3 run
does not reach the S-mode `usertrap()` recovery branch.

The full transient PMP debug-only run with M-mode skip reaches measurement on
BOOM v3, but it is still negative:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-pmp-mskip-debugonly-r8-a1.log
MELTDOWN_US_PMP_FAULT=1
MELTDOWN_US_MMODE_FAULT_SKIP=1
MELTDOWN_US_TIMING=1
MELTDOWN_US_MMODE_CYCLE_TIMING=1
MELTDOWN_US_DEBUG_TIMES=1
MELTDOWN_US_DEBUG_ONLY=1
meltdown-us: timing hit=211 miss=275 threshold=243
meltdown-us: pmp training value=0x53
meltdown-us: pmp deny armed
meltdown-us: raw attempt=0 i53=300 i0=258 i80=289 i1=263 i55=251 i51=258 i56=258 i50=258 i54=258 i52=258
meltdown-us: fault recovery ok
meltdown-us: debug-only done secret=0x53
meltdown-us: done
real 364.30
```

`i53=300` is above the `243` threshold and slower than most controls. The
M-mode skip diagnostic makes recovery possible, but it does not produce a
secret-specific cache footprint.

The same PMP/M-mode-skip recovery path was then combined with
`MELTDOWN_US_GADGET_VARIANT=3`, the fixed `probe[0x53]` fault-window
diagnostic. This tests whether PMP gives a wider window for a younger
independent load than the page-permission no-sfence path.

Spike smoke passes:

```text
MELTDOWN_US_PMP_FAULT=1
MELTDOWN_US_MMODE_FAULT_SKIP=1
MELTDOWN_US_GADGET_VARIANT=3
meltdown-us: fault_mode=pmp-access
meltdown-us: pmp training value=0x53
meltdown-us: pmp deny armed
meltdown-us: raw attempt=0 i53=68 i0=68 i80=68 i1=68 i55=68 i51=68 i56=68 i50=68 i54=68 i52=68
meltdown-us: done
SPIKE: PASS
```

BOOM v3 reaches raw timing but remains negative:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-pmp-mskip-c1-var3-touch16-debugonly-r8-a1.log
CPUS=1
MELTDOWN_US_NPROC=4
MELTDOWN_US_PMP_FAULT=1
MELTDOWN_US_MMODE_FAULT_SKIP=1
MELTDOWN_US_GADGET_VARIANT=3
MELTDOWN_US_GADGET_TOUCH_REPEATS=16
MELTDOWN_US_TIME_REPS=8
meltdown-us: timing hit=210 miss=242 threshold=226
meltdown-us: pmp training value=0x53
meltdown-us: pmp deny armed
meltdown-us: raw attempt=0 i53=241 i0=296 i80=288 i1=321 i55=250 i51=266 i56=250 i50=250 i54=257 i52=257
meltdown-us: fault recovery ok
meltdown-us: done
real 377.36
```

`i53=241` is closer to threshold than the page-permission no-sfence variant 3
run (`255 > 241`), but it is still above the `226` PMP threshold. PMP therefore
does not currently provide a successful younger-load cache footprint either.

## Clear-U Without SFENCE Diagnostic

`MELTDOWN_US_CLEAR_NO_SFENCE=1` tests whether keeping a stale user TLB entry
after clearing `PTE_U` can create a wider transient window. The sequence is:

1. map the secret page user-readable;
2. train a user load from the secret VA and confirm the value is `0x53`;
3. clear `PTE_U` without `sfence.vma`;
4. run the normal faulting Meltdown-US gadget and raw timing diagnostics.

Spike smoke with the same ELF parameters reaches the expected page-fault
recovery path:

```text
meltdown-us: fault_mode=page-permission
meltdown-us: clear_no_sfence=1
meltdown-us: timing hit=68 miss=89 threshold=78
meltdown-us: training value=0x53
meltdown-us: trap recover scause=0xd sepc=0x34 stval=0x20000000 recover=0x52
meltdown-us: raw attempt=0 i53=68 i0=68 i80=68 i1=68 i55=89 i51=68 i56=68 i50=68 i54=68 i52=68
meltdown-us: fault recovery ok
meltdown-us: done
SPIKE: PASS
real 4.85
```

BOOM v3 command:

```bash
/usr/bin/time -p timeout 7m \
  /nfs/home/leizhenyu/opt/DUTs/boom/chipyard/sims/verilator/simulator-chipyard.harness-MediumBoomV3Config \
  +permissive +max-cycles=3500000000 \
  +loadmem=/tmp/minios-meltdown-work2-build-nosfence-r8-a1/minios.spike.elf \
  +permissive-off /tmp/minios-meltdown-work2-build-nosfence-r8-a1/minios.spike.elf \
  2>&1 | tee targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nosfence-debugonly-r8-a1.log
```

BOOM v3 result:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nosfence-debugonly-r8-a1.log
MELTDOWN_US_CLEAR_NO_SFENCE=1
MELTDOWN_US_TOUCH_SECRET_ON_ARM=1
MELTDOWN_US_TRAIN_USER_ACCESS=1
MELTDOWN_US_TIMING=1
MELTDOWN_US_MMODE_CYCLE_TIMING=1
MELTDOWN_US_DEBUG_TIMES=1
MELTDOWN_US_DEBUG_ONLY=1
MELTDOWN_US_ATTEMPTS=1
MELTDOWN_US_TIME_REPS=8
MELTDOWN_US_CAL_REPS=5
MELTDOWN_US_PROBE_STRIDE=64
meltdown-us: fault_mode=page-permission
meltdown-us: clear_no_sfence=1
meltdown-us: timing hit=209 miss=273 threshold=241
meltdown-us: training value=0x53
meltdown-us: trap recover scause=0xd sepc=0x34 stval=0x20000000 recover=0x52
meltdown-us: raw attempt=0 i53=273 i0=305 i80=297 i1=260 i55=249 i51=255 i56=279 i50=249 i54=253 i52=273
meltdown-us: fault recovery ok
meltdown-us: debug-only done secret=0x53
meltdown-us: done
real 370.68
```

The no-sfence variant confirms that BOOM v3 can train on the secret as a user
mapping, clear `PTE_U` without an explicit TLB flush, take the expected load
page fault, and recover. It still does not leak the secret: bucket `0x53`
measures `273`, above the `241` threshold and equal to/near miss-level control
buckets.

### Repeated No-SFENCE Debug Attempts

To check whether the single-attempt no-sfence result was hiding rare hits, the
same debug-only configuration was rerun with multiple attempts. A four-attempt
run reached three raw measurements but hit the 480-second wrapper timeout
before `done`:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nosfence-debugonly-r8-a4.log
MELTDOWN_US_ATTEMPTS=4
meltdown-us: timing hit=208 miss=250 threshold=229
meltdown-us: training value=0x53
meltdown-us: raw attempt=0 i53=336 i0=248 i80=285 i1=264 i55=248 i51=248 i56=248 i50=248 i54=252 i52=248
meltdown-us: raw attempt=1 i53=290 i0=255 i80=286 i1=259 i55=248 i51=307 i56=248 i50=248 i54=248 i52=248
meltdown-us: raw attempt=2 i53=271 i0=248 i80=248 i1=289 i55=248 i51=248 i56=259 i50=248 i54=248 i52=248
real 480.01
```

A three-attempt run also timed out after two raw measurements:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nosfence-debugonly-r8-a3.log
MELTDOWN_US_ATTEMPTS=3
meltdown-us: timing hit=208 miss=239 threshold=223
meltdown-us: training value=0x53
meltdown-us: raw attempt=0 i53=298 i0=286 i80=285 i1=248 i55=281 i51=248 i56=248 i50=248 i54=248 i52=248
meltdown-us: raw attempt=1 i53=291 i0=260 i80=248 i1=259 i55=248 i51=248 i56=248 i50=248 i54=248 i52=248
real 480.01
```

The clean repeated run uses two attempts and exits normally:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nosfence-debugonly-r8-a2clean.log
MELTDOWN_US_ATTEMPTS=2
meltdown-us: timing hit=208 miss=250 threshold=229
meltdown-us: training value=0x53
meltdown-us: raw attempt=0 i53=271 i0=261 i80=296 i1=265 i55=248 i51=252 i56=259 i50=248 i54=248 i52=248
meltdown-us: raw attempt=1 i53=264 i0=248 i80=285 i1=301 i55=248 i51=248 i56=248 i50=248 i54=248 i52=248
meltdown-us: fault recovery ok
meltdown-us: debug-only done secret=0x53
meltdown-us: done
real 432.99
```

The clean no-sfence repeated success rate is `0/2`: neither attempt had
`i53 < threshold`. The timeout runs add five more partial negative samples
(`i53` values 336, 290, 271, 298, and 291), but they are not counted as clean
success-rate runs because they did not reach `done`.

## Clear Accessed-Bit Diagnostic

`MELTDOWN_US_CLEAR_ACCESSED=1` tests a different page-fault source. The secret
mapping stays user-readable, but after a successful user training load the
kernel clears `PTE_A` and executes `sfence.vma`. The next user load faults
because the accessed bit is clear, not because the U/S permission check fails.
This checks whether BOOM v3 forwards data farther for a permission-allowed
load that faults on page-table state.

Spike verifies that the A-bit path traps and recovers:

```text
meltdown-us: fault_mode=page-permission
meltdown-us: clear_accessed=1
meltdown-us: timing hit=68 miss=68 threshold=68
meltdown-us: training value=0x53
meltdown-us: trap recover scause=0xd sepc=0x34 stval=0x20000000 recover=0x52
meltdown-us: raw attempt=0 i53=68 i0=68 i80=68 i1=68 i55=68 i51=68 i56=68 i50=68 i54=68 i52=68
meltdown-us: fault recovery ok
meltdown-us: done
SPIKE: PASS
real 4.90
```

BOOM v3 result:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-clearA-debugonly-r8-a1.log
MELTDOWN_US_CLEAR_ACCESSED=1
MELTDOWN_US_TOUCH_SECRET_ON_ARM=1
MELTDOWN_US_TRAIN_USER_ACCESS=1
MELTDOWN_US_TIMING=1
MELTDOWN_US_MMODE_CYCLE_TIMING=1
MELTDOWN_US_DEBUG_TIMES=1
MELTDOWN_US_DEBUG_ONLY=1
MELTDOWN_US_ATTEMPTS=1
MELTDOWN_US_TIME_REPS=8
MELTDOWN_US_CAL_REPS=5
MELTDOWN_US_PROBE_STRIDE=64
meltdown-us: fault_mode=page-permission
meltdown-us: clear_accessed=1
meltdown-us: timing hit=208 miss=274 threshold=241
meltdown-us: training value=0x53
meltdown-us: trap recover scause=0xd sepc=0x34 stval=0x20000000 recover=0x52
meltdown-us: raw attempt=0 i53=290 i0=248 i80=254 i1=307 i55=252 i51=248 i56=248 i50=248 i54=248 i52=248
meltdown-us: fault recovery ok
meltdown-us: debug-only done secret=0x53
meltdown-us: done
real 370.38
```

The A-bit page-fault source does not leak either. Bucket `0x53` measures `290`,
well above the `241` threshold, while several control buckets are near the hit
range. BOOM v3 is therefore still negative for the tested U/S, no-sfence, A-bit,
and PMP fault primitives.

The same accessed-bit fault source was then tested with
`MELTDOWN_US_GADGET_VARIANT=3`, the fixed `probe[0x53]` fault-window
diagnostic. This asks whether the A-bit fault permits any younger independent
load to leave a cache footprint.

Spike smoke passes:

```text
MELTDOWN_US_CLEAR_ACCESSED=1
MELTDOWN_US_GADGET_VARIANT=3
MELTDOWN_US_GADGET_TOUCH_REPEATS=16
meltdown-us: fault_mode=page-permission
meltdown-us: clear_accessed=1
meltdown-us: timing hit=68 miss=68 threshold=68
meltdown-us: training value=0x53
meltdown-us: raw attempt=0 i53=68 i0=68 i80=68 i1=68 i55=68 i51=68 i56=68 i50=68 i54=68 i52=68
meltdown-us: fault recovery ok
meltdown-us: done
SPIKE: PASS
```

BOOM v3 reaches raw timing but remains negative:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-clearA-c1-var3-touch16-debugonly-r8-a1.log
CPUS=1
MELTDOWN_US_NPROC=4
MELTDOWN_US_CLEAR_ACCESSED=1
MELTDOWN_US_TRAIN_USER_ACCESS=1
MELTDOWN_US_GADGET_VARIANT=3
MELTDOWN_US_GADGET_TOUCH_REPEATS=16
MELTDOWN_US_TIME_REPS=8
MELTDOWN_US_CAL_REPS=5
meltdown-us: timing hit=208 miss=274 threshold=241
meltdown-us: training value=0x53
meltdown-us: raw attempt=0 i53=255 i0=281 i80=309 i1=313 i55=309 i51=259 i56=285 i50=258 i54=273 i52=279
meltdown-us: fault recovery ok
meltdown-us: debug-only done secret=0x53
meltdown-us: done
real 374.84
```

This fixed-touch A-bit run is also negative: `i53=255` is above the `241`
threshold. Compared with the no-sfence fixed-touch result (`255 > 241`) and
the PMP/M-mode-skip fixed-touch result (`241 > 226`), the accessed-bit source
does not widen the BOOM v3 transient window enough to produce a reliable
younger-load cache footprint.

## Non-Faulting Positive Controls

Two positive controls were added because the faulting variants were all
negative. These controls do not prove Meltdown, but they test whether the
current probe/flush/timing path can see a deliberately hot `probe[0x53]`.

The first control keeps the secret mapping user-readable with
`MELTDOWN_US_NO_FAULT=1`, then runs the same gadget legally. With one probe
touch it still did not make bucket `0x53` a hit on BOOM v3:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nofault-debugonly-r8-a1.log
MELTDOWN_US_NO_FAULT=1
MELTDOWN_US_TRAIN_USER_ACCESS=1
MELTDOWN_US_GADGET_TOUCH_REPEATS=1
meltdown-us: timing hit=209 miss=279 threshold=244
meltdown-us: training value=0x53
meltdown-us: raw attempt=0 i53=267 i0=287 i80=287 i1=256 i55=256 i51=269 i56=256 i50=256 i54=256 i52=256
meltdown-us: done
real 376.81
```

Repeating the final probe touch 16 times also remained inconclusive:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nofault-touch16-debugonly-r8-a1.log
MELTDOWN_US_NO_FAULT=1
MELTDOWN_US_TRAIN_USER_ACCESS=1
MELTDOWN_US_GADGET_TOUCH_REPEATS=16
meltdown-us: timing hit=209 miss=273 threshold=241
meltdown-us: training value=0x53
meltdown-us: raw attempt=0 i53=256 i0=249 i80=333 i1=261 i55=272 i51=256 i56=256 i50=256 i54=256 i52=262
meltdown-us: done
real 354.09
```

A second, stronger diagnostic was added as `MELTDOWN_US_TOUCH_PROBE_CONTROL=1`.
It bypasses the secret load and fault gadget completely: after
`SYS_meltdown_flush_probe`, U-mode directly reads `probe[0x53]` and then raw
timing measures the selected buckets. Spike verifies the new path:

```text
MELTDOWN_US_TOUCH_PROBE_CONTROL=1
MELTDOWN_US_GADGET_TOUCH_REPEATS=16
meltdown-us: touch_probe_control=1
meltdown-us: timing hit=68 miss=68 threshold=68
meltdown-us: raw attempt=0 i53=68 i0=68 i80=68 i1=68 i55=89 i51=68 i56=68 i50=68 i54=68 i52=68
meltdown-us: done
SPIKE: PASS
real 4.94
```

The first BOOM v3 attempt with this direct touch-probe control used a
420-second wrapper and did not reach user mode:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-touchprobe-debugonly-r8-a1.log
minios booting on core 0
minios core 0 installed sv39 kpt 0x807f7000 satp 0x80000000000807f7
[UART] UART0 is here (stdin/stdout).
real 420.01
```

A 10-minute rerun was interrupted after it again failed to reach
`meltdown-us: main begin`. This is recorded as a BOOM run failure/timeout, not
as a negative cache result.

The important conclusion is that the current BOOM v3 work should first make a
non-faulting positive control unmistakable. Until direct `probe[0x53]` touches
produce a stable low-latency `i53`, additional Meltdown fault primitives cannot
be interpreted cleanly.

## Single-Core Positive-Control Follow-Up

The direct touch-probe control was rebuilt with a smaller miniOS configuration
to reduce BOOM startup overhead:

```text
CPUS=1
MELTDOWN_US_NPROC=4
MELTDOWN_US_TOUCH_PROBE_CONTROL=1
MELTDOWN_US_GADGET_TOUCH_REPEATS=16
MELTDOWN_US_TIME_REPS=8
MELTDOWN_US_CAL_REPS=5
MELTDOWN_US_DEBUG_TIMES=1
MELTDOWN_US_DEBUG_ONLY=1
```

Spike passes in this configuration and BOOM v3 now reaches the raw timing
print:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-touchprobe-c1-debugonly-r8-a1.log
meltdown-us: touch_probe_control=1
meltdown-us: timing hit=208 miss=274 threshold=241
meltdown-us: raw attempt=0 i53=239 i0=290 i80=248 i1=259 i55=248 i51=248 i56=255 i50=248 i54=248 i52=248
meltdown-us: done
real 381.59
```

This is a weak but real positive control: the directly touched `0x53` bucket is
below the `241` threshold, while most controls are above it. The margin is only
two cycles, so it is useful as a diagnostic but not yet a robust scoring
threshold.

The same single-core setup was then run with the legal secret-indexed gadget:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nofault-c1-touch16-debugonly-r8-a1.log
CPUS=1
MELTDOWN_US_NPROC=4
MELTDOWN_US_NO_FAULT=1
MELTDOWN_US_TRAIN_USER_ACCESS=1
MELTDOWN_US_GADGET_TOUCH_REPEATS=16
meltdown-us: timing hit=208 miss=274 threshold=241
meltdown-us: training value=0x53
meltdown-us: raw attempt=0 i53=239 i0=254 i80=248 i1=259 i55=277 i51=248 i56=248 i50=248 i54=248 i52=252
meltdown-us: done
real 362.82
```

This confirms that the legal gadget can index `probe[0x53]` and leave the same
weak hit on BOOM v3.

Finally, the single-core no-sfence faulting path was run with the same gadget
strength:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nosfence-c1-debugonly-r8-a1.log
CPUS=1
MELTDOWN_US_NPROC=4
MELTDOWN_US_CLEAR_NO_SFENCE=1
MELTDOWN_US_TRAIN_USER_ACCESS=1
MELTDOWN_US_GADGET_TOUCH_REPEATS=16
meltdown-us: timing hit=208 miss=246 threshold=227
meltdown-us: training value=0x53
meltdown-us: raw attempt=0 i53=271 i0=311 i80=301 i1=266 i55=273 i51=273 i56=274 i50=255 i54=321 i52=310
meltdown-us: fault recovery ok
meltdown-us: done
real 366.62
```

The no-sfence faulting run is still negative: `i53=271` is above the `227`
threshold. The current BOOM v3 evidence is therefore:

1. direct `probe[0x53]` touch: weak positive (`239 < 241`);
2. legal secret-indexed gadget: weak positive (`239 < 241`);
3. faulting no-sfence gadget: negative (`271 > 227`).

This narrows the blocker to the faulting/transient execution path, not the
basic legal gadget or the raw timing syscall.

## Single-Core Parameter Sweep

Two follow-up legal no-fault runs tested whether the single-core positive
control could be strengthened before spending more BOOM time on the faulting
path.

First, `MELTDOWN_US_GADGET_DELAY` was inserted between the secret load and the
probe touch. This did not help. With delay `16`, bucket `0x53` moved above the
threshold:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nofault-c1-delay16-touch16-debugonly-r8-a1.log
CPUS=1
MELTDOWN_US_NPROC=4
MELTDOWN_US_NO_FAULT=1
MELTDOWN_US_TRAIN_USER_ACCESS=1
MELTDOWN_US_GADGET_TOUCH_REPEATS=16
MELTDOWN_US_GADGET_DELAY=16
MELTDOWN_US_TIME_REPS=8
meltdown-us: timing hit=208 miss=281 threshold=244
meltdown-us: training value=0x53
meltdown-us: raw attempt=0 i53=255 i0=301 i80=248 i1=289 i55=248 i51=252 i56=248 i50=248 i54=248 i52=248
meltdown-us: done
real 366.91
```

With delay `4`, the legal positive control was also negative:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nofault-c1-delay4-touch16-debugonly-r8-a1.log
CPUS=1
MELTDOWN_US_NPROC=4
MELTDOWN_US_NO_FAULT=1
MELTDOWN_US_TRAIN_USER_ACCESS=1
MELTDOWN_US_GADGET_TOUCH_REPEATS=16
MELTDOWN_US_GADGET_DELAY=4
MELTDOWN_US_TIME_REPS=8
meltdown-us: timing hit=208 miss=274 threshold=241
meltdown-us: training value=0x53
meltdown-us: raw attempt=0 i53=298 i0=291 i80=317 i1=299 i55=258 i51=254 i56=290 i50=258 i54=248 i52=254
meltdown-us: done
real 379.69
```

Second, the no-delay legal positive control was rerun with
`MELTDOWN_US_TIME_REPS=16`. This still produced only a weak hit:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nofault-c1-touch16-debugonly-r16-a1.log
CPUS=1
MELTDOWN_US_NPROC=4
MELTDOWN_US_NO_FAULT=1
MELTDOWN_US_TRAIN_USER_ACCESS=1
MELTDOWN_US_GADGET_TOUCH_REPEATS=16
MELTDOWN_US_GADGET_DELAY=0
MELTDOWN_US_TIME_REPS=16
meltdown-us: timing hit=224 miss=299 threshold=261
meltdown-us: training value=0x53
meltdown-us: raw attempt=0 i53=258 i0=269 i80=266 i1=312 i55=276 i51=276 i56=276 i50=276 i54=276 i52=276
meltdown-us: done
real 373.84
```

The `TIME_REPS=16` margin is only three cycles (`258 < 261`), so it does not
materially improve the earlier `TIME_REPS=8` positive control. The delay sweep
is worse: both tested delay points break the already weak legal hit. Based on
that, the matching no-sfence delay and no-sfence `TIME_REPS=16` BOOM runs were
not launched; the positive control is not yet strong enough to justify the
extra faulting runs.

The current best baseline remains:

```text
CPUS=1
MELTDOWN_US_NPROC=4
MELTDOWN_US_GADGET_DELAY=0
MELTDOWN_US_GADGET_TOUCH_REPEATS=16
MELTDOWN_US_TIME_REPS=8
MELTDOWN_US_CAL_REPS=5
MELTDOWN_US_PROBE_STRIDE=64
MELTDOWN_US_MMODE_CYCLE_TIMING=1
MELTDOWN_US_DEBUG_TIMES=1
MELTDOWN_US_DEBUG_ONLY=1
```

This setup is sufficient to observe weak legal positive controls, but BOOM v3
still has not recovered secret byte `0x53` through the faulting Meltdown-US
path.

## Gadget Variant 2

`MELTDOWN_US_GADGET_VARIANT=2` was added to change the dependent probe access
without touching neighboring buckets. After the secret byte selects
`probe + secret * stride`, the gadget issues four byte loads within the same
64-byte cache line:

```asm
lbu  t0, 0(secret_va)
andi t0, t0, 0xff
slli t0, t0, PROBE_SHIFT
add  t0, t0, probe
lb   t1, 0(t0)
lb   t2, 8(t0)
lb   t3, 16(t0)
lb   t4, 24(t0)
```

The intent was to amplify the footprint of the selected cache line while
keeping the selected bucket unchanged.

Spike smoke passed for both the legal no-fault control and the no-sfence
faulting configuration.

BOOM v3, legal no-fault control:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nofault-c1-var2-touch16-debugonly-r8-a1.log
CPUS=1
MELTDOWN_US_NPROC=4
MELTDOWN_US_GADGET_VARIANT=2
MELTDOWN_US_NO_FAULT=1
MELTDOWN_US_TRAIN_USER_ACCESS=1
MELTDOWN_US_GADGET_TOUCH_REPEATS=16
MELTDOWN_US_TIME_REPS=8
meltdown-us: timing hit=208 miss=274 threshold=241
meltdown-us: training value=0x53
meltdown-us: raw attempt=0 i53=239 i0=248 i80=285 i1=264 i55=248 i51=248 i56=248 i50=248 i54=248 i52=248
meltdown-us: done
real 400.65
```

This preserves the weak legal positive control: `i53=239 < threshold=241`.

BOOM v3, matching no-sfence faulting run:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nosfence-c1-var2-touch16-debugonly-r8-a1.log
CPUS=1
MELTDOWN_US_NPROC=4
MELTDOWN_US_GADGET_VARIANT=2
MELTDOWN_US_CLEAR_NO_SFENCE=1
MELTDOWN_US_TRAIN_USER_ACCESS=1
MELTDOWN_US_GADGET_TOUCH_REPEATS=16
MELTDOWN_US_TIME_REPS=8
meltdown-us: timing hit=208 miss=245 threshold=226
meltdown-us: training value=0x53
meltdown-us: raw attempt=0 i53=271 i0=324 i80=248 i1=260 i55=263 i51=308 i56=284 i50=255 i54=310 i52=274
meltdown-us: fault recovery ok
meltdown-us: done
real 363.87
```

The faulting run remains negative: `i53=271` is above the `226` threshold.
Variant 2 therefore changes the gadget shape and keeps the legal positive
control working, but it does not make BOOM v3 forward the supervisor-only load
value far enough to recover byte `0x53`.

## Gadget Variant 3

`MELTDOWN_US_GADGET_VARIANT=3` is a control for the faulting window itself. It
executes the supervisor-only load first, then touches fixed `probe[0x53]`
independently of the secret value:

```asm
lbu  t0, 0(secret_va)
li   t2, 0x53
slli t2, t2, PROBE_SHIFT
add  t2, t2, probe
mv   t0, t2
lb   t1, 0(t0)
```

This is not a Meltdown leak gadget because the probe index is constant. Its
purpose is to distinguish two failure modes:

1. the faulting load does not forward secret data to dependent operations;
2. younger loads after the faulting load are squashed or blocked before leaving
   a cache footprint at all.

Spike smoke passed for both legal no-fault and no-sfence faulting builds.

BOOM v3, legal no-fault control:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nofault-c1-var3b-touch16-debugonly-r8-a1.log
CPUS=1
MELTDOWN_US_NPROC=4
MELTDOWN_US_GADGET_VARIANT=3
MELTDOWN_US_NO_FAULT=1
MELTDOWN_US_TRAIN_USER_ACCESS=1
MELTDOWN_US_GADGET_TOUCH_REPEATS=16
MELTDOWN_US_TIME_REPS=8
meltdown-us: timing hit=208 miss=285 threshold=246
meltdown-us: training value=0x53
meltdown-us: raw attempt=0 i53=239 i0=302 i80=254 i1=289 i55=248 i51=248 i56=259 i50=248 i54=248 i52=248
meltdown-us: done
real 400.61
```

The fixed-touch control works legally: `i53=239 < threshold=246`.

BOOM v3, matching no-sfence faulting run:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nosfence-c1-var3b-touch16-debugonly-r8-a1.log
CPUS=1
MELTDOWN_US_NPROC=4
MELTDOWN_US_GADGET_VARIANT=3
MELTDOWN_US_CLEAR_NO_SFENCE=1
MELTDOWN_US_TRAIN_USER_ACCESS=1
MELTDOWN_US_GADGET_TOUCH_REPEATS=16
MELTDOWN_US_TIME_REPS=8
meltdown-us: timing hit=208 miss=274 threshold=241
meltdown-us: training value=0x53
meltdown-us: raw attempt=0 i53=255 i0=286 i80=248 i1=290 i55=263 i51=248 i56=248 i50=248 i54=252 i52=248
meltdown-us: fault recovery ok
meltdown-us: done
real 378.30
```

The faulting fixed-touch run is negative: `i53=255` is above the `241`
threshold. This suggests the current BOOM v3 no-sfence page-permission fault
path is not merely failing to forward the secret byte; even a younger
independent load after the faulting supervisor-only load does not leave a
stable measurable cache footprint. The next direction should therefore change
the fault source or permission-transition timing, not only the
secret-dependent address chain.

The PMP/M-mode-skip and accessed-bit runs above test two alternate fault
sources with the same fixed-touch diagnostic. They also remain negative
(`i53=241 > threshold=226` for PMP and `i53=255 > threshold=241` for A-bit).
BOOM v3 therefore still has not shown a reliable cache footprint from a younger
load after the fault in any tested fault source.

## Gadget Variant 4

`MELTDOWN_US_GADGET_VARIANT=4` extends the fixed-touch diagnostic by issuing
several independent fixed probe loads after the faulting load:

```asm
lbu  t0, 0(secret_va)
touch probe[0x53]
touch probe[0x51]
touch probe[0x55]
touch probe[0x80]
```

This is still not a leakage gadget because all touched buckets are constants.
Its purpose is to test whether a wider group of younger independent loads can
leave any measurable cache footprint when the single fixed-touch diagnostic is
too weak.

Spike smoke passed for both legal no-fault and accessed-bit faulting builds.

BOOM v3, legal no-fault control:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nofault-c1-var4-debugonly-r8-a1.log
CPUS=1
MELTDOWN_US_NPROC=4
MELTDOWN_US_GADGET_VARIANT=4
MELTDOWN_US_NO_FAULT=1
MELTDOWN_US_TRAIN_USER_ACCESS=1
MELTDOWN_US_TIME_REPS=8
meltdown-us: timing hit=208 miss=280 threshold=244
meltdown-us: training value=0x53
meltdown-us: raw attempt=0 i53=239 i0=266 i80=248 i1=248 i55=232 i51=232 i56=248 i50=252 i54=248 i52=248
meltdown-us: done
real 370.43
```

The legal path confirms variant 4 can create a measurable footprint:
`i53=239`, `i55=232`, and `i51=232` are below the `244` threshold. Bucket
`0x80=248` is close but above threshold.

BOOM v3, accessed-bit faulting run:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-clearA-c1-var4-touch16-debugonly-r8-a1.log
CPUS=1
MELTDOWN_US_NPROC=4
MELTDOWN_US_GADGET_VARIANT=4
MELTDOWN_US_CLEAR_ACCESSED=1
MELTDOWN_US_TRAIN_USER_ACCESS=1
MELTDOWN_US_TIME_REPS=8
meltdown-us: timing hit=208 miss=274 threshold=241
meltdown-us: training value=0x53
meltdown-us: raw attempt=0 i53=271 i0=248 i80=248 i1=289 i55=248 i51=248 i56=259 i50=248 i54=248 i52=248
meltdown-us: fault recovery ok
meltdown-us: done
real 384.69
```

The faulting run remains negative for the target bucket: `i53=271` is above
the `241` threshold. Some fixed buckets sit near the low-latency range
(`i80/i55/i51=248`), but none crosses the threshold and the target bucket is
cold. Variant 4 therefore strengthens the earlier conclusion: the current A-bit
fault source does not provide a stable BOOM v3 younger-load footprint, even
when several independent fixed probe loads are issued after the fault.

The same widened fixed-touch diagnostic was then run on the PMP/M-mode-skip
fault source:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-pmp-mskip-c1-var4-debugonly-r8-a1.log
CPUS=1
MELTDOWN_US_NPROC=4
MELTDOWN_US_PMP_FAULT=1
MELTDOWN_US_MMODE_FAULT_SKIP=1
MELTDOWN_US_GADGET_VARIANT=4
MELTDOWN_US_TIME_REPS=8
meltdown-us: timing hit=210 miss=289 threshold=249
meltdown-us: pmp training value=0x53
meltdown-us: pmp deny armed
meltdown-us: raw attempt=0 i53=241 i0=342 i80=288 i1=250 i55=263 i51=263 i56=250 i50=257 i54=257 i52=263
meltdown-us: fault recovery ok
meltdown-us: done
real 377.81
```

This is the first BOOM v3 faulting diagnostic in this series where the selected
fixed bucket crosses threshold (`i53=241 < 249`). It is still not a Meltdown
leak because `0x53` is hard-coded by variant 4. It does, however, show that the
PMP/M-mode-skip fault source can sometimes leave a measurable younger-load
footprint.

That result justified rerunning real secret-dependent gadgets on the same PMP
fault source. Variant 0, the direct secret-indexed probe chain, remains
negative:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-pmp-mskip-c1-var0-debugonly-r8-a1.log
CPUS=1
MELTDOWN_US_NPROC=4
MELTDOWN_US_PMP_FAULT=1
MELTDOWN_US_MMODE_FAULT_SKIP=1
MELTDOWN_US_GADGET_VARIANT=0
MELTDOWN_US_GADGET_TOUCH_REPEATS=16
MELTDOWN_US_TIME_REPS=8
meltdown-us: timing hit=210 miss=276 threshold=243
meltdown-us: pmp training value=0x53
meltdown-us: pmp deny armed
meltdown-us: raw attempt=0 i53=260 i0=292 i80=288 i1=257 i55=257 i51=250 i56=261 i50=257 i54=257 i52=261
meltdown-us: fault recovery ok
meltdown-us: done
real 385.80
```

Variant 2, the secret-indexed selected-line amplification gadget, is also
negative:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-pmp-mskip-c1-var2-debugonly-r8-a1.log
CPUS=1
MELTDOWN_US_NPROC=4
MELTDOWN_US_PMP_FAULT=1
MELTDOWN_US_MMODE_FAULT_SKIP=1
MELTDOWN_US_GADGET_VARIANT=2
MELTDOWN_US_TIME_REPS=8
meltdown-us: timing hit=210 miss=276 threshold=243
meltdown-us: pmp training value=0x53
meltdown-us: pmp deny armed
meltdown-us: raw attempt=0 i53=261 i0=305 i80=261 i1=291 i55=250 i51=265 i56=250 i50=250 i54=250 i52=257
meltdown-us: fault recovery ok
meltdown-us: done
real 354.93
```

So PMP/M-mode-skip is the most promising fault source so far, but only for
fixed younger-load diagnostics. It still has not propagated the faulting secret
byte through the dependent address chain strongly enough to recover `0x53`.
