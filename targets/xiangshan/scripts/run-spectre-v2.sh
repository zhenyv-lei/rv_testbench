#!/usr/bin/env bash
set -euo pipefail

TESTBENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTBENCH_ROOT/env.sh"

POC_DIR="$XIANGSHAN_WORKLOAD_ROOT/spectre-v2"
LOG_DIR="$XIANGSHAN_LOG_DIR"
mkdir -p "$LOG_DIR"

threshold="${CACHE_HIT_THRESHOLD:-70}"
secret_sz="${SECRET_SZ:-6}"
attack_tries="${V2_ATTACK_TRIES:-2}"
training_loops="${V2_TRAINING_LOOPS:-16}"
timeout_value="${TIMEOUT:-8h}"
use_fixed_threshold="${USE_FIXED_CACHE_HIT_THRESHOLD:-0}"
mode="${MODE:-cmo}"
tag="${TAG:-${mode}-th${threshold}-fixed${use_fixed_threshold}-sz${secret_sz}-tries${attack_tries}-train${training_loops}}"

cppflags=(
  "-DCACHE_HIT_THRESHOLD=$threshold"
  "-DUSE_FIXED_CACHE_HIT_THRESHOLD=$use_fixed_threshold"
  "-DSECRET_SZ=$secret_sz"
  "-DV2_ATTACK_TRIES=$attack_tries"
  "-DV2_TRAINING_LOOPS=$training_loops"
)

if [[ "$mode" == "evict" ]]; then
  cppflags+=("-DUSE_EVICTION_FLUSH=1")
fi

build_log="$LOG_DIR/spectre-v2-build-${tag}.log"
run_log="$LOG_DIR/spectre-v2-run-${tag}.log"

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
  -i "$POC_DIR/build/spectre-v2-riscv64-xs.elf" \
  > "$run_log" 2>&1

printf 'build_log=%s\n' "$build_log"
printf 'run_log=%s\n' "$run_log"

if strings -a "$run_log" | grep -Eq '^\[v2\] check 0 0x53 0x53'; then
  printf 'check=PASS\n'
else
  printf 'check=FAIL\n'
  exit 1
fi
