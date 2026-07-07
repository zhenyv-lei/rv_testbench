#!/usr/bin/env bash
set -euo pipefail

BOOM_TESTBENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$BOOM_TESTBENCH_ROOT/env.sh"

selector="${1:-all}"
case "$selector" in
  v1) variants="v1" ;;
  v2) variants="v2" ;;
  v4) variants="v4" ;;
  v5) variants="v5" ;;
  all) variants="${VARIANTS:-v1 v2 v4 v5}" ;;
  *)
    echo "usage: $0 [v1|v2|v4|v5|all]" >&2
    exit 2
    ;;
esac

BOOM_CONFIGS="${BOOM_CONFIGS:-MediumBoomV3Config MediumBoomV4Config}"
TIMEOUT="${TIMEOUT:-30m}"
CAL_TIMEOUT="${CAL_TIMEOUT:-180s}"
MAX_CYCLES="${MAX_CYCLES:-3000000000}"
CAL_MAX_CYCLES="${CAL_MAX_CYCLES:-50000000}"
SECRET_SZ="${SECRET_SZ:-1}"
ROUND_CANDIDATES="${ROUND_CANDIDATES:-1 2 3 5 8 10}"
V4_ROUND_CANDIDATES="${V4_ROUND_CANDIDATES:-1 2 4 8 16 32 64 128}"
V5_PROFILE_CANDIDATES="${V5_PROFILE_CANDIDATES:-1,1,1,0 4,1,1,0 8,2,2,16 16,4,4,32}"
ATTACK_REPEATS="${ATTACK_REPEATS:-3}"
MIN_SUCCESS_PCT="${MIN_SUCCESS_PCT:-100}"
STOP_ON_ACCEPT="${STOP_ON_ACCEPT:-1}"
TOOLCHAIN_TAG="${TOOLCHAIN_TAG:-toolchain-$(date +%Y%m%d-%H%M%S)}"
SUMMARY_TSV="${SUMMARY_TSV:-$BOOM_LOG_DIR/${TOOLCHAIN_TAG}-summary.tsv}"

now_s() {
  date +%s
}

elapsed_s() {
  local start="$1"
  echo "$(( $(now_s) - start ))"
}

variant_name() {
  case "$1" in
    v1) echo "spectre-v1" ;;
    v2) echo "spectre-v2" ;;
    v4) echo "spectre-v4" ;;
    v5) echo "spectre-v5" ;;
    *) return 2 ;;
  esac
}

attack_passed() {
  local variant="$1"
  local log="$2"
  local pattern
  case "$variant" in
    spectre-v1|spectre-v2) pattern='want\(S\).*1\.\([1-9][0-9]*, 83, S\)' ;;
    spectre-v4) pattern='^\[v4\] check 0 0x53 0x53' ;;
    spectre-v5) pattern='^\[v5\] check 0 0x53 0x53' ;;
    *) return 2 ;;
  esac
  [[ -f "$log" ]] && strings -a "$log" | grep -Eq "$pattern"
}

mkdir -p "$BOOM_LOG_DIR"
printf 'target\tconfig\tvariant\tthreshold\thot_avg\tcold_avg\tparam_name\tparam_value\trepeats\tpasses\tsuccess_rate_pct\taccepted\telapsed_s\tlog_glob\n' > "$SUMMARY_TSV"

make -C "$BOOM_CALIBRATION_ROOT" smoke PROGRAMS="spectre-v1 spectre-v2" >/dev/null
cal_elf="$BOOM_EXEC_DIR/cache-calibration-smoke.riscv"

overall=0
for config in $BOOM_CONFIGS; do
  sim="$BOOM_SIM_DIR/simulator-chipyard.harness-$config"
  if [[ ! -x "$sim" ]]; then
    echo "error: simulator not executable for $config: $sim" >&2
    overall=1
    continue
  fi

  cal_log="$BOOM_LOG_DIR/${config}-${TOOLCHAIN_TAG}-cache-calibration.log"
  echo "[calibrate:$config] elf=$cal_elf"
  echo "[calibrate:$config] log=$cal_log"
  cal_start="$(now_s)"
  timeout "$CAL_TIMEOUT" "$sim" \
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
    overall=1
    continue
  fi
  echo "[calibrate:$config] hot_avg=$hot_avg cold_avg=$cold_avg CACHE_HIT_THRESHOLD=$threshold elapsed=${cal_elapsed}s"

  for variant in $variants; do
    name="$(variant_name "$variant")"
    accepted_variant=0
    case "$variant" in
      v1|v2)
        param_name="ATTACK_SAME_ROUNDS"
        candidates="$ROUND_CANDIDATES"
        ;;
      v4)
        param_name="V4_ROUNDS"
        candidates="$V4_ROUND_CANDIDATES"
        ;;
      v5)
        param_name="V5_PROFILE"
        candidates="$V5_PROFILE_CANDIDATES"
        ;;
    esac

    for candidate in $candidates; do
      echo "[attack:$config:$name] $param_name=$candidate repeats=$ATTACK_REPEATS SECRET_SZ=$SECRET_SZ"
      attack_start="$(now_s)"
      passes=0
      for rep in $(seq 1 "$ATTACK_REPEATS"); do
        tag_value="${candidate//,/-}"
        run_tag="${TOOLCHAIN_TAG}-${name}-${param_name}${tag_value}-rep${rep}"
        v4_rounds=""
        v5_rounds=""
        v5_train_passes=""
        v5_ras_depth=""
        v5_in_place_delay=""
        case "$variant" in
          v1|v2)
            attack_same_rounds="$candidate"
            ;;
          v4)
            attack_same_rounds="${ATTACK_SAME_ROUNDS:-2}"
            v4_rounds="$candidate"
            ;;
          v5)
            attack_same_rounds="${ATTACK_SAME_ROUNDS:-2}"
            IFS=, read -r v5_rounds v5_train_passes v5_ras_depth v5_in_place_delay <<< "$candidate"
            ;;
        esac
        set +e
        (
          cd "$BOOM_TESTBENCH_ROOT"
          CONFIG="$config" \
          SIM="$sim" \
          RISCV="$BOOM_RISCV" \
          SECRET_SZ="$SECRET_SZ" \
          ATTACK_SAME_ROUNDS="$attack_same_rounds" \
          CACHE_HIT_THRESHOLD="$threshold" \
          V4_ROUNDS="$v4_rounds" \
          V5_ROUNDS="$v5_rounds" \
          V5_TRAIN_PASSES="$v5_train_passes" \
          V5_RAS_DEPTH="$v5_ras_depth" \
          V5_IN_PLACE_DELAY="$v5_in_place_delay" \
          TIMEOUT="$TIMEOUT" \
          MAX_CYCLES="$MAX_CYCLES" \
          LOG_DIR="$BOOM_LOG_DIR" \
          RUN_TAG="$run_tag" \
          scripts/run-workloads.sh "$variant"
        )
        rc=$?
        set -e
        log="$BOOM_LOG_DIR/${config}-${name}-secret${SECRET_SZ}-rounds${attack_same_rounds}-${run_tag}.log"
        if [[ "$rc" -eq 0 ]] && attack_passed "$name" "$log"; then
          passes=$((passes + 1))
          echo "[attack:$config:$name] rep=$rep PASS log=$log"
        else
          echo "[attack:$config:$name] rep=$rep FAIL log=$log"
        fi
      done

      elapsed="$(elapsed_s "$attack_start")"
      success_pct=$((passes * 100 / ATTACK_REPEATS))
      accepted=0
      if (( passes * 100 >= ATTACK_REPEATS * MIN_SUCCESS_PCT )); then
        accepted=1
        accepted_variant=1
      fi
      log_glob="$BOOM_LOG_DIR/${config}-${name}-secret${SECRET_SZ}-rounds*-${TOOLCHAIN_TAG}-${name}-${param_name}${tag_value}-rep*.log"
      printf 'boom\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$config" "$name" "$threshold" "$hot_avg" "$cold_avg" "$param_name" "$candidate" \
        "$ATTACK_REPEATS" "$passes" "$success_pct" "$accepted" "$elapsed" "$log_glob" >> "$SUMMARY_TSV"
      echo "[attack:$config:$name] success=${passes}/${ATTACK_REPEATS} (${success_pct}%) accepted=$accepted elapsed=${elapsed}s"

      if [[ "$accepted" -eq 1 && "$STOP_ON_ACCEPT" == "1" ]]; then
        break
      fi
    done
    if [[ "$accepted_variant" -eq 0 ]]; then
      overall=1
    fi
  done
done

echo "[summary] $SUMMARY_TSV"
cat "$SUMMARY_TSV"
exit "$overall"
