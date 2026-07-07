#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
selector="${1:-all}"

case "$selector" in
  v4) variants="v4" ;;
  v5) variants="v5" ;;
  all) variants="v4 v5" ;;
  *)
    echo "usage: $0 [v4|v5|all]" >&2
    exit 2
    ;;
esac

CONFIG="${CONFIG:-SmallBoomV4Config}"
SECRET_SZ="${SECRET_SZ:-1}"
TIMEOUT="${TIMEOUT:-10m}"
MAX_CYCLES="${MAX_CYCLES:-3000000000}"

for variant in $variants; do
  case "$variant" in
    v4)
      CONFIG="$CONFIG" \
      SECRET_SZ="$SECRET_SZ" \
      V4_GADGET_MODE="${V4_GADGET_MODE:-asm}" \
      V4_ROUNDS="${V4_ROUNDS:-1}" \
      TIMEOUT="$TIMEOUT" \
      MAX_CYCLES="$MAX_CYCLES" \
      RUN_TAG="${RUN_TAG:-asm-v4}" \
      "$ROOT/targets/boom/scripts/run-workloads.sh" v4
      ;;
    v5)
      CONFIG="$CONFIG" \
      SECRET_SZ="$SECRET_SZ" \
      V5_GADGET_MODE="${V5_GADGET_MODE:-loop}" \
      V5_ROUNDS="${V5_ROUNDS:-1}" \
      V5_TRAIN_PASSES="${V5_TRAIN_PASSES:-1}" \
      V5_RAS_DEPTH="${V5_RAS_DEPTH:-16}" \
      V5_IN_PLACE_DELAY="${V5_IN_PLACE_DELAY:-8}" \
      TIMEOUT="$TIMEOUT" \
      MAX_CYCLES="$MAX_CYCLES" \
      RUN_TAG="${RUN_TAG:-asm-v5-loop}" \
      "$ROOT/targets/boom/scripts/run-workloads.sh" v5
      ;;
  esac
done
