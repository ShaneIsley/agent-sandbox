#!/bin/bash
# helpers-self.sh — unit tests for helpers.sh's own primitives.
#
# Currently focused on with_timeout, which has enough strategy-selection
# logic and signal handling to deserve direct coverage rather than only
# being exercised indirectly via smoke tests.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_FILE_NAME="unit/helpers-self"

# shellcheck source=helpers.sh
source "$SCRIPT_DIR/helpers.sh"
trap _emit_summary EXIT

echo "Unit tests: helpers.sh (self-tests)"

# ── with_timeout: detection ─────────────────────────────────────────────────
section "with_timeout strategy detection"

# At least one of the three should be available wherever this test runs;
# detection should not hard-fail.
_WITH_TIMEOUT_IMPL=""
_detect_timeout_impl
case "$_WITH_TIMEOUT_IMPL" in
    timeout|gtimeout|perl)
        _pass "detected a valid strategy: $_WITH_TIMEOUT_IMPL"
        ;;
    *)
        _fail "detection picked an unexpected value" \
              "got: $_WITH_TIMEOUT_IMPL"
        ;;
esac

# Force-fail detection by clearing PATH. Should exit 2 with a diagnostic.
DETECT_RC=0
( _WITH_TIMEOUT_IMPL=""
  PATH="/dev/null" _detect_timeout_impl 2>/dev/null ) || DETECT_RC=$?
assert_eq "detection exits 2 when no strategy available" 2 "$DETECT_RC"

# ── with_timeout: each strategy that's actually available ───────────────────
# We test each strategy that's installed on this machine. perl is the
# universal floor and should work everywhere; timeout/gtimeout depend on
# the OS. We always test perl explicitly because it's the trickiest impl.

run_strategy_tests() {
    local impl="$1"
    section "with_timeout strategy: $impl"

    # Skip if this strategy isn't available — but record it as a non-pass-non-fail
    # diagnostic. Only perl should ever skip in practice (always present).
    if [ "$impl" != "perl" ] && ! command -v "$impl" >/dev/null 2>&1; then
        printf "  ${T_DIM}(skipped: %s not on this system)${T_NC}\n" "$impl"
        return 0
    fi

    _WITH_TIMEOUT_IMPL="$impl"

    # Success path
    assert_rc "$impl: command succeeds within budget → rc 0" \
        0 with_timeout 5 true

    # Failure path (non-timeout)
    assert_rc "$impl: command fails within budget → rc forwarded" \
        7 with_timeout 5 sh -c "exit 7"

    # Timeout path
    local timeout_rc=0
    with_timeout 1 sleep 5 >/dev/null 2>&1 || timeout_rc=$?
    assert_eq "$impl: command exceeds budget → rc 124" 124 "$timeout_rc"
}

run_strategy_tests timeout
run_strategy_tests gtimeout
run_strategy_tests perl

# ── with_timeout: stderr cleanliness on timeout ─────────────────────────────
# Regression test: an earlier implementation printed "Alarm clock" to stderr
# when the perl alarm fired (because exec replaced perl, leaving the alarm
# to be handled by the child's default SIGALRM behavior). The fork-based
# implementation must not produce that noise.
section "with_timeout: no stderr noise on timeout"

_WITH_TIMEOUT_IMPL=perl
STDERR_CAPTURE=$(with_timeout 1 sleep 5 2>&1 >/dev/null) || true
if echo "$STDERR_CAPTURE" | grep -qiF "alarm clock"; then
    _fail "perl strategy: no 'Alarm clock' message on timeout" \
          "stderr was: $STDERR_CAPTURE"
else
    _pass "perl strategy: no 'Alarm clock' message on timeout"
fi
