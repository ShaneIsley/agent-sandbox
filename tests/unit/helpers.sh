#!/bin/bash
# helpers.sh — minimal assertion primitives for the test suite.
#
# Sourced, not executed. Tests track their own pass/fail counts in
# $TESTS_PASSED / $TESTS_FAILED and print one line per assertion via the
# helpers below. The orchestrator (run-tests.sh) aggregates totals.

# ── Colors ──────────────────────────────────────────────────────────────────
T_RED='\033[0;31m'
T_GREEN='\033[0;32m'
T_DIM='\033[2m'
T_NC='\033[0m'

# ── Counters (per-file; orchestrator reads via grep) ────────────────────────
TESTS_PASSED=0
TESTS_FAILED=0

_pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "  ${T_GREEN}✓${T_NC} %s\n" "$1"
}

_fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "  ${T_RED}✗${T_NC} %s\n" "$1"
    [ -n "${2:-}" ] && printf "${T_DIM}    %s${T_NC}\n" "$2"
}

# assert_eq <description> <expected> <actual>
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        _pass "$desc"
    else
        _fail "$desc" "expected: $(printf '%q' "$expected")  got: $(printf '%q' "$actual")"
    fi
}

# assert_rc <description> <expected_rc> <command…>
# Runs the command IN A SUBSHELL, captures rc, compares.
# The subshell isolation matters: functions that use `exit` (like
# validate_network) won't kill the test runner. Side-effects on globals
# also don't propagate — for those, call the function directly outside
# assert_rc and inspect the globals with assert_eq.
assert_rc() {
    local desc="$1" expected_rc="$2"; shift 2
    local actual_rc=0
    ( "$@" ) >/dev/null 2>&1 || actual_rc=$?
    if [ "$actual_rc" -eq "$expected_rc" ]; then
        _pass "$desc"
    else
        _fail "$desc" "expected rc=$expected_rc, got rc=$actual_rc"
    fi
}

# assert_stderr_contains <description> <substring> <command…>
# Runs the command, captures stderr, checks substring.
assert_stderr_contains() {
    local desc="$1" needle="$2"; shift 2
    local stderr_capture
    stderr_capture=$("$@" 2>&1 >/dev/null) || true
    if echo "$stderr_capture" | grep -qF -- "$needle"; then
        _pass "$desc"
    else
        _fail "$desc" "stderr did not contain: $needle"
    fi
}

# assert_stdout_contains <description> <substring> <command…>
assert_stdout_contains() {
    local desc="$1" needle="$2"; shift 2
    local stdout_capture
    stdout_capture=$("$@" 2>/dev/null) || true
    if echo "$stdout_capture" | grep -qF -- "$needle"; then
        _pass "$desc"
    else
        _fail "$desc" "stdout did not contain: $needle"
    fi
}

# Print a one-line summary for the orchestrator to parse.
# Always called via trap EXIT so the line appears even if a test crashes.
_emit_summary() {
    printf "TEST_RESULT file=%s passed=%d failed=%d\n" \
        "${TEST_FILE_NAME:-unknown}" "$TESTS_PASSED" "$TESTS_FAILED"
}

# Section headers within a test file (purely cosmetic).
section() { printf "\n${T_DIM}── %s ──${T_NC}\n" "$1"; }

# ── with_timeout ────────────────────────────────────────────────────────────
# with_timeout SECONDS COMMAND [ARGS...]
#
# Portable, strict timeout enforcement. Detects the first available strategy
# from: GNU `timeout` (Linux), `gtimeout` (macOS w/ Homebrew coreutils), or
# `perl` (universal floor — macOS, Linux, BSD all ship perl by default).
# Fails loudly if none are available — never silently skips the timeout.
#
# On timeout: returns 124 (matches GNU `timeout` semantics) so callers can
# distinguish "timed out" from "command failed normally".
#
# Detection runs once per shell session and is cached in $_WITH_TIMEOUT_IMPL.
_WITH_TIMEOUT_IMPL=""

_detect_timeout_impl() {
    if command -v timeout >/dev/null 2>&1; then
        _WITH_TIMEOUT_IMPL="timeout"
    elif command -v gtimeout >/dev/null 2>&1; then
        _WITH_TIMEOUT_IMPL="gtimeout"
    elif command -v perl >/dev/null 2>&1; then
        _WITH_TIMEOUT_IMPL="perl"
    else
        echo "[helpers.sh] FATAL: no timeout strategy available." >&2
        echo "             Need one of: timeout (GNU coreutils), gtimeout" >&2
        echo "             (macOS: brew install coreutils), or perl." >&2
        exit 2
    fi
}

with_timeout() {
    local secs="$1"; shift
    [ -z "${_WITH_TIMEOUT_IMPL:-}" ] && _detect_timeout_impl
    case "$_WITH_TIMEOUT_IMPL" in
        timeout|gtimeout)
            "$_WITH_TIMEOUT_IMPL" "$secs" "$@"
            ;;
        perl)
            # perl-based timeout via fork + alarm. We can't use exec here:
            # exec replaces the perl process, so $SIG{ALRM} dies with it and
            # the alarm fires inside the child's default handler (rc 142,
            # noisy "Alarm clock" message). Fork keeps the parent alive to
            # handle the alarm cleanly and translate to rc 124 (matching
            # GNU timeout's semantics).
            perl -e '
                my $secs = shift;
                my $pid = fork // die "fork: $!";
                if ($pid == 0) { exec @ARGV or exit 127 }
                my $timed_out = 0;
                local $SIG{ALRM} = sub {
                    $timed_out = 1;
                    kill "TERM", $pid;
                    sleep 1;
                    kill "KILL", $pid;
                };
                alarm $secs;
                waitpid $pid, 0;
                my $rc = $?;
                alarm 0;
                exit 124 if $timed_out;
                exit $rc >> 8;
            ' "$secs" "$@"
            ;;
    esac
}
