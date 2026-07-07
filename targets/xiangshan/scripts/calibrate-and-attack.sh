#!/usr/bin/env bash
set -euo pipefail

XIANGSHAN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$XIANGSHAN_ROOT/env.sh"

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
ATTACK_REPEATS="${ATTACK_REPEATS:-3}"
MIN_SUCCESS_PCT="${MIN_SUCCESS_PCT:-100}"
STOP_ON_ACCEPT="${STOP_ON_ACCEPT:-1}"
TOOLCHAIN_TAG="${TOOLCHAIN_TAG:-toolchain-$(date +%Y%m%d-%H%M%S)}"
SUMMARY_TSV="${SUMMARY_TSV:-$XIANGSHAN_LOG_DIR/${TOOLCHAIN_TAG}-summary.tsv}"

now_s() {
  date +%s
}

elapsed_s() {
  local start="$1"
  echo "$(( $(now_s) - start ))"
}

mkdir -p "$XIANGSHAN_LOG_DIR"
printf 'target\tconfig\tvariant\tthreshold\thit_avg\tmiss_avg\tparam_name\tparam_value\trepeats\tpasses\tsuccess_rate_pct\taccepted\telapsed_s\tlog_glob\n' > "$SUMMARY_TSV"

CAL_DIR="$XIANGSHAN_WORKLOAD_ROOT/cache-calibration"
if [[ ! -x "$XIANGSHAN_EMU" ]]; then
  echo "error: simulator not executable: $XIANGSHAN_EMU" >&2
  exit 1
fi

cal_build_log="$XIANGSHAN_LOG_DIR/${TOOLCHAIN_TAG}-cache-calibration-build.log"
cal_log="$XIANGSHAN_LOG_DIR/${TOOLCHAIN_TAG}-cache-calibration-run.log"
echo "[calibrate:xiangshan] build_dir=$CAL_DIR"
echo "[calibrate:xiangshan] build_log=$cal_build_log"
cal_start="$(now_s)"
make -C "$CAL_DIR" clean >/dev/null
make -C "$CAL_DIR" \
  AM_HOME="$XIANGSHAN_AM_HOME" \
  ARCH=riscv64-xs \
  LINUX_GNU_TOOLCHAIN=1 \
  MARCH="$XIANGSHAN_MARCH" \
  CC_OPT= \
  -j"$(nproc)" > "$cal_build_log" 2>&1

echo "[calibrate:xiangshan] run_log=$cal_log"
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
echo "[calibrate:xiangshan] hit_avg=$hit_avg miss_avg=$miss_avg CACHE_HIT_THRESHOLD=$threshold elapsed=${cal_elapsed}s"

overall=0
for variant in $variants; do
  case "$variant" in
    v1)
      variant_name="spectre-v1"
      param_name="ATTACK_SAME_ROUNDS"
      candidates="$ROUND_CANDIDATES"
      runner="$XIANGSHAN_ROOT/scripts/run-spectre-v1.sh"
      ;;
    v2)
      variant_name="spectre-v2"
      param_name="V2_ATTACK_TRIES"
      candidates="$V2_TRY_CANDIDATES"
      runner="$XIANGSHAN_ROOT/scripts/run-spectre-v2.sh"
      ;;
  esac

  accepted_variant=0
  for candidate in $candidates; do
    echo "[attack:xiangshan:$variant_name] $param_name=$candidate repeats=$ATTACK_REPEATS SECRET_SZ=$SECRET_SZ"
    attack_start="$(now_s)"
    passes=0
    for rep in $(seq 1 "$ATTACK_REPEATS"); do
      tag="${TOOLCHAIN_TAG}-${variant_name}-${param_name}${candidate}-rep${rep}"
      set +e
      if [[ "$variant" == "v1" ]]; then
        CACHE_HIT_THRESHOLD="$threshold" \
        USE_FIXED_CACHE_HIT_THRESHOLD=1 \
        SECRET_SZ="$SECRET_SZ" \
        ATTACK_SAME_ROUNDS="$candidate" \
        TIMEOUT="$TIMEOUT" \
        TAG="$tag" \
        "$runner"
      else
        CACHE_HIT_THRESHOLD="$threshold" \
        USE_FIXED_CACHE_HIT_THRESHOLD=1 \
        SECRET_SZ="$SECRET_SZ" \
        V2_ATTACK_TRIES="$candidate" \
        TIMEOUT="$TIMEOUT" \
        TAG="$tag" \
        "$runner"
      fi
      rc=$?
      set -e
      if [[ "$rc" -eq 0 ]]; then
        passes=$((passes + 1))
        echo "[attack:xiangshan:$variant_name] rep=$rep PASS tag=$tag"
      else
        echo "[attack:xiangshan:$variant_name] rep=$rep FAIL tag=$tag"
      fi
    done

    elapsed="$(elapsed_s "$attack_start")"
    success_pct=$((passes * 100 / ATTACK_REPEATS))
    accepted=0
    if (( passes * 100 >= ATTACK_REPEATS * MIN_SUCCESS_PCT )); then
      accepted=1
      accepted_variant=1
    fi
    log_glob="$XIANGSHAN_LOG_DIR/${variant_name}-run-${TOOLCHAIN_TAG}-${variant_name}-${param_name}${candidate}-rep*.log"
    printf 'xiangshan\tdefault\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$variant_name" "$threshold" "$hit_avg" "$miss_avg" "$param_name" "$candidate" \
      "$ATTACK_REPEATS" "$passes" "$success_pct" "$accepted" "$elapsed" "$log_glob" >> "$SUMMARY_TSV"
    echo "[attack:xiangshan:$variant_name] success=${passes}/${ATTACK_REPEATS} (${success_pct}%) accepted=$accepted elapsed=${elapsed}s"

    if [[ "$accepted" -eq 1 && "$STOP_ON_ACCEPT" == "1" ]]; then
      break
    fi
  done

  if [[ "$accepted_variant" -eq 0 ]]; then
    overall=1
  fi
done

echo "[summary] $SUMMARY_TSV"
cat "$SUMMARY_TSV"
exit "$overall"
