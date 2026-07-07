# RV64 Spectre PoCs

This directory contains RV64 bare-metal ports of Spectre v1, v2, v4, and v5.

The build flow is:

1. `.c` source is compiled to a RISC-V ELF named `*.riscv`.
2. `objdump` disassembles the ELF into `dump/*.dump`.
3. The BOOM Verilator simulator runs the `*.riscv` ELF. The `.dump` files are
   only for inspection.

Build:

```bash
make -C spectre-type/rv64 all
```

Outputs:

- `build/exec/boom/rv64gc/spectre-v1.riscv`
- `build/exec/boom/rv64gc/spectre-v2.riscv`
- `build/exec/boom/rv64gc/spectre-v4.riscv`
- `build/exec/boom/rv64gc/spectre-v5.riscv`
- `build/exec/boom/rv64gc/spectre-v1-smoke.riscv`
- `build/exec/boom/rv64gc/spectre-v2-smoke.riscv`
- `build/exec/boom/rv64gc/spectre-v4-smoke.riscv`
- `build/exec/boom/rv64gc/spectre-v5-smoke.riscv`

Run on BOOM Verilator:

```bash
make -C spectre-type/rv64 boom-run-spectre-v1
```

Override the config if needed:

```bash
make -C spectre-type/rv64 BOOM_CONFIG=SmallBoomV4Config boom-run-spectre-v2
```

Smoke build:

```bash
make -C spectre-type/rv64 smoke
```

Run the smoke suite on the direct BOOM Verilator simulators:

```bash
scripts/run_boom_spectre_smoke.sh
```

The runner defaults to:

- `MediumBoomV4Config SmallBoomV4Config`
- `spectre-v1 spectre-v2 spectre-v4 spectre-v5`
- `build/exec/boom/rv64gc/*-smoke.riscv`
- `+loadmem=<elf>`

`+loadmem=<elf>` is required for practical direct Verilator runs. Without it,
the same C ELF is loaded through the slow TSI path and can appear to hang before
`main`.

The runner writes `tmp/boom-spectre-logs/summary.tsv`. It reports two separate
verdicts:

- `exec_status`: the ELF entered the benchmark, printed the expected progress
  lines, and exited through the BOOM harness.
- `leak_status`: the guessed byte matched the expected secret byte. This is the
  stricter attack-level result. Set `ATTACK_CHECK=1` to make leak failures return
  a non-zero runner exit code.

Current BOOM smoke status:

| Config | v1 exec | v1 leak | v2 exec | v2 leak | v4 exec | v4 leak | v5 exec | v5 leak |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `MediumBoomV4Config` | PASS | FAIL | PASS | FAIL | PASS | FAIL | PASS | FAIL |
| `SmallBoomV4Config` | PASS | FAIL | PASS | FAIL | PASS | FAIL | PASS | FAIL |

These smoke binaries are intentionally small (`SPECTRE_MAX_BYTES=1`,
`PROBE_ENTRIES=96`) but keep a stronger eviction pass (`EVICTION_MULTIPLIER=4`)
because cache calibration showed that weaker eviction produces unstable
hot/cold timing. They validate the BOOM execution path and produce
cache-timing guesses, but they are not yet calibrated to prove stable secret
recovery for every variant.

The latest direct Verilator run used:

```bash
CONFIGS='MediumBoomV4Config SmallBoomV4Config' \
PROGRAMS='spectre-v1 spectre-v2 spectre-v4 spectre-v5' \
WALL_TIMEOUT=240s TIMEOUT_CYCLES=80000000 \
scripts/run_boom_spectre_smoke.sh
```

Result: all eight BOOM smoke executions pass, but all eight attack-level leak
checks currently fail. This means the compile/load/execute path is working; the
Spectre gadgets and cache thresholds still need calibration before claiming
successful secret recovery. Current v1/v2/v5 smoke output is dominated by
low-score cache noise. Current v4 often recovers the overwritten value or noise,
so it likely needs a stronger store-bypass gadget rather than only a threshold
change.

The v5 smoke profile uses a minimal RAS sequence
(`V5_RAS_DEPTH=1`, `V5_IN_PLACE_DELAY=0`). A deeper smoke sequence previously
triggered a `MediumBoomV4Config` LSU assertion at `lsu.scala:1255`; the reduced
profile keeps the execution-level regression stable. Attack-oriented v5 runs
should use a separate profile and expect additional BOOM LSU investigation if
they reintroduce deep RAS pressure.

BOOM-specific reference artifact:

- `riscv-boom/boom-attacks` was checked as the closest BOOM baseline.
- It implements Spectre-v1 and Spectre-v2 with upstream source names
  `condBranchMispred.c` and `indirBranchMispred.c`; the normalized BOOM
  workload sources are `spectre-v1.c` and `spectre-v2.c`.
- Its RSB file is marked incomplete by the upstream README, and it does not
  provide a Spectre-v4 demo.

Next BOOM work:

1. Keep `scripts/run_boom_spectre_smoke.sh` as the execution regression.
2. Add or tune an attack profile that runs more training rounds and compares
   every byte with `ATTACK_CHECK=1`.
3. Align v1/v2 gadgets with the BOOM `boom-attacks` artifact before treating
   them as BOOM-specific vulnerability tests.
4. Rework v4 and v5 as BOOM-specific experiments; the public BOOM artifact does
   not provide complete v4/v5 baselines.

OpenC910 should be handled as a separate stage after BOOM attack calibration.
The BOOM binaries are RV64 bare-metal ELFs built for a BOOM/Chipyard HTIF
environment; they should not be assumed to run unchanged on OpenC910 Verilator.
