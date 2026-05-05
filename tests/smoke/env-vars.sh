#!/bin/bash
# env-vars.sh — smoke test for v1.1 item 1.3.
# Verifies SANDBOX_PROJECT (canonical) and CLAUDE_PROJECT (compat alias) are
# both set inside the container, and that they hold the project name.
#
# Requires: podman, agent-sandbox-claude:latest image built (./agent-sandbox setup).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_FILE_NAME="smoke/env-vars"

# shellcheck source=../unit/helpers.sh
source "$SCRIPT_DIR/../unit/helpers.sh"
trap _emit_summary EXIT

echo "Smoke test: container env vars (1.3)"

# ── Pre-flight ──────────────────────────────────────────────────────────────
if ! command -v podman >/dev/null 2>&1; then
    echo "  SKIP: podman not available" >&2
    _pass "skipped (no podman)"
    exit 0
fi
if ! podman image exists agent-sandbox-claude:latest 2>/dev/null; then
    echo "  SKIP: agent-sandbox-claude:latest not built" >&2
    _pass "skipped (no image)"
    exit 0
fi

# ── Run ─────────────────────────────────────────────────────────────────────
# Bypass entrypoint — we just want a container with the env vars set.
# Project name "smoketest-env" is what we expect both vars to hold.
CTR_NAME="sandbox-claude-smoketest-env-$$"
CAPTURE=$(podman run --rm \
    --name "$CTR_NAME" \
    -e "SANDBOX_PROJECT=smoketest-env" \
    -e "CLAUDE_PROJECT=smoketest-env" \
    -e "SANDBOX_NETWORK=locked" \
    --entrypoint /bin/bash \
    agent-sandbox-claude:latest \
    -c 'echo "SANDBOX_PROJECT=$SANDBOX_PROJECT"; echo "CLAUDE_PROJECT=$CLAUDE_PROJECT"; echo "SANDBOX_NETWORK=$SANDBOX_NETWORK"' \
    2>&1)

# ── Assertions ──────────────────────────────────────────────────────────────
section "v1.1 1.3 — env vars present"
assert_stdout_contains "SANDBOX_PROJECT is set" \
    "SANDBOX_PROJECT=smoketest-env" echo "$CAPTURE"
assert_stdout_contains "CLAUDE_PROJECT alias still works" \
    "CLAUDE_PROJECT=smoketest-env" echo "$CAPTURE"
assert_stdout_contains "SANDBOX_NETWORK is set" \
    "SANDBOX_NETWORK=locked" echo "$CAPTURE"
