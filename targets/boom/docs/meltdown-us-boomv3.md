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
