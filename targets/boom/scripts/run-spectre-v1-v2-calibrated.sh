#!/usr/bin/env bash
set -euo pipefail

BOOM_TESTBENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BOOM_TESTBENCH_ROOT/env.sh"

TIMEOUT="${TIMEOUT:-30m}"
CAL_TIMEOUT="${CAL_TIMEOUT:-180s}"
MAX_CYCLES="${MAX_CYCLES:-3000000000}"
CAL_MAX_CYCLES="${CAL_MAX_CYCLES:-50000000}"
SECRET_SZ="${SECRET_SZ:-1}"
ATTACK_SAME_ROUNDS="${ATTACK_SAME_ROUNDS:-2}"
ATTACK="${1:-all}"

mkdir -p "$BOOM_LOG_DIR"

if [[ ! -x "$BOOM_SIM" ]]; then
  echo "error: simulator not executable: $BOOM_SIM" >&2
  exit 1
fi

make -C "$BOOM_CALIBRATION_ROOT" smoke PROGRAMS="spectre-v1 spectre-v2" >/dev/null

cal_elf="$BOOM_EXEC_DIR/cache-calibration-smoke.riscv"
cal_log="$BOOM_LOG_DIR/${BOOM_CONFIG}-cache-calibration.log"

echo "[calibrate] elf=$cal_elf"
echo "[calibrate] log=$cal_log"

timeout "$CAL_TIMEOUT" "$BOOM_SIM" \
  +permissive \
  "+max-cycles=$CAL_MAX_CYCLES" \
  "+loadmem=$cal_elf" \
  +permissive-off \
  "$cal_elf" > "$cal_log" 2>&1

threshold="$(
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
      printf "%d\n", int(((hot / n_hot) + (cold / n_cold)) / 2) + 1;
    }
  ' "$cal_log"
)"

if [[ -z "$threshold" || "$threshold" -le 0 ]]; then
  echo "error: failed to derive cache threshold from $cal_log" >&2
  exit 1
fi

echo "[calibrate] CACHE_HIT_THRESHOLD=$threshold"

(
  cd "$BOOM_TESTBENCH_ROOT"
  CONFIG="$BOOM_CONFIG" \
  SIM="$BOOM_SIM" \
  RISCV="$BOOM_RISCV" \
  SECRET_SZ="$SECRET_SZ" \
  ATTACK_SAME_ROUNDS="$ATTACK_SAME_ROUNDS" \
  CACHE_HIT_THRESHOLD="$threshold" \
  TIMEOUT="$TIMEOUT" \
  MAX_CYCLES="$MAX_CYCLES" \
  LOG_DIR="$BOOM_LOG_DIR" \
  scripts/run-workloads.sh "$ATTACK"
)

status=0
for log in "$BOOM_LOG_DIR"/"$BOOM_CONFIG"-spectre-v[12]-secret"$SECRET_SZ"-rounds"$ATTACK_SAME_ROUNDS".log; do
  [[ -f "$log" ]] || continue
  if strings -a "$log" | grep -Eq 'want\(S\).*1\.\([1-9][0-9]*, 83, S\)'; then
    echo "[check] PASS $(basename "$log")"
  else
    echo "[check] FAIL $(basename "$log")"
    status=1
  fi
done

exit "$status"
