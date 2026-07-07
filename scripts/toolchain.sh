#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TARGETS="${TARGETS:-boom xiangshan}"
VARIANTS="${VARIANTS:-v1 v2}"

selector="all"
case "$VARIANTS" in
  "v1") selector="v1" ;;
  "v2") selector="v2" ;;
  "v1 v2"|"v2 v1") selector="all" ;;
  *) echo "error: unsupported VARIANTS: $VARIANTS" >&2; exit 2 ;;
esac

for target in $TARGETS; do
  case "$target" in
    boom)
      "$ROOT/targets/boom/scripts/calibrate-and-attack.sh" "$selector"
      ;;
    xiangshan)
      "$ROOT/targets/xiangshan/scripts/calibrate-and-attack.sh" "$selector"
      ;;
    *)
      echo "error: unsupported target: $target" >&2
      exit 2
      ;;
  esac
done
