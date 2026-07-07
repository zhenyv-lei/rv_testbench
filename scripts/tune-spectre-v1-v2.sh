#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TARGETS="${TARGETS:-boom xiangshan}"
VARIANTS="${VARIANTS:-v1 v2}"

for target in $TARGETS; do
  case "$target" in
    boom)
      case "$VARIANTS" in
        "v1") "$ROOT/targets/boom/scripts/tune-spectre-v1-v2.sh" v1 ;;
        "v2") "$ROOT/targets/boom/scripts/tune-spectre-v1-v2.sh" v2 ;;
        "v1 v2"|"v2 v1") "$ROOT/targets/boom/scripts/tune-spectre-v1-v2.sh" all ;;
        *) echo "error: unsupported BOOM VARIANTS: $VARIANTS" >&2; exit 2 ;;
      esac
      ;;
    xiangshan)
      case "$VARIANTS" in
        "v1") "$ROOT/targets/xiangshan/scripts/tune-spectre-v1-v2.sh" v1 ;;
        "v2") "$ROOT/targets/xiangshan/scripts/tune-spectre-v1-v2.sh" v2 ;;
        "v1 v2"|"v2 v1") "$ROOT/targets/xiangshan/scripts/tune-spectre-v1-v2.sh" all ;;
        *) echo "error: unsupported XiangShan VARIANTS: $VARIANTS" >&2; exit 2 ;;
      esac
      ;;
    *)
      echo "error: unsupported target: $target" >&2
      exit 2
      ;;
  esac
done
