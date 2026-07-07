#!/usr/bin/env bash
set -euo pipefail

XIANGSHAN_TUNE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$XIANGSHAN_TUNE_ROOT/env.sh"

selector="${1:-all}"
case "$selector" in
  v1) variants="v1" ;;
  v2) variants="v2" ;;
  all) variants="v1 v2" ;;
  *)
    echo "usage: $0 [v1|v2|all]" >&2
    exit 2
    ;;
esac

TIMEOUT="${TIMEOUT:-8h}"
CAL_TIMEOUT="${CAL_TIMEOUT:-10m}"
SECRET_SZ="${SECRET_SZ:-1}"
ROUND_CANDIDATES="${ROUND_CANDIDATES:-1 2 3 5}"
V2_TRY_CANDIDATES="${V2_TRY_CANDIDATES:-1 2 4 8 16}"
TUNE_STOP_ON_PASS="${TUNE_STOP_ON_PASS:-1}"

now_s() {
  date +%s
}

elapsed_s() {
  local start="$1"
  echo "$(( $(now_s) - start ))"
}

total_start="$(now_s)"

LOG_DIR="$XIANGSHAN_LOG_DIR"
CAL_DIR="$XIANGSHAN_WORKLOAD_ROOT/cache-calibration"
mkdir -p "$LOG_DIR"

if [[ ! -x "$XIANGSHAN_EMU" ]]; then
  echo "error: simulator not executable: $XIANGSHAN_EMU" >&2
  exit 1
fi
if [[ ! -d "$CAL_DIR" ]]; then
  echo "error: cache-calibration directory not found: $CAL_DIR" >&2
  exit 1
fi

cal_tag="cache-calibration-tune"
build_log="$LOG_DIR/${cal_tag}-build.log"
cal_log="$LOG_DIR/${cal_tag}-run.log"

echo "[calibrate] build_dir=$CAL_DIR"
echo "[calibrate] build_log=$build_log"
cal_start="$(now_s)"
make -C "$CAL_DIR" clean >/dev/null
make -C "$CAL_DIR" \
  AM_HOME="$XIANGSHAN_AM_HOME" \
  ARCH=riscv64-xs \
  LINUX_GNU_TOOLCHAIN=1 \
  MARCH="$XIANGSHAN_MARCH" \
  CC_OPT= \
  -j"$(nproc)" > "$build_log" 2>&1

echo "[calibrate] run_log=$cal_log"
timeout "$CAL_TIMEOUT" "$XIANGSHAN_EMU" --no-diff \
  -i "$CAL_DIR/build/cache-calibration-riscv64-xs.elf" \
  > "$cal_log" 2>&1
cal_elapsed="$(elapsed_s "$cal_start")"

calibration="$(
  awk '
    /diff read from ram/ {
      miss += $NF;
      n_miss++;
    }
    /diff from data cache/ {
      hit += $NF;
      n_hit++;
    }
    END {
      if (n_hit == 0 || n_miss == 0) {
        exit 1;
      }
      hit_avg = hit / n_hit;
      miss_avg = miss / n_miss;
      threshold = int((hit_avg + miss_avg) / 2) + 1;
      printf "%d %.2f %.2f\n", threshold, hit_avg, miss_avg;
    }
  ' "$cal_log"
)"

read -r threshold hit_avg miss_avg <<< "$calibration"
if [[ -z "$threshold" || "$threshold" -le 0 ]]; then
  echo "error: failed to derive cache threshold from $cal_log" >&2
  exit 1
fi

echo "[calibrate] hit_avg=$hit_avg miss_avg=$miss_avg CACHE_HIT_THRESHOLD=$threshold elapsed=${cal_elapsed}s"

best_v1_rounds=""
best_v2_tries=""

for variant in $variants; do
  case "$variant" in
    v1)
      for rounds in $ROUND_CANDIDATES; do
        echo "[sweep:v1] ATTACK_SAME_ROUNDS=$rounds SECRET_SZ=$SECRET_SZ"
        sweep_start="$(now_s)"
        set +e
        (
          cd "$XIANGSHAN_TUNE_ROOT"
          CACHE_HIT_THRESHOLD="$threshold" \
          USE_FIXED_CACHE_HIT_THRESHOLD=1 \
          SECRET_SZ="$SECRET_SZ" \
          ATTACK_SAME_ROUNDS="$rounds" \
          TIMEOUT="$TIMEOUT" \
          TAG="tune-v1-th${threshold}-r${rounds}" \
          "$XIANGSHAN_TUNE_ROOT/scripts/run-spectre-v1.sh"
        )
        rc=$?
        set -e
        sweep_elapsed="$(elapsed_s "$sweep_start")"
        if [[ "$rc" -eq 0 ]]; then
          echo "[sweep:v1] PASS ATTACK_SAME_ROUNDS=$rounds elapsed=${sweep_elapsed}s"
          best_v1_rounds="$rounds"
          if [[ "$TUNE_STOP_ON_PASS" == "1" ]]; then
            break
          fi
        else
          echo "[sweep:v1] FAIL ATTACK_SAME_ROUNDS=$rounds elapsed=${sweep_elapsed}s"
        fi
      done
      ;;
    v2)
      for tries in $V2_TRY_CANDIDATES; do
        echo "[sweep:v2] V2_ATTACK_TRIES=$tries SECRET_SZ=$SECRET_SZ"
        sweep_start="$(now_s)"
        set +e
        (
          cd "$XIANGSHAN_TUNE_ROOT"
          CACHE_HIT_THRESHOLD="$threshold" \
          USE_FIXED_CACHE_HIT_THRESHOLD=1 \
          SECRET_SZ="$SECRET_SZ" \
          V2_ATTACK_TRIES="$tries" \
          TIMEOUT="$TIMEOUT" \
          TAG="tune-v2-th${threshold}-tries${tries}" \
          "$XIANGSHAN_TUNE_ROOT/scripts/run-spectre-v2.sh"
        )
        rc=$?
        set -e
        sweep_elapsed="$(elapsed_s "$sweep_start")"
        if [[ "$rc" -eq 0 ]]; then
          echo "[sweep:v2] PASS V2_ATTACK_TRIES=$tries elapsed=${sweep_elapsed}s"
          best_v2_tries="$tries"
          if [[ "$TUNE_STOP_ON_PASS" == "1" ]]; then
            break
          fi
        else
          echo "[sweep:v2] FAIL V2_ATTACK_TRIES=$tries elapsed=${sweep_elapsed}s"
        fi
      done
      ;;
  esac
done

status=0
for variant in $variants; do
  if [[ "$variant" == "v1" && -z "$best_v1_rounds" ]]; then
    echo "[result] no passing ATTACK_SAME_ROUNDS in: $ROUND_CANDIDATES" >&2
    status=1
  fi
  if [[ "$variant" == "v2" && -z "$best_v2_tries" ]]; then
    echo "[result] no passing V2_ATTACK_TRIES in: $V2_TRY_CANDIDATES" >&2
    status=1
  fi
done
if [[ "$status" -ne 0 ]]; then
  exit "$status"
fi

echo "[result] recommended:"
if [[ -n "$best_v1_rounds" ]]; then
  echo "CACHE_HIT_THRESHOLD=$threshold USE_FIXED_CACHE_HIT_THRESHOLD=1 ATTACK_SAME_ROUNDS=$best_v1_rounds SECRET_SZ=6 $XIANGSHAN_TUNE_ROOT/scripts/run-spectre-v1.sh"
fi
if [[ -n "$best_v2_tries" ]]; then
  echo "CACHE_HIT_THRESHOLD=$threshold USE_FIXED_CACHE_HIT_THRESHOLD=1 V2_ATTACK_TRIES=$best_v2_tries SECRET_SZ=6 $XIANGSHAN_TUNE_ROOT/scripts/run-spectre-v2.sh"
fi
echo "[time] total=$(elapsed_s "$total_start")s calibration=${cal_elapsed}s"
