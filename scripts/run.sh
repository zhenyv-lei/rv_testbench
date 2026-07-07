#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TARGETS="${TARGETS:-boom xiangshan}"
VARIANTS="${VARIANTS:-v1 v2}"

has_v45=0
for variant in $VARIANTS; do
  case "$variant" in
    v1|v2) ;;
    v4|v5) has_v45=1 ;;
    *) echo "error: unsupported VARIANTS: $VARIANTS" >&2; exit 2 ;;
  esac
done

if [[ "$has_v45" == "0" ]]; then
  exec "$ROOT/scripts/run-spectre-v1-v2-calibrated.sh" "$@"
fi

select_variants() {
  local allowed="$1"
  local selected=""
  local variant

  for variant in $VARIANTS; do
    case " $allowed " in
      *" $variant "*) selected="${selected:+$selected }$variant" ;;
    esac
  done

  printf '%s\n' "$selected"
}

single_selector() {
  case "$1" in
    v1|v2|v4|v5) printf '%s\n' "$1" ;;
    *) printf 'all\n' ;;
  esac
}

for target in $TARGETS; do
  case "$target" in
    boom)
      boom_v12="$(select_variants "v1 v2")"
      boom_v45="$(select_variants "v4 v5")"
      if [[ -n "$boom_v12" ]]; then
        TARGETS=boom VARIANTS="$boom_v12" "$ROOT/scripts/run-spectre-v1-v2-calibrated.sh" "$@"
      fi
      if [[ -n "$boom_v45" ]]; then
        "$ROOT/scripts/run-boom-v4-v5-asm.sh" "$(single_selector "$boom_v45")"
      fi
      ;;
    xiangshan)
      xiangshan_v12="$(select_variants "v1 v2")"
      xiangshan_v45="$(select_variants "v4 v5")"
      if [[ -n "$xiangshan_v45" ]]; then
        echo "error: XiangShan run supports v1/v2 only: $VARIANTS" >&2
        exit 2
      fi
      if [[ -n "$xiangshan_v12" ]]; then
        TARGETS=xiangshan VARIANTS="$xiangshan_v12" "$ROOT/scripts/run-spectre-v1-v2-calibrated.sh" "$@"
      fi
      ;;
    *)
      echo "error: unsupported TARGETS: $TARGETS" >&2
      exit 2
      ;;
  esac
done
