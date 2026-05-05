#!/bin/bash
# squid-warning.sh — smoke test for v1.1 item 2.5.
# Verifies that the entrypoint's squid readiness loop emits the warning
# message when squid cannot become reachable.
#
# Strategy:
#   1. Override --entrypoint to /bin/bash so we can run a setup wrapper.
#   2. Wrapper corrupts /etc/squid-locked.conf in-place (file is root-owned
#      but we're running as root inside the container at this stage).
#   3. Wrapper exec's the real entrypoint with /bin/true as the agent CMD.
#   4. Squid fails to start; the readiness loop exhausts in 6s; warning fires.
#
# Capture design: the wrapper redirects the entrypoint's stderr to stdout
# IN-CONTAINER so the warning survives whatever fd routing podman+macOS
# imposes on the host side. The host-side `2>&1` is belt-and-braces.
#
# Why not bind-mount a poisoned config from the host? Because Podman on
# macOS only shares $HOME and a few defaults with its VM (see HANDOFF item
# 4); a config file in /var/folders/... cannot be reached by the container.
#
# Requires: podman, agent-sandbox-claude:latest image built.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_FILE_NAME="smoke/squid-warning"

# shellcheck source=../unit/helpers.sh
source "$SCRIPT_DIR/../unit/helpers.sh"
trap _emit_summary EXIT

echo "Smoke test: squid health-check warning (2.5)"

# ── Pre-flight ──────────────────────────────────────────────────────────────
if ! command -v podman >/dev/null 2>&1; then
    _pass "skipped (no podman)"; exit 0
fi
if ! podman image exists agent-sandbox-claude:latest 2>/dev/null; then
    _pass "skipped (no image)"; exit 0
fi

# ── Setup ───────────────────────────────────────────────────────────────────
CTR_NAME="sandbox-claude-squid-warn-$$"
podman rm -f "$CTR_NAME" >/dev/null 2>&1 || true

cleanup() { podman rm -f "$CTR_NAME" >/dev/null 2>&1 || true; }
trap 'cleanup; _emit_summary' EXIT

# Strict timeout: 25s. with_timeout (in helpers.sh) detects timeout, gtimeout,
# or perl in that order — fails loudly if none are available rather than
# running without a timeout. Perl is the universal floor and ships with macOS.
#
# Wrapper script:
#   - Overwrite /etc/squid-locked.conf with junk (file is root-owned; we're root pre-sudo)
#   - exec the entrypoint with stderr merged into stdout in-container
#   - /bin/true is the CMD passed to the entrypoint's final exec
COMBINED=$(with_timeout 25 podman run --rm \
    --name "$CTR_NAME" \
    --cap-add=NET_ADMIN \
    -e SANDBOX_NETWORK=locked \
    --entrypoint /bin/bash \
    agent-sandbox-claude:latest \
    -c 'echo "intentionally-broken" > /etc/squid-locked.conf; exec /usr/local/bin/entrypoint.sh /bin/true 2>&1' \
    2>&1) || true

# ── Assertions ──────────────────────────────────────────────────────────────
section "v1.1 2.5 — warning fires on squid failure"
INITIAL_FAILED=$TESTS_FAILED

assert_stdout_contains "warning text appears (combined output)" \
    "did not become reachable" echo "$COMBINED"
assert_stdout_contains "warning includes [entrypoint] tag" \
    "[entrypoint]" echo "$COMBINED"

# ── Diagnostic on failure ──────────────────────────────────────────────────
# If either assertion failed, dump the combined output so the next debugger
# doesn't have to re-run the test by hand. Cheap and only fires on failure.
if [ "$TESTS_FAILED" -gt "$INITIAL_FAILED" ]; then
    echo ""
    echo "    ── diagnostic: container combined output (head -40) ──"
    if [ -z "$COMBINED" ]; then
        echo "      (empty — container produced no output at all)"
    else
        echo "$COMBINED" | head -40 | sed 's/^/      /'
    fi
    echo "    ── end diagnostic ──"
fi
