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

- Adds `SYS_meltdown_setup`.
  - Creates a kernel-owned secret page.
  - Maps it into the current user page table at `0x20000000`.
  - Maps it readable but without `PTE_U`.
- Adds `SYS_meltdown_arm`.
  - Lets the user program register a recovery PC before the faulting load.
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

The smoke currently verifies the privilege setup and fault recovery. It does
not yet claim a cache-timing leak.

## Verified

Applied and tested from a clean copy in `/tmp/minios-patch-apply/minios`.

Build and Spike smoke command:

```bash
rm -rf /tmp/minios-patch-apply
mkdir -p /tmp/minios-patch-apply
cp -a /nfs/home/leizhenyu/opt/arch-fuzz-add-am-system/generators/system/minios \
  /tmp/minios-patch-apply/minios
cd /tmp/minios-patch-apply
patch -p0 < /nfs/home/leizhenyu/opt/testbench/targets/boom/patches/minios-meltdown-us-smoke.patch
timeout 90s make -C /tmp/minios-patch-apply/minios \
  BUILD_DIR=/tmp/minios-patch-apply-build \
  CPUS=1 VM_MODE=sv39 MELTDOWN_US=1 SPIKE_TIMEOUT=60 \
  PASS_SENTINEL='meltdown-us: done' spike-pass
```

Result:

```text
meltdown-us: secret_va=0x20000000 attempts=8
meltdown-us: fault recovery ok
meltdown-us: done
SPIKE: PASS
```

## Next Step

The next increment should run the patched spike/HTIF build on BOOM v3 and add
the real measurement phase:

1. Enable or provide a user-accessible cycle counter for BOOM timing.
2. Add probe eviction and randomized probe reload timing.
3. Calibrate a BOOM-specific hit threshold using the existing testbench cache
   calibration method.
4. Run the patched miniOS image through the BOOM runner and record whether
   byte `0x53` is recovered above noise.

The current patch establishes the OS privilege conditions needed for
Meltdown-US; the leakage experiment remains open.
