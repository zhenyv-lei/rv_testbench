#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ATTACK="${1:-all}"

CHIPYARD="${CHIPYARD:-/nfs/home/leizhenyu/opt/DUTs/boom/chipyard}"
CONFIG="${CONFIG:-SmallBoomV4Config}"
SIM="${SIM:-$CHIPYARD/sims/verilator/simulator-chipyard.harness-$CONFIG}"
RISCV="${RISCV:-$CHIPYARD/.conda-env/riscv-tools}"

SECRET_SZ="${SECRET_SZ:-1}"
ATTACK_SAME_ROUNDS="${ATTACK_SAME_ROUNDS:-2}"
TRAIN_TIMES="${TRAIN_TIMES:-}"
ROUNDS="${ROUNDS:-}"
CACHE_HIT_THRESHOLD="${CACHE_HIT_THRESHOLD:-}"

MAX_CYCLES="${MAX_CYCLES:-3000000000}"
TIMEOUT="${TIMEOUT:-30m}"
USE_DRAMSIM="${USE_DRAMSIM:-0}"
DRAMSIM_INI_DIR="${DRAMSIM_INI_DIR:-$CHIPYARD/generators/testchipip/src/main/resources/dramsim2_ini}"
LOG_DIR="${LOG_DIR:-$ROOT/logs}"
RUN_TAG="${RUN_TAG:-}"

usage() {
    cat <<USAGE
Usage: $0 [v1|v2|all]

Environment overrides:
  CONFIG=SmallBoomV4Config
  SIM=/path/to/simulator
  RISCV=/path/to/riscv-tools
  SECRET_SZ=1
  ATTACK_SAME_ROUNDS=2
  TRAIN_TIMES=6
  ROUNDS=1
  CACHE_HIT_THRESHOLD=50
  MAX_CYCLES=3000000000
  TIMEOUT=30m
  USE_DRAMSIM=0
  LOG_DIR=$ROOT/logs
USAGE
}

case "$ATTACK" in
    v1|v2|all) ;;
    -h|--help|help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

if [[ ! -x "$SIM" ]]; then
    echo "error: simulator not executable: $SIM" >&2
    exit 1
fi

make_args=(
    "RISCV=$RISCV"
    "SECRET_SZ=$SECRET_SZ"
    "ATTACK_SAME_ROUNDS=$ATTACK_SAME_ROUNDS"
)

if [[ -n "$TRAIN_TIMES" ]]; then
    make_args+=("TRAIN_TIMES=$TRAIN_TIMES")
fi
if [[ -n "$ROUNDS" ]]; then
    make_args+=("ROUNDS=$ROUNDS")
fi
if [[ -n "$CACHE_HIT_THRESHOLD" ]]; then
    make_args+=("CACHE_HIT_THRESHOLD=$CACHE_HIT_THRESHOLD")
fi

targets=()
case "$ATTACK" in
    v1) targets=(v1) ;;
    v2) targets=(v2) ;;
    all) targets=(v1 v2) ;;
esac

echo "[build] ROOT=$ROOT"
echo "[build] SECRET_SZ=$SECRET_SZ ATTACK_SAME_ROUNDS=$ATTACK_SAME_ROUNDS"
(
    cd "$ROOT"
    make clean
    make "${make_args[@]}" "${targets[@]}"
)

mkdir -p "$LOG_DIR"

dramsim_args=()
if [[ "$USE_DRAMSIM" == "1" ]]; then
    dramsim_args=(
        +dramsim
        "+dramsim_ini_dir=$DRAMSIM_INI_DIR"
    )
fi

run_one() {
    local name="$1"
    local elf="$2"
    local tag_suffix=""
    if [[ -n "$RUN_TAG" ]]; then
        tag_suffix="-$RUN_TAG"
    fi
    local log="$LOG_DIR/${CONFIG}-${name}-secret${SECRET_SZ}-rounds${ATTACK_SAME_ROUNDS}${tag_suffix}.log"

    echo "[run] $name"
    echo "[run] elf=$elf"
    echo "[run] log=$log"

    set +e
    timeout "$TIMEOUT" "$SIM" \
        +permissive \
        "${dramsim_args[@]}" \
        "+max-cycles=$MAX_CYCLES" \
        "+loadmem=$elf" \
        +permissive-off \
        "$elf" > "$log" 2>&1
    local rc=$?
    set -e

    echo "[status] $name exit_code=$rc"
    echo "[summary] $name"
    strings -a "$log" | grep -E 'm\[|want|guess|Verilog \$finish|error|assert|FAILED|PASSED' || tail -40 "$log"

    return "$rc"
}

overall=0
for target in "${targets[@]}"; do
    case "$target" in
        v1)
            run_one "spectre-v1" "$ROOT/build/bin/spectre-v1.riscv" || overall=$?
            ;;
        v2)
            run_one "spectre-v2" "$ROOT/build/bin/spectre-v2.riscv" || overall=$?
            ;;
    esac
done

exit "$overall"
