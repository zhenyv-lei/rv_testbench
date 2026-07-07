#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TARGETS="${TARGETS:-boom xiangshan}"
VARIANTS="${VARIANTS:-v1 v2}"

selector="all"
for variant in $VARIANTS; do
  case "$variant" in
    v1|v2|v4|v5|meltdown) ;;
    *) echo "error: unsupported VARIANTS: $VARIANTS" >&2; exit 2 ;;
  esac
done
if [[ " $VARIANTS " == *" meltdown "* && "$VARIANTS" != "meltdown" ]]; then
  echo "error: meltdown must be run as a standalone VARIANTS=meltdown workload" >&2
  exit 2
fi
case "$VARIANTS" in
  "v1"|"v2"|"v4"|"v5"|"meltdown") selector="$VARIANTS" ;;
esac

for target in $TARGETS; do
  case "$target" in
    boom)
      if [[ "$selector" == "meltdown" ]]; then
        "$ROOT/targets/boom/scripts/run-workloads.sh" meltdown
      else
        "$ROOT/targets/boom/scripts/calibrate-and-attack.sh" "$selector"
      fi
      ;;
    xiangshan)
      if [[ "$selector" == "meltdown" ]]; then
        "$ROOT/targets/xiangshan/scripts/run-meltdown.sh"
      else
        for variant in $VARIANTS; do
          case "$variant" in
            v1|v2) ;;
            *) echo "error: XiangShan toolchain supports v1/v2/meltdown only: $VARIANTS" >&2; exit 2 ;;
          esac
        done
        "$ROOT/targets/xiangshan/scripts/calibrate-and-attack.sh" "$selector"
      fi
      ;;
    *)
      echo "error: unsupported target: $target" >&2
      exit 2
      ;;
  esac
done
