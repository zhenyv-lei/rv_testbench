#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TARGETS="${TARGETS:-boom xiangshan}"
VARIANTS="${VARIANTS:-v1 v2}"

selector="all"
for variant in $VARIANTS; do
  case "$variant" in
    v1|v2|v4|v5) ;;
    *) echo "error: unsupported VARIANTS: $VARIANTS" >&2; exit 2 ;;
  esac
done
case "$VARIANTS" in
  "v1"|"v2"|"v4"|"v5") selector="$VARIANTS" ;;
esac

for target in $TARGETS; do
  case "$target" in
    boom)
      "$ROOT/targets/boom/scripts/calibrate-and-attack.sh" "$selector"
      ;;
    xiangshan)
      for variant in $VARIANTS; do
        case "$variant" in
          v1|v2) ;;
          *) echo "error: XiangShan toolchain supports v1/v2 only: $VARIANTS" >&2; exit 2 ;;
        esac
      done
      "$ROOT/targets/xiangshan/scripts/calibrate-and-attack.sh" "$selector"
      ;;
    *)
      echo "error: unsupported target: $target" >&2
      exit 2
      ;;
  esac
done
