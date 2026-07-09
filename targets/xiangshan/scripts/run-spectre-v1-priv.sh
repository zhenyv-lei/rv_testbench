#!/usr/bin/env bash
set -euo pipefail

TESTBENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$TESTBENCH_ROOT/env.sh"

POC_DIR="$XIANGSHAN_WORKLOAD_ROOT/spectre-v1-priv"
LOG_DIR="$XIANGSHAN_LOG_DIR"
mkdir -p "$LOG_DIR"

threshold="${CACHE_HIT_THRESHOLD:-70}"
secret_sz="${SECRET_SZ:-3}"
full_byte_probe="${FULL_BYTE_PROBE:-0}"
early_stop="${EARLY_STOP:-1}"
early_stop_min_score="${EARLY_STOP_MIN_SCORE:-3}"
early_stop_gap="${EARLY_STOP_GAP:-2}"
if [[ "$full_byte_probe" == "1" ]]; then
  probe_candidates="${PROBE_CANDIDATES:-256}"
else
  probe_candidates="${PROBE_CANDIDATES:-62}"
fi
attack_same_rounds="${ATTACK_SAME_ROUNDS:-5}"
train_times="${TRAIN_TIMES:-10}"
timeout_value="${TIMEOUT:-20m}"
use_fixed_threshold="${USE_FIXED_CACHE_HIT_THRESHOLD:-0}"
direct_service_call="${DIRECT_SERVICE_CALL:-0}"
use_am_cte="${USE_AM_CTE:-0}"
attacker_mpp="${ATTACKER_MPP:-0}"
tag="${TAG:-priv-sz${secret_sz}-r${attack_same_rounds}-t${train_times}-direct${direct_service_call}-mpp${attacker_mpp}-fb${full_byte_probe}-pc${probe_candidates}-es${early_stop}}"

cppflags=(
  "-DCACHE_HIT_THRESHOLD=$threshold"
  "-DUSE_FIXED_CACHE_HIT_THRESHOLD=$use_fixed_threshold"
  "-DSECRET_SZ=$secret_sz"
  "-DPROBE_CANDIDATES=$probe_candidates"
  "-DATTACK_SAME_ROUNDS=$attack_same_rounds"
  "-DTRAIN_TIMES=$train_times"
  "-DDIRECT_SERVICE_CALL=$direct_service_call"
  "-DUSE_AM_CTE=$use_am_cte"
  "-DATTACKER_MPP=$attacker_mpp"
  "-DFULL_BYTE_PROBE=$full_byte_probe"
  "-DEARLY_STOP=$early_stop"
  "-DEARLY_STOP_MIN_SCORE=$early_stop_min_score"
  "-DEARLY_STOP_GAP=$early_stop_gap"
)

build_log="$LOG_DIR/spectre-v1-priv-build-${tag}.log"
run_log="$LOG_DIR/spectre-v1-priv-run-${tag}.log"

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
  -i "$POC_DIR/build/spectre-v1-priv-riscv64-xs.elf" \
  > "$run_log" 2>&1

printf 'build_log=%s\n' "$build_log"
printf 'run_log=%s\n' "$run_log"

if strings -a "$run_log" | grep -q '^\[v1-priv\] check=PASS'; then
  printf 'check=PASS\n'
else
  printf 'check=FAIL\n'
  exit 1
fi
