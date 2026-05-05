#!/bin/bash
# status-display.sh — smoke test for v1.1 item 2.3.
# Verifies that ./agent-sandbox status renders the network mode of running
# containers in its listing.
#
# Requires: podman, agent-sandbox-claude:latest image built.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_FILE_NAME="smoke/status-display"

# shellcheck source=../unit/helpers.sh
source "$SCRIPT_DIR/../unit/helpers.sh"
trap _emit_summary EXIT

echo "Smoke test: cmd_status mode rendering (2.3)"

# ── Pre-flight ──────────────────────────────────────────────────────────────
if ! command -v podman >/dev/null 2>&1; then
    _pass "skipped (no podman)"; exit 0
fi
if ! podman image exists agent-sandbox-claude:latest 2>/dev/null; then
    _pass "skipped (no image)"; exit 0
fi

CTR_NAME="sandbox-claude-status-smoke-$$"

cleanup() { podman rm -f "$CTR_NAME" 2>/dev/null || true; }
trap 'cleanup; _emit_summary' EXIT

# ── Setup: long-lived container with a known mode ───────────────────────────
podman run -d --rm \
    --name "$CTR_NAME" \
    -e SANDBOX_NETWORK=open \
    --entrypoint /bin/sleep \
    agent-sandbox-claude:latest 60 >/dev/null

# Give podman a moment to register the container as 'running'
sleep 1

# ── Run status command ──────────────────────────────────────────────────────
STATUS_OUT=$("$REPO_ROOT/agent-sandbox" status 2>&1)

# ── Assertions ──────────────────────────────────────────────────────────────
section "status output renders mode field"
assert_stdout_contains "container appears in status output" \
    "$CTR_NAME" echo "$STATUS_OUT"
assert_stdout_contains "mode: open is rendered" \
    "mode: open" echo "$STATUS_OUT"
assert_stdout_contains "running state is shown alongside mode" \
    "running" echo "$STATUS_OUT"
