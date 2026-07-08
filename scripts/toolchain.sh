#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TARGETS="${TARGETS:-boom xiangshan}"
VARIANTS="${VARIANTS:-v1 v2}"

selector="all"
for variant in $VARIANTS; do
  case "$variant" in
    v1|v2|v4|v5|meltdown|meltdown-us) ;;
    *) echo "error: unsupported VARIANTS: $VARIANTS" >&2; exit 2 ;;
  esac
done
if [[ " $VARIANTS " == *" meltdown "* && "$VARIANTS" != "meltdown" ]] ||
   [[ " $VARIANTS " == *" meltdown-us "* && "$VARIANTS" != "meltdown-us" ]]; then
  echo "error: meltdown workloads must be run standalone with VARIANTS=meltdown or VARIANTS=meltdown-us" >&2
  exit 2
fi
case "$VARIANTS" in
  "v1"|"v2"|"v4"|"v5"|"meltdown"|"meltdown-us") selector="$VARIANTS" ;;
esac

for target in $TARGETS; do
  case "$target" in
    boom)
      if [[ "$selector" == "meltdown" || "$selector" == "meltdown-us" ]]; then
        "$ROOT/targets/boom/scripts/run-workloads.sh" "$selector"
      else
        "$ROOT/targets/boom/scripts/calibrate-and-attack.sh" "$selector"
      fi
      ;;
    xiangshan)
      if [[ "$selector" == "meltdown" ]]; then
        "$ROOT/targets/xiangshan/scripts/run-meltdown.sh"
      elif [[ "$selector" == "meltdown-us" ]]; then
        echo "error: XiangShan toolchain does not yet support VARIANTS=meltdown-us" >&2
        exit 2
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
