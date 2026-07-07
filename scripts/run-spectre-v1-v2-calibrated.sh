#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TARGETS="${TARGETS:-boom xiangshan}"
VARIANTS="${VARIANTS:-v1 v2}"
TIMEOUT="${TIMEOUT:-8h}"
SECRET_SZ="${SECRET_SZ:-1}"

run_boom() {
  local attack="all"

  if [[ "$VARIANTS" == "v1" ]]; then
    attack="v1"
  elif [[ "$VARIANTS" == "v2" ]]; then
    attack="v2"
  fi

  for variant in $VARIANTS; do
    case "$variant" in
      v1|v2) ;;
      *) echo "error: unsupported BOOM variant: $variant" >&2; return 2 ;;
    esac
  done

  BOOM_LOG_DIR="${BOOM_LOG_DIR:-$ROOT/targets/boom/logs}" \
  TIMEOUT="${BOOM_WALL_TIMEOUT:-$TIMEOUT}" \
  SECRET_SZ="$SECRET_SZ" \
  "$ROOT/targets/boom/scripts/run-spectre-v1-v2-calibrated.sh" "$attack"
}

run_xiangshan() {
  (
    cd "$ROOT/targets/xiangshan"
    for variant in $VARIANTS; do
      case "$variant" in
        v1)
          SECRET_SZ="$SECRET_SZ" TIMEOUT="$TIMEOUT" scripts/run-spectre-v1.sh
          ;;
        v2)
          SECRET_SZ="$SECRET_SZ" TIMEOUT="$TIMEOUT" scripts/run-spectre-v2.sh
          ;;
        *)
          echo "error: unsupported XiangShan variant: $variant" >&2
          return 2
          ;;
      esac
    done
  )
}

mkdir -p "$ROOT/targets/boom/logs" "$ROOT/targets/xiangshan/logs"

for target in $TARGETS; do
  case "$target" in
    boom) run_boom ;;
    xiangshan) run_xiangshan ;;
    *) echo "error: unsupported target: $target" >&2; exit 2 ;;
  esac
done
