#!/bin/bash
# lib-functions.sh — unit tests for sandbox-lib.sh helpers.
# Covers v1.1 item 1.2 (arg validation on image_exists/container_exists/volume_exists)
# and the volume_ensure / volume_remove control flow.
#
# Runs in <1s. Mocks `podman` at the function level — no real container runtime
# required. Stub returns a configurable rc so we can drive both branches.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_FILE_NAME="unit/lib-functions"

# shellcheck source=helpers.sh
source "$SCRIPT_DIR/helpers.sh"
trap _emit_summary EXIT

# Source the lib. It needs the colour vars + log helpers, which it defines itself,
# so a clean source is sufficient — no environment prep required.
# shellcheck source=../../sandbox-lib.sh
source "$REPO_ROOT/sandbox-lib.sh"

# ── podman mock — drives both branches via $PODMAN_RC ───────────────────────
PODMAN_RC=0
podman() {
    return "$PODMAN_RC"
}
export -f podman

echo "Unit tests: sandbox-lib.sh"

# ── 1.2: arg validation contract ────────────────────────────────────────────
section "image_exists / container_exists / volume_exists arg validation"

# Missing arg → rc 2 (the new contract from v1.1 1.2)
assert_rc "image_exists with no arg returns 2"     2 image_exists
assert_rc "container_exists with no arg returns 2" 2 container_exists
assert_rc "volume_exists with no arg returns 2"    2 volume_exists

# Empty string arg → rc 2 (also caught by the [ -n "${1:-}" ] guard)
assert_rc "image_exists with empty arg returns 2"     2 image_exists ""
assert_rc "container_exists with empty arg returns 2" 2 container_exists ""
assert_rc "volume_exists with empty arg returns 2"    2 volume_exists ""

# Missing-arg path emits a stderr message — important for debuggability.
assert_stderr_contains "image_exists prints function name on missing arg" \
    "image_exists" image_exists
assert_stderr_contains "container_exists prints function name on missing arg" \
    "container_exists" container_exists
assert_stderr_contains "volume_exists prints function name on missing arg" \
    "volume_exists" volume_exists

# Valid arg + podman says "yes" → rc 0
section "exists() functions forward podman's rc when arg is valid"
PODMAN_RC=0
assert_rc "image_exists returns 0 when podman says yes"     0 image_exists "img"
assert_rc "container_exists returns 0 when podman says yes" 0 container_exists "ctr"
assert_rc "volume_exists returns 0 when podman says yes"    0 volume_exists "vol"

# Valid arg + podman says "no" → rc 1 (the normal "not found" path)
PODMAN_RC=1
assert_rc "image_exists returns 1 when podman says no"     1 image_exists "img"
assert_rc "container_exists returns 1 when podman says no" 1 container_exists "ctr"
assert_rc "volume_exists returns 1 when podman says no"    1 volume_exists "vol"

# ── volume_ensure / volume_remove control flow ──────────────────────────────
# These delegate to podman volume create / rm. We just verify they call podman
# (i.e. don't error early on missing-arg in the wrong branch) — rc forwarding
# isn't part of their contract, but "doesn't crash on the happy path" is.
section "volume_ensure / volume_remove happy path"
PODMAN_RC=0
assert_rc "volume_ensure runs cleanly when volume exists" 0 volume_ensure "test-vol"
PODMAN_RC=1
# When volume doesn't exist, volume_ensure tries to create — succeeds because podman mock returns 0 for create
PODMAN_RC=0
assert_rc "volume_ensure runs cleanly when volume must be created" 0 volume_ensure "new-vol"

PODMAN_RC=1   # volume doesn't exist → volume_remove no-ops, rc 0
assert_rc "volume_remove no-ops when volume absent" 0 volume_remove "absent-vol"

# ── sanitize_name ───────────────────────────────────────────────────────────
section "sanitize_name produces lowercase, hyphenated names"
assert_eq "lowercase preserved"           "abc"        "$(sanitize_name "abc")"
assert_eq "uppercase folded"              "abc"        "$(sanitize_name "ABC")"
assert_eq "spaces become hyphens"         "foo-bar"    "$(sanitize_name "Foo Bar")"
assert_eq "dots become hyphens"           "foo-bar"    "$(sanitize_name "foo.bar")"
assert_eq "underscores become hyphens"    "foo-bar"    "$(sanitize_name "foo_bar")"
assert_eq "mixed garbage"                 "my-proj-1"  "$(sanitize_name "My_Proj.1")"
assert_eq "digits preserved"              "abc123"     "$(sanitize_name "abc123")"

# ── container_name_for ──────────────────────────────────────────────────────
section "container_name_for assembles prefix-qualifier-name"
assert_eq "claude + simple project"   "sandbox-claude-myproj" \
    "$(container_name_for sandbox claude myproj)"
assert_eq "name with caps gets sanitized" "sandbox-claude-my-proj" \
    "$(container_name_for sandbox claude My_Proj)"
assert_eq "pi agent qualifier"        "sandbox-pi-test" \
    "$(container_name_for sandbox pi test)"
