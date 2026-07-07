#!/usr/bin/env bash

XIANGSHAN_TESTBENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTBENCH_ROOT="$(cd "$XIANGSHAN_TESTBENCH_ROOT/../.." && pwd)"

export XS_ROOT="${XS_ROOT:-/nfs/home/leizhenyu/opt/DUTs/XiangShan}"
source "$XS_ROOT/scripts/local-env.sh"

export XIANGSHAN_WORKLOAD_ROOT="${XIANGSHAN_WORKLOAD_ROOT:-$XIANGSHAN_TESTBENCH_ROOT/workloads}"
export XIANGSHAN_LOG_DIR="${XIANGSHAN_LOG_DIR:-$XIANGSHAN_TESTBENCH_ROOT/logs}"
export XIANGSHAN_AM_HOME="${XIANGSHAN_AM_HOME:-$XS_ROOT/third_party/nexus-am}"
export XIANGSHAN_EMU="${XIANGSHAN_EMU:-$XS_ROOT/build/emu}"
export XIANGSHAN_MARCH="${XIANGSHAN_MARCH:-rv64gc_zba_zbb_zbc_zbs_zbkb_zbkc_zbkx_zknd_zkne_zknh_zkr_zksed_zksh_zkt_zicbom_zicboz}"
