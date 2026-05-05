#!/bin/bash
# run-tests.sh — top-level test orchestrator.
#
# Runs all test layers in increasing cost order and prints an aggregate
# summary. Exit non-zero if any layer or any individual test fails.
#
# Layers:
#   1. shellcheck   — static analysis on production + test scripts
#   2. unit/        — pure-function & CLI-parsing tests, no containers (~1s)
#   3. smoke/       — host-side & container-touching tests (~30s, needs podman)
#   4. integration  — full audit-matrix.sh (~60s, needs podman + images built)
#
# Usage:
#   ./tests/run-tests.sh              # all layers
#   ./tests/run-tests.sh --fast       # skip integration (matrix)
#   ./tests/run-tests.sh --unit-only  # shellcheck + unit only

# shellcheck disable=SC2059  # printf format strings include color vars by design
# shellcheck disable=SC2317,SC2329  # layer fns invoked indirectly via "$fn" (SC2329 is shellcheck >=0.10)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# ── Argument parsing ────────────────────────────────────────────────────────
RUN_SHELLCHECK=1
RUN_UNIT=1
RUN_SMOKE=1
RUN_INTEGRATION=1

case "${1:-}" in
    --unit-only)  RUN_SMOKE=0; RUN_INTEGRATION=0 ;;
    --fast)       RUN_INTEGRATION=0 ;;
    --help|-h)
        sed -n '2,/^$/p' "$0" | sed 's/^# *//' | sed 's/^!//'
        exit 0
        ;;
    "") ;;
    *)  echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
esac

# ── Aggregate counters ──────────────────────────────────────────────────────
TOTAL_PASSED=0
TOTAL_FAILED=0
LAYERS_RUN=()
LAYERS_FAILED=()
START_TIME=$(date +%s)

# Run a layer-function and record outcome. Layer functions return non-zero
# on failure, zero on success.
run_layer() {
    local label="$1" fn="$2"
    LAYERS_RUN+=("$label")
    printf "\n${BOLD}── Layer: %s ──${NC}\n" "$label"
    if "$fn"; then
        printf "${GREEN}✓ %s passed${NC}\n" "$label"
    else
        printf "${RED}✗ %s failed${NC}\n" "$label"
        LAYERS_FAILED+=("$label")
    fi
}

# Run one test file, capture its TEST_RESULT line, accumulate counts.
# Returns the file's failed-count (0 = pass).
run_test_file() {
    local f="$1"
    local out
    out=$(bash "$f" 2>&1)
    echo "$out"
    local summary p fail
    summary=$(echo "$out" | grep '^TEST_RESULT' | tail -1)
    if [ -n "$summary" ]; then
        p=$(echo "$summary" | grep -oE 'passed=[0-9]+' | cut -d= -f2)
        fail=$(echo "$summary" | grep -oE 'failed=[0-9]+' | cut -d= -f2)
        TOTAL_PASSED=$((TOTAL_PASSED + p))
        TOTAL_FAILED=$((TOTAL_FAILED + fail))
        return "$fail"
    else
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
        return 1
    fi
}

# ── Layer functions ─────────────────────────────────────────────────────────

layer_shellcheck() {
    set -e
    cd "$REPO_ROOT"
    shellcheck sandbox-lib.sh
    shellcheck -x agent-sandbox
    shellcheck audit.sh
    shellcheck audit-matrix.sh
    ( cd tests/unit && shellcheck -x ./*.sh )
    if compgen -G "tests/smoke/*.sh" >/dev/null; then
        ( cd tests/smoke && shellcheck -x ./*.sh )
    fi
    shellcheck "$SCRIPT_DIR/run-tests.sh"
}

layer_unit() {
    local local_failed=0
    local f
    for f in "$SCRIPT_DIR"/unit/*.sh; do
        # Skip helpers.sh — it's sourced, not run standalone.
        [ "$(basename "$f")" = "helpers.sh" ] && continue
        run_test_file "$f" || local_failed=$((local_failed + 1))
    done
    [ "$local_failed" -eq 0 ]
}

layer_smoke() {
    local local_failed=0
    local f
    for f in "$SCRIPT_DIR"/smoke/*.sh; do
        run_test_file "$f" || local_failed=$((local_failed + 1))
    done
    [ "$local_failed" -eq 0 ]
}

layer_integration() {
    cd "$REPO_ROOT" && ./audit-matrix.sh
}

# ── Drive layers ────────────────────────────────────────────────────────────

[ "$RUN_SHELLCHECK"  = 1 ] && run_layer "shellcheck"               layer_shellcheck
[ "$RUN_UNIT"        = 1 ] && run_layer "unit"                     layer_unit

if [ "$RUN_SMOKE" = 1 ]; then
    if compgen -G "$SCRIPT_DIR/smoke/*.sh" >/dev/null; then
        run_layer "smoke" layer_smoke
    else
        printf "\n${YELLOW}── Layer: smoke (skipped — no smoke tests yet) ──${NC}\n"
    fi
fi

[ "$RUN_INTEGRATION" = 1 ] && run_layer "integration (audit-matrix)" layer_integration

# ── Summary ─────────────────────────────────────────────────────────────────
ELAPSED=$(($(date +%s) - START_TIME))

printf "\n${BOLD}=========================================================${NC}\n"
printf "${BOLD}  Test summary (%ss)${NC}\n" "$ELAPSED"
printf "${BOLD}=========================================================${NC}\n"
printf "  Layers run:    %s\n" "${LAYERS_RUN[*]}"
printf "  Assertions:    ${GREEN}%d passed${NC} / " "$TOTAL_PASSED"
if [ "$TOTAL_FAILED" -gt 0 ]; then
    printf "${RED}%d failed${NC}\n" "$TOTAL_FAILED"
else
    printf "%d failed\n" "$TOTAL_FAILED"
fi

if [ "${#LAYERS_FAILED[@]}" -gt 0 ]; then
    printf "  ${RED}Failed layers: %s${NC}\n" "${LAYERS_FAILED[*]}"
    printf "\n${RED}${BOLD}OVERALL: FAIL${NC}\n"
    exit 1
fi

printf "\n${GREEN}${BOLD}OVERALL: PASS${NC}\n"
exit 0
