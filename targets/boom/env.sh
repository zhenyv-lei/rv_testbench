#!/usr/bin/env bash

BOOM_TESTBENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTBENCH_ROOT="$(cd "$BOOM_TESTBENCH_ROOT/../.." && pwd)"

export BOOM_CHIPYARD="${BOOM_CHIPYARD:-/nfs/home/leizhenyu/opt/DUTs/boom/chipyard}"
export BOOM_CONFIG="${BOOM_CONFIG:-SmallBoomV4Config}"
export BOOM_SIM_DIR="${BOOM_SIM_DIR:-$BOOM_CHIPYARD/sims/verilator}"
export BOOM_SIM="${BOOM_SIM:-$BOOM_SIM_DIR/simulator-chipyard.harness-$BOOM_CONFIG}"
export BOOM_RISCV="${BOOM_RISCV:-$BOOM_CHIPYARD/.conda-env/riscv-tools}"

export PATH="$BOOM_RISCV/bin:$BOOM_CHIPYARD/.conda-env/bin:$PATH"
export LD_LIBRARY_PATH="$BOOM_RISCV/lib:$BOOM_CHIPYARD/.conda-env/lib:${LD_LIBRARY_PATH:-}"

export BOOM_CALIBRATION_ROOT="${BOOM_CALIBRATION_ROOT:-$BOOM_TESTBENCH_ROOT/workloads/cache-calibration}"
export BOOM_EXEC_DIR="${BOOM_EXEC_DIR:-$BOOM_TESTBENCH_ROOT/build/exec/boom/rv64gc}"
export BOOM_LOG_DIR="${BOOM_LOG_DIR:-$BOOM_TESTBENCH_ROOT/logs}"
