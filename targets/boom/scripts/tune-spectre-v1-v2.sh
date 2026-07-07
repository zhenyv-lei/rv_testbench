#!/usr/bin/env bash
set -euo pipefail

BOOM_TESTBENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BOOM_TESTBENCH_ROOT/env.sh"

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

TIMEOUT="${TIMEOUT:-30m}"
CAL_TIMEOUT="${CAL_TIMEOUT:-180s}"
MAX_CYCLES="${MAX_CYCLES:-3000000000}"
CAL_MAX_CYCLES="${CAL_MAX_CYCLES:-50000000}"
SECRET_SZ="${SECRET_SZ:-1}"
ROUND_CANDIDATES="${ROUND_CANDIDATES:-1 2 3 5 8 10}"
TUNE_STOP_ON_PASS="${TUNE_STOP_ON_PASS:-1}"

now_s() {
  date +%s
}

elapsed_s() {
  local start="$1"
  echo "$(( $(now_s) - start ))"
}

total_start="$(now_s)"

mkdir -p "$BOOM_LOG_DIR"

if [[ ! -x "$BOOM_SIM" ]]; then
  echo "error: simulator not executable: $BOOM_SIM" >&2
  exit 1
fi

make -C "$BOOM_CALIBRATION_ROOT" smoke PROGRAMS="spectre-v1 spectre-v2" >/dev/null

cal_elf="$BOOM_EXEC_DIR/cache-calibration-smoke.riscv"
cal_log="$BOOM_LOG_DIR/${BOOM_CONFIG}-cache-calibration-tune.log"

echo "[calibrate] elf=$cal_elf"
echo "[calibrate] log=$cal_log"

cal_start="$(now_s)"
timeout "$CAL_TIMEOUT" "$BOOM_SIM" \
  +permissive \
  "+max-cycles=$CAL_MAX_CYCLES" \
  "+loadmem=$cal_elf" \
  +permissive-off \
  "$cal_elf" > "$cal_log" 2>&1
cal_elapsed="$(elapsed_s "$cal_start")"

calibration="$(
  awk '
    /^\[cal\] round / {
      for (i = 1; i <= NF; ++i) {
        if ($i ~ /^hot=/) {
          split($i, a, "=");
          hot += a[2];
          n_hot++;
        }
        if ($i ~ /^cold=/) {
          split($i, a, "=");
          cold += a[2];
          n_cold++;
        }
      }
    }
    END {
      if (n_hot == 0 || n_cold == 0) {
        exit 1;
      }
      hot_avg = hot / n_hot;
      cold_avg = cold / n_cold;
      threshold = int((hot_avg + cold_avg) / 2) + 1;
      printf "%d %.2f %.2f\n", threshold, hot_avg, cold_avg;
    }
  ' "$cal_log"
)"

read -r threshold hot_avg cold_avg <<< "$calibration"
if [[ -z "$threshold" || "$threshold" -le 0 ]]; then
  echo "error: failed to derive cache threshold from $cal_log" >&2
  exit 1
fi

echo "[calibrate] hot_avg=$hot_avg cold_avg=$cold_avg CACHE_HIT_THRESHOLD=$threshold elapsed=${cal_elapsed}s"

attack_selector="all"
if [[ "$variants" == "v1" ]]; then
  attack_selector="v1"
elif [[ "$variants" == "v2" ]]; then
  attack_selector="v2"
fi

best_rounds=""
for rounds in $ROUND_CANDIDATES; do
  echo "[sweep] ATTACK_SAME_ROUNDS=$rounds SECRET_SZ=$SECRET_SZ"
  sweep_start="$(now_s)"
  set +e
  (
    cd "$BOOM_TESTBENCH_ROOT"
    CONFIG="$BOOM_CONFIG" \
    SIM="$BOOM_SIM" \
    RISCV="$BOOM_RISCV" \
    SECRET_SZ="$SECRET_SZ" \
    ATTACK_SAME_ROUNDS="$rounds" \
    CACHE_HIT_THRESHOLD="$threshold" \
    TIMEOUT="$TIMEOUT" \
    MAX_CYCLES="$MAX_CYCLES" \
    LOG_DIR="$BOOM_LOG_DIR" \
    scripts/run-workloads.sh "$attack_selector"
  )
  rc=$?
  set -e
  sweep_elapsed="$(elapsed_s "$sweep_start")"

  pass=1
  for variant in $variants; do
    case "$variant" in
      v1) name="spectre-v1" ;;
      v2) name="spectre-v2" ;;
    esac

    log="$BOOM_LOG_DIR/${BOOM_CONFIG}-${name}-secret${SECRET_SZ}-rounds${rounds}.log"
    if [[ ! -f "$log" ]] ||
       ! strings -a "$log" | grep -Eq 'want\(S\).*1\.\([1-9][0-9]*, 83, S\)'; then
      pass=0
    fi
  done

  if [[ "$rc" -eq 0 && "$pass" -eq 1 ]]; then
    echo "[sweep] PASS ATTACK_SAME_ROUNDS=$rounds elapsed=${sweep_elapsed}s"
    best_rounds="$rounds"
    if [[ "$TUNE_STOP_ON_PASS" == "1" ]]; then
      break
    fi
  else
    echo "[sweep] FAIL ATTACK_SAME_ROUNDS=$rounds elapsed=${sweep_elapsed}s"
  fi
done

if [[ -z "$best_rounds" ]]; then
  echo "[result] no passing ATTACK_SAME_ROUNDS in: $ROUND_CANDIDATES" >&2
  exit 1
fi

echo "[result] recommended:"
echo "CACHE_HIT_THRESHOLD=$threshold ATTACK_SAME_ROUNDS=$best_rounds SECRET_SZ=6 $BOOM_TESTBENCH_ROOT/scripts/run-spectre-v1-v2-calibrated.sh $selector"
echo "[time] total=$(elapsed_s "$total_start")s calibration=${cal_elapsed}s"
