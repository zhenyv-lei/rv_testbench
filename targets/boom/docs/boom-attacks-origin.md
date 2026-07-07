# BOOMv4 Spectre v1/v2 PoCs

This directory contains a small, self-contained copy of the BOOM Spectre v1/v2
bare-metal PoCs derived from `riscv-boom/boom-attacks`.

## Contents

- `workloads/spectre-v1/src/spectre-v1.c`: Spectre v1 / bounds-check bypass PoC.
- `workloads/spectre-v2/src/spectre-v2.c`: Spectre v2 / branch-target injection PoC.
- `runtime/crt.S`, `runtime/stack.S`, `runtime/syscalls.c`: minimal bare-metal runtime.
- `include/`: RISC-V helpers and cache eviction helper.
- `link/link.ld`: linker script placing the ELF at BOOM DRAM base `0x80000000`.
- `scripts/run-workloads.sh`: build-and-run helper for BOOM Verilator.

The upstream BOOM artifact used `condBranchMispred.c` and
`indirBranchMispred.c`; this testbench keeps those names only in historical
logs and legacy build outputs.

## Build

```bash
cd /nfs/home/leizhenyu/opt/testbench/targets/boom
make all
```

Build only one attack:

```bash
make v1
make v2
```

Experiment knobs can be overridden at build time:

```bash
make clean
make v1 SECRET_SZ=1 ATTACK_SAME_ROUNDS=2
```

## Run On BOOM Verilator

Default run uses `SmallBoomV4Config`, `SECRET_SZ=1`, and
`ATTACK_SAME_ROUNDS=2` for quick calibrated smoke runs.

```bash
./scripts/run-workloads.sh v1
./scripts/run-workloads.sh v2
./scripts/run-workloads.sh all
```

Run the full 6-byte test secret `S3CreT`:

```bash
SECRET_SZ=6 TIMEOUT=2h ./scripts/run-workloads.sh all
```

Select another BOOM config or simulator:

```bash
CONFIG=MediumBoomV4Config ./scripts/run-workloads.sh v2
SIM=/path/to/simulator-chipyard.harness-SmallBoomV4Config ./scripts/run-workloads.sh v1
```

Use DRAMSim instead of the default faster memory model:

```bash
USE_DRAMSIM=1 TIMEOUT=1h ./scripts/run-workloads.sh v2
```

Logs are written to `logs/`.

The current PoCs probe only digit/uppercase/lowercase candidates
(`0-9A-Za-z`) to reduce runtime.

## Notes

The attack programs are bare-metal ELF binaries. BOOM Verilator does not execute
`.c` or `.S` files directly; it executes the linked `.riscv` ELF produced by
`riscv64-unknown-elf-gcc`.

The `.S` files provide the minimal runtime normally supplied by an OS or by a
toolchain runtime: reset entry, stack/TLS setup, trap handling, and
`tohost/fromhost` communication for printing and exiting.
