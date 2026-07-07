#!/usr/bin/env bash
set -euo pipefail

TESTBENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTBENCH_ROOT/env.sh"

POC_DIR="$XIANGSHAN_WORKLOAD_ROOT/meltdown"
LOG_DIR="$XIANGSHAN_LOG_DIR"
mkdir -p "$LOG_DIR"

threshold="${CACHE_HIT_THRESHOLD:-82}"
attempts="${MELTDOWN_ATTEMPTS:-64}"
timeout_value="${TIMEOUT:-8h}"
use_fixed_threshold="${USE_FIXED_CACHE_HIT_THRESHOLD:-0}"
tag="${TAG:-th${threshold}-fixed${use_fixed_threshold}-attempts${attempts}}"

cppflags=(
  "-DCACHE_HIT_THRESHOLD=$threshold"
  "-DUSE_FIXED_CACHE_HIT_THRESHOLD=$use_fixed_threshold"
  "-DMELTDOWN_ATTEMPTS=$attempts"
)

build_log="$LOG_DIR/meltdown-build-${tag}.log"
run_log="$LOG_DIR/meltdown-run-${tag}.log"

make -C "$POC_DIR" clean >/dev/null
make -C "$POC_DIR" \
  AM_HOME="$XIANGSHAN_AM_HOME" \
  ARCH=riscv64-xs \
  LINUX_GNU_TOOLCHAIN=1 \
  MARCH="$XIANGSHAN_MARCH" \
  CC_OPT= \
  CPPFLAGS="${cppflags[*]}" \
  -j"$(nproc)" > "$build_log" 2>&1

timeout "$timeout_value" "$XIANGSHAN_EMU" --no-diff \
  -i "$POC_DIR/build/meltdown-riscv64-xs.elf" \
  > "$run_log" 2>&1

printf 'build_log=%s\n' "$build_log"
printf 'run_log=%s\n' "$run_log"

if strings -a "$run_log" | grep -Eq '^\[meltdown\] check 0 0x53 0x53 traps=[1-9][0-9]*'; then
  printf 'check=PASS\n'
else
  printf 'check=FAIL\n'
  exit 1
fi
