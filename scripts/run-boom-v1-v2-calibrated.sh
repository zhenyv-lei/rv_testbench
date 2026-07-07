#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT/targets/boom/scripts/run-spectre-v1-v2-calibrated.sh" "$@"
