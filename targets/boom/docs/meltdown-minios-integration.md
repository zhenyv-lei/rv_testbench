# Meltdown-US miniOS Integration Notes

Date: 2026-07-08

## Source

Reference miniOS:

```text
/nfs/home/leizhenyu/opt/arch-fuzz-add-am-system/generators/system/minios
```

Patch artifact in this repository:

```text
targets/boom/patches/minios-meltdown-us-smoke.patch
```

## Assessment

This miniOS is useful for BOOM Meltdown work. It already has the parts that the
previous bare-metal `meltdown-us` workload was missing:

- M-mode boot into S-mode.
- Sv39 user page tables.
- Real U-mode processes.
- xv6-style `TRAMPOLINE` and `TRAPFRAME`.
- U-mode trap entry that saves user registers, switches back to kernel `satp`,
  and returns through `sret`.

That makes it a better base than the current private M-mode trampoline in
`targets/boom/workloads/meltdown-us`, whose blocker was unstable recovery from
a U-mode fault back to the measurement phase.

## Implemented Smoke Patch

The patch adds a Meltdown-US smoke path without changing the default miniOS
behavior unless `MELTDOWN_US=1` is set.

Main changes:

- Adds BOOM-friendly smoke build knobs.
  - `MELTDOWN_US_PHYSMEM_MB=8`
  - `MELTDOWN_US_NPROC=8`
  - `MELTDOWN_US_NINODE=32`
  - `MELTDOWN_US_NFILE=64`
  - `MELTDOWN_US_TIMING=0`
  - `MELTDOWN_US_CYCLE_TIMING=0`
  - `MELTDOWN_US_ENABLE_COUNTEREN` defaults to `MELTDOWN_US_CYCLE_TIMING`
  - `MELTDOWN_US_MCYCLE_TIMING=0`
  - `MELTDOWN_US_DEBUG_TIMES=0`
  - `MELTDOWN_US_DEBUG_ONLY=0`
  - `MELTDOWN_US_ATTEMPTS=16`
  - `MELTDOWN_US_TIME_REPS=64`
  - `MELTDOWN_US_CAL_REPS=5`
  - `MELTDOWN_US_PROBE_STRIDE=64`
  - `MELTDOWN_US_GADGET_DELAY=0`
  - `BOOT_DEBUG=0` can suppress boot-stage and per-process debug output.
- Adds `SYS_meltdown_setup`.
  - Creates a kernel-owned secret page.
  - Maps it into the current user page table at `0x20000000`.
  - Maps it readable but without `PTE_U`.
- Adds `SYS_meltdown_arm`.
  - Lets the user program register a recovery PC before the faulting load.
- Adds `SYS_meltdown_done`.
  - Lets the smoke test call `platform_halt(0)` after the sentinel, so BOOM
    runs finish automatically instead of needing Ctrl-C after `wfi`.
- Adds `SYS_meltdown_calibrate` and `SYS_meltdown_probe`.
  - These are used only when `MELTDOWN_US_TIMING=1`.
  - Timing is performed in S-mode using CLINT `mtime`, avoiding the earlier
    unstable U-mode `rdcycle` path.
- Adds `SYS_meltdown_flush_probe`.
  - Flushes every translated probe-array line from S-mode before each faulting
    attempt, so the measurement phase does not reuse stale cached probe lines.
- Adds `SYS_meltdown_probe_time_one`.
  - Debug-only raw timing helper for selected probe indices. This is used to
    diagnose whether the secret bucket is distinguishable before paying for a
    full 256-bucket scan.
- Extends `usertrap()`.
  - If a load page fault occurs while `meltdown_recover_epc` is armed, the trap
    handler resumes at that PC instead of killing the process.
- Adds `user/meltdown_us.c`.
  - Allocates a probe array.
  - Executes the transient-style gadget:

```asm
lb   t0, 0(secret_va)
slli t0, t0, 6
add  t0, t0, probe
ld   zero, 0(t0)
```
  - Includes an experimental `MELTDOWN_US_TIMING=1` path for kernel-side
    eviction and probe reload timing.

The smoke currently verifies the privilege setup and fault recovery. It does
not yet claim a cache-timing leak.

## Verified

The patch applies cleanly to a fresh miniOS copy:

```bash
mkdir -p /tmp/minios-patch-apply-check
cp -a /nfs/home/leizhenyu/opt/arch-fuzz-add-am-system/generators/system/minios \
  /tmp/minios-patch-apply-check/minios
patch -d /tmp/minios-patch-apply-check -p0 \
  < /nfs/home/leizhenyu/opt/testbench/targets/boom/patches/minios-meltdown-us-smoke.patch
```

Initial build and Spike smoke command:

```bash
timeout 90s make -C /tmp/minios-meltdown-work2/minios \
  BUILD_DIR=/tmp/minios-meltdown-work2-build-halt \
  CPUS=1 VM_MODE=sv39 MELTDOWN_US=1 BOOT_DEBUG=0 SPIKE_TIMEOUT=60 \
  PASS_SENTINEL='meltdown-us: done' spike-pass
```

Initial result, before increasing the smoke attempt count:

```text
meltdown-us: secret_va=0x20000000 attempts=8
meltdown-us: fault recovery ok
meltdown-us: done
SPIKE: PASS
real 4.57
```

After adding the optional timing code but leaving `MELTDOWN_US_TIMING=0`, the
default smoke still passes:

```text
meltdown-us: secret_va=0x20000000 attempts=16
meltdown-us: fault recovery ok
meltdown-us: done
SPIKE: PASS
real 4.80
```

Initial BOOM v3 smoke command, before increasing the smoke attempt count:

```bash
/usr/bin/time -p timeout 10m \
  /nfs/home/leizhenyu/opt/DUTs/boom/chipyard/sims/verilator/simulator-chipyard.harness-MediumBoomV3Config \
  +permissive +max-cycles=3000000000 \
  +loadmem=/tmp/minios-meltdown-work2-build-halt/minios.spike.elf \
  +permissive-off /tmp/minios-meltdown-work2-build-halt/minios.spike.elf \
  2>&1 | tee targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-smoke-tiny-halt.log
```

Initial BOOM v3 result:

```text
minios booting on core 0
minios core 0 installed sv39 kpt 0x807f7000 satp 0x80000000000807f7
meltdown-us: secret_va=0x20000000 attempts=8
meltdown-us: fault recovery ok
meltdown-us: done
Verilog $finish
real 213.79
```

## Timing Experiment Status

An experimental timing path was added behind `MELTDOWN_US_TIMING=1`. It adds:

- eviction-buffer based `flush_line()`;
- randomized probe reload order;
- CLINT `mtime` based load timing;
- top-two score reporting for secret byte `0x53`.

This path is runnable, but not yet a successful leakage demo.

Failed counter-access attempt:

- Direct M-mode write of both `mcounteren` and `scounteren` before `mret`
  prevented the system from reaching the user program.
- Splitting it into M-mode `mcounteren` and S-mode `scounteren` allowed boot to
  reach the scheduler, but the Spike run still timed out before
  `meltdown-us: done`.
- Enabling only `mcounteren` and reading `cycle` in the S-mode syscall also
  timed out before `meltdown-us: done`, so the committed timing path uses
  CLINT `mtime` instead of CSR `cycle`.
- A later guarded `MELTDOWN_US_CYCLE_TIMING=1` prototype still timed out after
  entering the scheduler on Spike:

```text
minios booting on core 0
minios core 0 installed sv39 kpt 0x807f7000 satp 0x80000000000807f7
SPIKE: FAIL (timeout waiting for meltdown-us: done)
real 104.69
```

Further isolation split `mcounteren` setup from the actual `cycle` read:

- `MELTDOWN_US_ENABLE_COUNTEREN=1` with `MELTDOWN_US_CYCLE_TIMING=0` still
  timed out after installing the kernel page table, before user output:

```text
minios booting on core 0
minios core 0 installed sv39 kpt 0x807f7000 satp 0x80000000000807f7
SPIKE: FAIL (timeout waiting for meltdown-us: done)
real 104.75
```

- `MELTDOWN_US_MCYCLE_TIMING=1` avoids `mcounteren` and tries to read `mcycle`
  directly from the S-mode syscall. Spike rejects this with an illegal
  instruction trap:

```text
meltdown-us: main begin
meltdown-us: secret_va=0x20000000 attempts=1
[trap] unexpected kernel trap scause=0x2 sepc=0x80006512 stval=0xb0002873
panic: [trap] unexpected kernel trap
real 4.76
```

`stval=0xb0002873` is the faulting CSR-read instruction for `mcycle`. The
current conclusion is that neither `cycle` via `mcounteren` nor direct S-mode
`mcycle` is viable in this Spike/miniOS setup without a deeper privilege/timer
change.

Current kernel-side `mtime` path:

```bash
timeout 120s make -C /tmp/minios-meltdown-work2/minios \
  BUILD_DIR=/tmp/minios-meltdown-work2-build-ktiming2 \
  CPUS=1 VM_MODE=sv39 MELTDOWN_US=1 MELTDOWN_US_TIMING=1 \
  BOOT_DEBUG=0 SPIKE_TIMEOUT=100 PASS_SENTINEL='meltdown-us: done' spike-pass
```

Spike result with default `MELTDOWN_US_TIME_REPS=64`:

```text
meltdown-us: timing hit=0 miss=0 threshold=0
meltdown-us: score best=0x0/16 second=0x1/16 secret=0x53
meltdown-us: leak candidate miss
SPIKE: PASS
real 4.69
```

Spike result with `MELTDOWN_US_ATTEMPTS=1 MELTDOWN_US_TIME_REPS=4096`:

```text
meltdown-us: timing hit=150 miss=150 threshold=150
meltdown-us: score best=0x2/1 second=0x3/1 secret=0x53
meltdown-us: leak candidate miss
SPIKE: PASS
real 4.69
```

BOOM v3 result with `MELTDOWN_US_ATTEMPTS=1 MELTDOWN_US_TIME_REPS=4096`:

```bash
/usr/bin/time -p timeout 10m \
  /nfs/home/leizhenyu/opt/DUTs/boom/chipyard/sims/verilator/simulator-chipyard.harness-MediumBoomV3Config \
  +permissive +max-cycles=3000000000 \
  +loadmem=/tmp/minios-meltdown-work2-build-ktiming-r4096/minios.spike.elf \
  +permissive-off /tmp/minios-meltdown-work2-build-ktiming-r4096/minios.spike.elf \
  2>&1 | tee targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-ktiming-r4096.log
```

```text
meltdown-us: timing hit=9 miss=8 threshold=8
meltdown-us: score best=0x9/1 second=0xa/1 secret=0x53
meltdown-us: leak candidate miss
real 569.17
```

Interpretation: the BOOM run reaches the measurement phase and gets nonzero
timing values, but it does not recover secret byte `0x53`. The best index is
noise, so the Meltdown leakage objective remains open.

After adding `SYS_meltdown_flush_probe`, the same BOOM v3 run completed:

```bash
/usr/bin/time -p timeout 10m \
  /nfs/home/leizhenyu/opt/DUTs/boom/chipyard/sims/verilator/simulator-chipyard.harness-MediumBoomV3Config \
  +permissive +max-cycles=3000000000 \
  +loadmem=/tmp/minios-meltdown-work2-build-kflush-r4096/minios.spike.elf \
  +permissive-off /tmp/minios-meltdown-work2-build-kflush-r4096/minios.spike.elf \
  2>&1 | tee targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-kflush-r4096.log
```

```text
meltdown-us: timing hit=9 miss=9 threshold=9
meltdown-us: fault recovery ok
meltdown-us: score best=0x0/1 second=0x1/1 secret=0x53
meltdown-us: leak candidate miss
meltdown-us: done
real 594.03
```

The explicit flush keeps the experiment structurally cleaner, but it still does
not recover `0x53`. The BOOM/Verilator `mtime` measurements remain too coarse
for a useful hit/miss split in this configuration.

Raw timing diagnostics were then added with
`MELTDOWN_US_DEBUG_TIMES=1`. A full-scan BOOM run printed the selected buckets
but hit the outer 10-minute timeout before completing the 256-bucket scan:

```text
meltdown-us: timing hit=9 miss=9 threshold=9
meltdown-us: raw attempt=0 i0=9 i1=9 i52=9 i53=9 i54=9
real 600.01
```

The cheaper `MELTDOWN_US_DEBUG_ONLY=1` mode skips the full scan after printing
raw bucket timings. BOOM v3 completed this run:

```text
meltdown-us: timing hit=9 miss=9 threshold=9
meltdown-us: raw attempt=0 i0=10 i1=9 i52=9 i53=9 i54=9
meltdown-us: fault recovery ok
meltdown-us: debug-only done secret=0x53
meltdown-us: done
real 316.49
```

This confirms the current BOOM v3 `mtime` path does not show a distinctive
timing signal for bucket `0x53`; the secret bucket is indistinguishable from
neighbor and baseline buckets in this diagnostic.

## M-mode Cycle Timing Update

The patch now also includes `MELTDOWN_US_MMODE_CYCLE_TIMING=1`, a guarded
M-mode `mcycle` service. The miniOS boot code keeps S-mode ecall undelegated
when this knob is enabled, installs `machinevec`, and handles a magic
`a7=0x4d435943` ecall by reading `mcycle` in M-mode and returning it to the
S-mode syscall path.

This avoids both earlier counter failures:

- no `mcounteren` write is required, so Spike user scheduling still reaches the
  Meltdown test;
- S-mode never executes `csrr mcycle`, so the illegal instruction trap is
  avoided.

Spike smoke with `MELTDOWN_US_MMODE_CYCLE_TIMING=1`,
`MELTDOWN_US_DEBUG_ONLY=1`, and `MELTDOWN_US_TIME_REPS=64` passes:

```text
meltdown-us: timing hit=292 miss=292 threshold=292
meltdown-us: raw attempt=0 i0=292 i1=292 i52=292 i53=292 i54=292
meltdown-us: fault recovery ok
meltdown-us: debug-only done secret=0x53
meltdown-us: done
SPIKE: PASS
real 4.76
```

BOOM v3 can also run this timing path to completion. With the original gadget
and `MELTDOWN_US_TIME_REPS=64`, BOOM v3 produced a usable hit/miss calibration
but did not leak the secret bucket:

```text
meltdown-us: timing hit=352 miss=411 threshold=381
meltdown-us: raw attempt=0 i0=377 i1=418 i52=383 i53=391 i54=389
meltdown-us: fault recovery ok
meltdown-us: debug-only done secret=0x53
meltdown-us: done
real 311.62
```

The current user gadget has been adjusted to use `lbu` for the faulting byte
load and a non-zero destination register for the dependent probe load:

```asm
lbu  t0, 0(secret_va)
slli t0, t0, 6
add  t0, t0, probe
lb   t1, 0(t0)
```

BOOM v3 still does not show a reliable secret-specific cache footprint with
this gadget:

```text
MELTDOWN_US_TIME_REPS=1
meltdown-us: timing hit=236 miss=223 threshold=229
meltdown-us: raw attempt=0 i0=240 i1=282 i52=272 i53=240 i54=240
real 345.21

MELTDOWN_US_TIME_REPS=8
meltdown-us: timing hit=254 miss=246 threshold=250
meltdown-us: raw attempt=0 i0=257 i1=273 i52=265 i53=249 i54=249
real 336.30
```

Interpretation: the privilege setup, fault recovery, and cycle-level timing
path are now working on BOOM v3, but byte `0x53` has not been recovered. The
remaining problem is the leakage mechanism itself: the faulting supervisor-only
load does not yet leave a distinguishable dependent probe access in the cache.

The timing path now also supports:

- `MELTDOWN_US_CAL_REPS`: repeats hot/cold calibration and reports minimum hot
  latency plus maximum cold latency. `CAL_REPS=5` fixed the earlier hit/miss
  reversal in BOOM v3 debug runs.
- `MELTDOWN_US_PROBE_STRIDE`: changes probe spacing. `512` is practical on
  BOOM v3 but still shows clustered adjacent bucket hits; `4096` passes Spike
  but is too slow for the current BOOM debug path.
- `MELTDOWN_US_GADGET_DELAY`: inserts independent ALU instructions between the
  faulting load and dependent probe load. BOOM v3 delay points `4` and `16`
  still produce clustered nearby bucket hits, so this knob is useful for
  diagnosis but has not produced a successful leak.

The latest BOOM v3 diagnostic with `PROBE_STRIDE=512`:

```text
meltdown-us: timing hit=209 miss=239 threshold=224
meltdown-us: raw attempt=0 i0=286 i1=255 i50=255 i51=255 i52=248 i53=248 i54=248 i55=259 i56=248
meltdown-us: raw attempt=1 i0=255 i1=255 i50=285 i51=259 i52=248 i53=248 i54=248 i55=259 i56=248
real 382.37
```

This remains a negative leakage result because several neighboring buckets
reach hit latency together.

Follow-up BOOM v3 diagnostics tested whether the apparent neighboring hits
were measurement-order artifacts and whether the faulting load needed a
different dependency chain or a hot secret line:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-mmodecycle-cal5-mixed-debugonly-r8-a2.log
MELTDOWN_US_PROBE_STRIDE=64
MELTDOWN_US_TIME_REPS=8
MELTDOWN_US_CAL_REPS=5
meltdown-us: timing hit=208 miss=274 threshold=241
meltdown-us: raw attempt=0 i53=298 i0=255 i80=285 i1=248 i55=248 i51=248 i56=248 i50=255 i54=259 i52=248
meltdown-us: raw attempt=1 i53=300 i0=255 i80=255 i1=255 i55=248 i51=248 i56=260 i50=255 i54=248 i52=248
real 355.45
```

With `i53` measured first it is cold, so the earlier adjacent-bucket fast
results were not a clean leak.

`MELTDOWN_US_GADGET_VARIANT=1` adds a pointer-table dependency
(`secret -> pointer table -> probe bucket`) while preserving the original
direct gadget as variant `0`:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-mmodecycle-cal5-var1-debugonly-r8-a2.log
meltdown-us: timing hit=208 miss=274 threshold=241
meltdown-us: raw attempt=0 i53=271 i0=285 i80=248 i1=314 i55=254 i51=254 i56=248 i50=248 i54=255 i52=248
meltdown-us: raw attempt=1 i53=271 i0=276 i80=285 i1=259 i55=248 i51=264 i56=248 i50=255 i54=255 i52=248
real 403.68
```

`MELTDOWN_US_TOUCH_SECRET_ON_ARM=1` makes `SYS_meltdown_arm` touch the
supervisor-only secret page in S-mode immediately before returning to U-mode,
so the faulting secret load should hit in cache:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-mmodecycle-cal5-touch-debugonly-r8-a2.log
meltdown-us: timing hit=209 miss=239 threshold=224
meltdown-us: raw attempt=0 i53=272 i0=256 i80=256 i1=272 i55=256 i51=256 i56=256 i50=256 i54=256 i52=262
meltdown-us: raw attempt=1 i53=272 i0=256 i80=249 i1=291 i55=256 i51=249 i56=260 i50=249 i54=249 i52=249
real 416.85
```

Both are negative leakage results. The current patch therefore provides a
reproducible miniOS Meltdown-US harness and BOOM v3 diagnostics, but it has
not yet recovered secret byte `0x53`.

`MELTDOWN_US_TRAIN_USER_ACCESS=1` was added for a stronger permission-sequence
test. In this mode each attempt temporarily sets `PTE_U` for the secret page,
performs a real U-mode load from the same VA, clears `PTE_U`, and then runs the
faulting gadget. Spike confirms the training load returns the secret:

```text
meltdown-us: training value=0x53
SPIKE: PASS
real 4.82
```

BOOM v3 still does not recover the secret:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-mmodecycle-cal5-trainu-debugonly-r8-a2.log
MELTDOWN_US_TRAIN_USER_ACCESS=1
meltdown-us: timing hit=209 miss=245 threshold=227
meltdown-us: training value=0x53
meltdown-us: raw attempt=0 i53=291 i0=261 i80=256 i1=272 i55=272 i51=256 i56=256 i50=249 i54=260 i52=256
meltdown-us: raw attempt=1 i53=272 i0=256 i80=256 i1=285 i55=256 i51=256 i56=256 i50=256 i54=249 i52=249
real 414.88
```

This narrows the remaining issue: even after a successful U-mode training load
from the same VA and an immediate `PTE_U` clear, BOOM v3 does not forward the
supervisor-only faulting load value into the dependent probe access.

`MELTDOWN_US_DEBUG_RESIDENCY=1` adds an S-mode diagnostic syscall that times the
secret line, `probe[0x53]`, and `probe[0]` before and after the faulting gadget.
This is a diagnostic only: it touches `probe[0x53]`, so any raw bucket timing
printed after it is polluted by the diagnostic.

Spike smoke:

```text
meltdown-us: training value=0x53
meltdown-us: residency pre attempt=0 secret=76 p53=68 p0=68
meltdown-us: residency post attempt=0 secret=76 p53=68 p0=68
SPIKE: PASS
real 4.84
```

BOOM v3:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-mmodecycle-cal5-resid-debugonly-r8-a1.log
MELTDOWN_US_ATTEMPTS=1
meltdown-us: timing hit=208 miss=274 threshold=241
meltdown-us: training value=0x53
meltdown-us: residency pre attempt=0 secret=301 p53=278 p0=245
meltdown-us: residency post attempt=0 secret=268 p53=227 p0=261
meltdown-us: raw attempt=0 i53=239 i0=271 i80=254 i1=264 i55=248 i51=248 i56=254 i50=248 i54=248 i52=255
real 379.95
```

The important observation is that the secret line is not measured as hot by the
S-mode timing path after the U-mode training and permission switch. The later
`i53=239` cannot be considered a successful leak because the residency
diagnostic has already touched `probe[0x53]`.

`MELTDOWN_US_PRELOAD_ON_CLEAR=1` then tested a non-diagnostic secret-only
preload. In this mode `meltdown_set_secret_user(2)` clears `PTE_U`, executes
`sfence.vma`, and touches the secret page in S-mode before returning to the
faulting U-mode gadget. No probe bucket is touched before raw timing.

BOOM v3, two attempts timed out at the wrapper limit after attempt 0:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-mmodecycle-cal5-preloadclear-debugonly-r8-a2.log
meltdown-us: timing hit=208 miss=274 threshold=241
meltdown-us: training value=0x53
meltdown-us: raw attempt=0 i53=290 i0=255 i80=255 i1=248 i55=248 i51=248 i56=259 i50=248 i54=248 i52=248
real 420.01
```

BOOM v3, one attempt exits cleanly:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-mmodecycle-cal5-preloadclear-debugonly-r8-a1.log
meltdown-us: timing hit=208 miss=281 threshold=244
meltdown-us: training value=0x53
meltdown-us: raw attempt=0 i53=300 i0=248 i80=248 i1=259 i55=248 i51=248 i56=248 i50=248 i54=248 i52=248
meltdown-us: fault recovery ok
meltdown-us: done
real 391.45
```

This is still negative. Immediate S-mode preloading after clear-U does not
produce a clean `0x53` probe hit.

`MELTDOWN_US_TRAIN_ALIAS=1` adds a second user-readable alias for the same
secret physical page at `0x20001000`. The attack still uses the supervisor-only
VA at `0x20000000`, but each attempt first reads the alias to train/cache the
secret data without toggling the attacked PTE.

Spike smoke:

```text
meltdown-us: timing hit=68 miss=89 threshold=78
meltdown-us: alias_va=0x20001000 training value=0x53
meltdown-us: raw attempt=0 i53=68 i0=68 i80=68 i1=68 i55=68 i51=68 i56=68 i50=68 i54=68 i52=68
SPIKE: PASS
real 4.83
```

BOOM v3 is still negative:

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

The alias path confirms that the same physical page can be user-read and
contains `0x53`, but the supervisor-only faulting VA still does not forward the
secret into the dependent probe access.

`MELTDOWN_US_PMP_FAULT=1` adds a separate access-fault experiment. In this
mode the secret VA is mapped `PTE_U=1`, then an M-mode ecall programs PMP as
three TOR regions:

- allow `[0, secret_start)`;
- deny `[secret_start, secret_end)`;
- allow `[secret_end, top)`.

Spike verifies the dynamic PMP path and recovery:

```text
meltdown-us: fault_mode=pmp-access
meltdown-us: pmp training value=0x53
meltdown-us: pmp deny armed
meltdown-us: fault recovery ok
meltdown-us: done
SPIKE: PASS
real 0.22
```

Spike timing smoke also exits:

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

BOOM v3 does not complete the PMP fault/recovery path. The timing build reaches
PMP deny and then times out before raw timing:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-pmp-debugonly-r8-a1.log
meltdown-us: fault_mode=pmp-access
meltdown-us: timing hit=210 miss=274 threshold=242
meltdown-us: pmp training value=0x53
meltdown-us: pmp deny armed
real 420.01
```

The non-timing BOOM smoke also stops at the same point:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-pmp-smoke-a1.log
meltdown-us: fault_mode=pmp-access
meltdown-us: pmp training value=0x53
meltdown-us: pmp deny armed
real 300.01
```

This means the PMP route is a useful miniOS extension and works in Spike, but
it is not yet a BOOM v3 Meltdown leakage demo. On BOOM v3 the dynamic PMP deny
is reached, but the following U-mode access-fault recovery does not complete
within the tested wrapper limits.

Follow-up diagnostics add two guarded knobs:

- `MELTDOWN_US_PMP_SIMPLE_FAULT=1`: arm recovery and execute only one `lbu`
  from the PMP-denied secret VA, without the transient probe gadget.
- `MELTDOWN_US_MMODE_FAULT_SKIP=1`: if a load access fault reaches M-mode
  instead of S-mode, skip the faulting instruction in `machinevec`. This is a
  diagnostic recovery path, not the normal miniOS usertrap path.

Spike simple-fault debug confirms the expected S-mode trap:

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

BOOM v3 simple-fault debug without M-mode skip still stops at `pmp deny armed`
and never prints the S-mode trap line:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-pmp-simple-debug-a1.log
meltdown-us: pmp_simple_fault=1
meltdown-us: pmp training value=0x53
meltdown-us: pmp deny armed
real 300.01
```

BOOM v3 simple-fault debug with M-mode skip completes:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-pmp-simple-mskip-a1.log
meltdown-us: pmp_simple_fault=1
meltdown-us: pmp training value=0x53
meltdown-us: pmp deny armed
meltdown-us: fault recovery ok
meltdown-us: done
real 290.37
```

This proves the previous BOOM hang was the M-mode unknown-trap loop, not the
cache-timing or transient gadget code. In this BOOM configuration, the PMP load
access fault is not reaching the S-mode `usertrap()` path even though the same
ELF does on Spike.

With M-mode skip enabled, the full transient PMP debug-only run reaches raw
timing on BOOM v3 but is still negative:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-pmp-mskip-debugonly-r8-a1.log
MELTDOWN_US_MMODE_FAULT_SKIP=1
MELTDOWN_US_TIMING=1
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

`i53=300` is slower than the threshold and slower than most controls, so even
with diagnostic M-mode recovery this is not a successful Meltdown leak.

The PMP/M-mode-skip path was also tested with
`MELTDOWN_US_GADGET_VARIANT=3`, the fixed `probe[0x53]` fault-window
diagnostic. This compares PMP against the page-permission no-sfence path for a
younger load that is independent of the secret value.

Spike smoke passes:

```text
MELTDOWN_US_PMP_FAULT=1
MELTDOWN_US_MMODE_FAULT_SKIP=1
MELTDOWN_US_GADGET_VARIANT=3
meltdown-us: fault_mode=pmp-access
meltdown-us: pmp training value=0x53
meltdown-us: pmp deny armed
meltdown-us: raw attempt=0 i53=68 i0=68 i80=68 i1=68 i55=68 i51=68 i56=68 i50=68 i54=68 i52=68
SPIKE: PASS
```

BOOM v3 reaches raw timing but remains negative:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-pmp-mskip-c1-var3-touch16-debugonly-r8-a1.log
meltdown-us: timing hit=210 miss=242 threshold=226
meltdown-us: pmp training value=0x53
meltdown-us: pmp deny armed
meltdown-us: raw attempt=0 i53=241 i0=296 i80=288 i1=321 i55=250 i51=266 i56=250 i50=250 i54=257 i52=257
real 377.36
```

This is closer to threshold than the page-permission no-sfence fixed-touch
run, but it is still negative because `i53=241` is above the `226` threshold.

## Clear-U Without SFENCE Diagnostic

`MELTDOWN_US_CLEAR_NO_SFENCE=1` adds one more U/S page-permission variant:
after confirming a user-readable secret mapping returns `0x53`, the kernel
clears `PTE_U` without executing `sfence.vma`, then the user gadget performs
the normal faulting load. This checks whether a stale translation creates a
wider BOOM transient window.

Spike reaches the expected recovery path:

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

BOOM v3 also reaches page-fault recovery, but the secret bucket is not a hit:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nosfence-debugonly-r8-a1.log
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

The no-sfence path is therefore another negative BOOM v3 leakage result:
`i53=273` is above the `241` threshold.

Repeated no-sfence debug-only runs were used to check for rare successful
attempts. The clean two-attempt run completed and remained negative:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nosfence-debugonly-r8-a2clean.log
meltdown-us: timing hit=208 miss=250 threshold=229
meltdown-us: raw attempt=0 i53=271 i0=261 i80=296 i1=265 i55=248 i51=252 i56=259 i50=248 i54=248 i52=248
meltdown-us: raw attempt=1 i53=264 i0=248 i80=285 i1=301 i55=248 i51=248 i56=248 i50=248 i54=248 i52=248
meltdown-us: fault recovery ok
meltdown-us: done
real 432.99
```

The measured no-sfence success rate for the clean repeated run is `0/2`.
Three- and four-attempt runs timed out at 480 seconds after producing only
partial raw measurements; those partial samples were also negative but are not
counted in the clean success-rate denominator.

## Clear Accessed-Bit Diagnostic

`MELTDOWN_US_CLEAR_ACCESSED=1` keeps the secret page user-readable, then clears
`PTE_A` after the training load and flushes the TLB. The following user load
faults on the accessed bit rather than on U/S permission. This is intended to
test whether a permission-allowed load that faults on page-table state creates
a different BOOM transient window.

Spike confirms that the variant traps and recovers:

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

BOOM v3 reaches the same recovery point but remains negative:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-clearA-debugonly-r8-a1.log
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

`i53=290` is above the `241` threshold, so the accessed-bit fault source also
does not produce a secret-specific cache footprint on BOOM v3.

The accessed-bit source was also combined with
`MELTDOWN_US_GADGET_VARIANT=3`, the fixed `probe[0x53]` fault-window
diagnostic. This variant is not a leakage gadget; it checks whether a younger
independent load can leave a measurable footprint after the A-bit fault.

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
meltdown-us: timing hit=208 miss=274 threshold=241
meltdown-us: training value=0x53
meltdown-us: raw attempt=0 i53=255 i0=281 i80=309 i1=313 i55=309 i51=259 i56=285 i50=258 i54=273 i52=279
meltdown-us: fault recovery ok
meltdown-us: debug-only done secret=0x53
meltdown-us: done
real 374.84
```

The fixed-touch A-bit diagnostic is still negative because `i53=255` is above
the `241` threshold. Alongside the no-sfence fixed-touch diagnostic
(`255 > 241`) and the PMP/M-mode-skip fixed-touch diagnostic (`241 > 226`),
this indicates that the tested BOOM v3 fault sources are squashing or blocking
younger loads before they leave a stable cache footprint.

## Non-Faulting Positive-Control Diagnostics

The patch now includes two non-faulting controls to separate Meltdown fault
behavior from the cache measurement path.

`MELTDOWN_US_NO_FAULT=1` keeps the secret page user-readable and runs the same
secret-indexed gadget legally. BOOM v3 completes, but the selected bucket is
not clearly hot:

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

`MELTDOWN_US_TOUCH_PROBE_CONTROL=1` is stronger: it skips the secret load and
directly touches `probe[0x53]` after flushing the probe array. Spike verifies
that the control path builds and exits:

```text
MELTDOWN_US_TOUCH_PROBE_CONTROL=1
MELTDOWN_US_GADGET_TOUCH_REPEATS=16
meltdown-us: touch_probe_control=1
meltdown-us: raw attempt=0 i53=68 i0=68 i80=68 i1=68 i55=89 i51=68 i56=68 i50=68 i54=68 i52=68
meltdown-us: done
SPIKE: PASS
real 4.94
```

The BOOM v3 run for this direct touch-probe control did not reach user mode
within the wrapper:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-touchprobe-debugonly-r8-a1.log
minios booting on core 0
minios core 0 installed sv39 kpt 0x807f7000 satp 0x80000000000807f7
[UART] UART0 is here (stdin/stdout).
real 420.01
```

A 10-minute retry was interrupted after it again failed to reach
`meltdown-us: main begin`. This remains a BOOM run/timeout issue for the
diagnostic ELF, not a cache-timing pass/fail result.

## Single-Core Positive-Control Follow-Up

Using `CPUS=1` and `MELTDOWN_US_NPROC=4` makes the direct touch-probe diagnostic
complete on BOOM v3:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-touchprobe-c1-debugonly-r8-a1.log
MELTDOWN_US_TOUCH_PROBE_CONTROL=1
MELTDOWN_US_GADGET_TOUCH_REPEATS=16
meltdown-us: timing hit=208 miss=274 threshold=241
meltdown-us: raw attempt=0 i53=239 i0=290 i80=248 i1=259 i55=248 i51=248 i56=255 i50=248 i54=248 i52=248
meltdown-us: done
real 381.59
```

The legal no-fault secret-indexed gadget produces the same weak `0x53` hit:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nofault-c1-touch16-debugonly-r8-a1.log
MELTDOWN_US_NO_FAULT=1
MELTDOWN_US_TRAIN_USER_ACCESS=1
MELTDOWN_US_GADGET_TOUCH_REPEATS=16
meltdown-us: timing hit=208 miss=274 threshold=241
meltdown-us: training value=0x53
meltdown-us: raw attempt=0 i53=239 i0=254 i80=248 i1=259 i55=277 i51=248 i56=248 i50=248 i54=248 i52=252
meltdown-us: done
real 362.82
```

The comparable single-core no-sfence faulting run still fails to leak:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nosfence-c1-debugonly-r8-a1.log
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

This changes the diagnosis: the raw timing path and legal secret-indexed
gadget are weak but functional on BOOM v3. The remaining blocker is the
faulting/transient path.

## Latest Single-Core Parameter Sweep

The next increment tested whether the single-core legal positive control could
be strengthened before spending more BOOM time on matching faulting runs.

`MELTDOWN_US_GADGET_DELAY=16` and `MELTDOWN_US_GADGET_DELAY=4` were both tested
with `CPUS=1`, `MELTDOWN_US_NPROC=4`,
`MELTDOWN_US_GADGET_TOUCH_REPEATS=16`, `MELTDOWN_US_TIME_REPS=8`, and the legal
`MELTDOWN_US_NO_FAULT=1` gadget:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nofault-c1-delay16-touch16-debugonly-r8-a1.log
meltdown-us: timing hit=208 miss=281 threshold=244
meltdown-us: raw attempt=0 i53=255 i0=301 i80=248 i1=289 i55=248 i51=252 i56=248 i50=248 i54=248 i52=248
real 366.91

log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nofault-c1-delay4-touch16-debugonly-r8-a1.log
meltdown-us: timing hit=208 miss=274 threshold=241
meltdown-us: raw attempt=0 i53=298 i0=291 i80=317 i1=299 i55=258 i51=254 i56=290 i50=258 i54=248 i52=254
real 379.69
```

Both delay runs are negative even though they are legal no-fault controls. The
independent delay chain therefore does not improve the current gadget; it makes
the already weak positive control worse.

The no-delay legal positive control was also rerun with
`MELTDOWN_US_TIME_REPS=16`:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nofault-c1-touch16-debugonly-r16-a1.log
meltdown-us: timing hit=224 miss=299 threshold=261
meltdown-us: raw attempt=0 i53=258 i0=269 i80=266 i1=312 i55=276 i51=276 i56=276 i50=276 i54=276 i52=276
real 373.84
```

This is still only a weak positive control: bucket `0x53` is three cycles below
threshold. Because neither delay tuning nor `TIME_REPS=16` produced a stronger
legal signal, the matching no-sfence delay and no-sfence `TIME_REPS=16` BOOM
runs were not launched.

`MELTDOWN_US_GADGET_VARIANT=2` was then added. It keeps the direct
secret-indexed bucket selection but touches four offsets inside the selected
64-byte cache line. The goal was to amplify the cache footprint without
touching neighboring buckets.

Spike smoke passed for both legal no-fault and no-sfence faulting builds.

BOOM v3 legal no-fault control:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nofault-c1-var2-touch16-debugonly-r8-a1.log
meltdown-us: timing hit=208 miss=274 threshold=241
meltdown-us: raw attempt=0 i53=239 i0=248 i80=285 i1=264 i55=248 i51=248 i56=248 i50=248 i54=248 i52=248
real 400.65
```

BOOM v3 matching no-sfence faulting run:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nosfence-c1-var2-touch16-debugonly-r8-a1.log
meltdown-us: timing hit=208 miss=245 threshold=226
meltdown-us: raw attempt=0 i53=271 i0=324 i80=248 i1=260 i55=263 i51=308 i56=284 i50=255 i54=310 i52=274
real 363.87
```

Variant 2 preserves the weak legal positive control, but the faulting run is
still negative because `i53=271` is above the `226` threshold.

`MELTDOWN_US_GADGET_VARIANT=3` was added as a fault-window diagnostic. It
performs the supervisor-only load first, then touches fixed `probe[0x53]`
independently of the loaded secret value. This is not a leakage gadget; it
checks whether any younger load after the faulting load can leave a cache
footprint in the current no-sfence page-permission path.

Spike smoke passed for both legal no-fault and no-sfence faulting builds.

BOOM v3 legal no-fault control:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nofault-c1-var3b-touch16-debugonly-r8-a1.log
meltdown-us: timing hit=208 miss=285 threshold=246
meltdown-us: raw attempt=0 i53=239 i0=302 i80=254 i1=289 i55=248 i51=248 i56=259 i50=248 i54=248 i52=248
real 400.61
```

BOOM v3 matching no-sfence faulting run:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nosfence-c1-var3b-touch16-debugonly-r8-a1.log
meltdown-us: timing hit=208 miss=274 threshold=241
meltdown-us: raw attempt=0 i53=255 i0=286 i80=248 i1=290 i55=263 i51=248 i56=248 i50=248 i54=252 i52=248
real 378.30
```

The legal fixed-touch control is positive (`239 < 246`), but the faulting
fixed-touch run is negative (`255 > 241`). This narrows the current blocker:
under the tested BOOM v3 no-sfence page-permission sequence, even a younger
load independent of the secret does not leave a stable cache footprint after
the supervisor-only faulting load.

`MELTDOWN_US_GADGET_VARIANT=4` was added to amplify that diagnostic. It still
uses constant probe indices, but it issues several independent fixed probe
loads after the faulting load: `0x53`, `0x51`, `0x55`, and `0x80`.

Spike smoke passed for both legal no-fault and accessed-bit faulting builds.

BOOM v3 legal no-fault control:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-nofault-c1-var4-debugonly-r8-a1.log
meltdown-us: timing hit=208 miss=280 threshold=244
meltdown-us: raw attempt=0 i53=239 i0=266 i80=248 i1=248 i55=232 i51=232 i56=248 i50=252 i54=248 i52=248
real 370.43
```

This confirms the widened fixed-touch gadget is observable on BOOM v3 without
a fault: `i53=239`, `i55=232`, and `i51=232` are below threshold.

BOOM v3 accessed-bit faulting run:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-clearA-c1-var4-touch16-debugonly-r8-a1.log
meltdown-us: timing hit=208 miss=274 threshold=241
meltdown-us: raw attempt=0 i53=271 i0=248 i80=248 i1=289 i55=248 i51=248 i56=259 i50=248 i54=248 i52=248
real 384.69
```

The target bucket remains cold (`i53=271 > 241`). Some fixed buckets are near
the low-latency range (`i80/i55/i51=248`), but none crosses the threshold. This
keeps the BOOM v3 accessed-bit path negative and suggests the fault window is
still too narrow or too aggressively squashed for a stable younger-load cache
footprint.

The widened fixed-touch diagnostic is more promising on the PMP/M-mode-skip
fault source:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-pmp-mskip-c1-var4-debugonly-r8-a1.log
meltdown-us: timing hit=210 miss=289 threshold=249
meltdown-us: pmp training value=0x53
meltdown-us: pmp deny armed
meltdown-us: raw attempt=0 i53=241 i0=342 i80=288 i1=250 i55=263 i51=263 i56=250 i50=257 i54=257 i52=263
real 377.81
```

This is a positive fault-window diagnostic (`i53=241 < 249`), but it is not a
Meltdown leak because variant 4 hard-codes the selected bucket.

Two real secret-dependent PMP/M-mode-skip runs were then tried. Direct variant
0 remains negative:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-pmp-mskip-c1-var0-debugonly-r8-a1.log
meltdown-us: timing hit=210 miss=276 threshold=243
meltdown-us: pmp training value=0x53
meltdown-us: pmp deny armed
meltdown-us: raw attempt=0 i53=260 i0=292 i80=288 i1=257 i55=257 i51=250 i56=261 i50=257 i54=257 i52=261
real 385.80
```

Selected-line amplification variant 2 is also negative:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-pmp-mskip-c1-var2-debugonly-r8-a1.log
meltdown-us: timing hit=210 miss=276 threshold=243
meltdown-us: pmp training value=0x53
meltdown-us: pmp deny armed
meltdown-us: raw attempt=0 i53=261 i0=305 i80=261 i1=291 i55=250 i51=265 i56=250 i50=250 i54=250 i52=257
real 354.93
```

Variant 5 shortens the secret-dependent address chain with a pointer-table
lookup: `lbu secret`, mask to byte, shift by three, load the bucket pointer,
then load the selected bucket. Spike smoke passed, but BOOM v3 remains
negative:

```text
log: targets/boom/logs/MediumBoomV3Config-minios-meltdown-us-pmp-mskip-c1-var5-debugonly-r8-a1.log
meltdown-us: timing hit=210 miss=305 threshold=257
meltdown-us: pmp training value=0x53
meltdown-us: pmp deny armed
meltdown-us: raw attempt=0 i53=257 i0=308 i80=256 i1=279 i55=250 i51=251 i56=250 i50=250 i54=250 i52=258
real 376.08
```

This is not a recovery of `0x53`: `i53` only equals threshold and is slower
than several neighboring/control buckets.

The current best interpretation is that PMP/M-mode-skip can expose a weak
younger-load footprint, but BOOM v3 still does not forward the protected secret
byte through the tested dependent probe-address chains.

## Next Step

The current patch establishes the OS privilege conditions needed for
Meltdown-US and several fault/recovery variants. The leakage experiment remains
open because BOOM v3 still does not leak through the tested U/S, no-sfence,
accessed-bit, or PMP secret-dependent fault paths, even though the legal
positive controls and the PMP variant 4 fault-window diagnostic now show weak
`0x53` hits.

The next useful increment should change the faulting gadget structure rather
than only increasing delay or timing repetitions. Candidate directions:

1. Test a different fault source or permission transition that changes when
   BOOM resolves the fault relative to younger loads. The variant 3 diagnostic
   suggests the current page-permission no-sfence and accessed-bit paths squash
   younger loads too early; variant 4 only produces weak near-threshold fixed
   buckets under A-bit faulting, while the PMP/M-mode-skip path can produce a
   fixed-bucket hit but still does not leak through secret-dependent variants 0
   2, or 5.
2. Add a one-attempt full 256-bucket scan only after the debug-only selected
   buckets show `i53` clearly below threshold.
3. Keep `CPUS=1`, `MELTDOWN_US_NPROC=4`, `GADGET_DELAY=0`,
   `GADGET_TOUCH_REPEATS=16`, `TIME_REPS=8`, `CAL_REPS=5`, and
   `PROBE_STRIDE=64` as the current BOOM v3 baseline.
