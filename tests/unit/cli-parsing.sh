#!/bin/bash
# cli-parsing.sh — unit tests for agent-sandbox's CLI argument handling.
# Covers validate_network and parse_agent_flag. Relies on the BASH_SOURCE
# guard in agent-sandbox to source the script without running its dispatcher.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_FILE_NAME="unit/cli-parsing"

# shellcheck source=helpers.sh
source "$SCRIPT_DIR/helpers.sh"
trap _emit_summary EXIT

# Source the library first (agent-sandbox sources it conditionally).
# shellcheck source=../../sandbox-lib.sh
source "$REPO_ROOT/sandbox-lib.sh"

# Source the main script. The BASH_SOURCE guard returns 0 before the
# dispatcher case statement, so all functions are defined but no commands run.
# shellcheck source=../../agent-sandbox
source "$REPO_ROOT/agent-sandbox"

echo "Unit tests: agent-sandbox CLI parsing"

# ── validate_network ────────────────────────────────────────────────────────
section "validate_network accepts known modes, rejects unknown"
assert_rc "validate_network locked → 0"  0 validate_network locked
assert_rc "validate_network open → 0"    0 validate_network open
assert_rc "validate_network bogus → 1"   1 validate_network bogus
assert_rc "validate_network LOCKED → 1 (case-sensitive)" 1 validate_network LOCKED
assert_rc "validate_network empty → 1"   1 validate_network ""

assert_stderr_contains "validate_network bogus prints helpful error" \
    "must be one of" validate_network bogus

# ── parse_agent_flag ────────────────────────────────────────────────────────
# parse_agent_flag sets globals AGENT, NETWORK, REMAINING_ARGS — call directly,
# then inspect with assert_eq. DETECTED_AGENT defaults to empty here because
# the script was sourced as 'agent-sandbox', not '<agent>-sandbox'.
section "parse_agent_flag — explicit --agent"

parse_agent_flag --agent claude /tmp/proj
assert_eq "AGENT set from --agent claude"      "claude"     "$AGENT"
assert_eq "NETWORK defaults to locked"         "locked"     "$NETWORK"
assert_eq "REMAINING_ARGS captures positional" "/tmp/proj"  "${REMAINING_ARGS[0]:-}"

parse_agent_flag --agent=pi /tmp/proj
assert_eq "AGENT set from --agent=pi"          "pi"         "$AGENT"

parse_agent_flag --agent gemini --network open /tmp/proj
assert_eq "AGENT=gemini with --network open"   "gemini"     "$AGENT"
assert_eq "NETWORK=open"                        "open"      "$NETWORK"

parse_agent_flag --agent=claude --network=open /tmp/proj
assert_eq "AGENT=claude (--agent= form)"       "claude"     "$AGENT"
assert_eq "NETWORK=open  (--network= form)"    "open"       "$NETWORK"

section "parse_agent_flag — argument order independence"
parse_agent_flag /tmp/proj --agent claude --network open
assert_eq "AGENT parsed regardless of position"  "claude" "$AGENT"
assert_eq "NETWORK parsed regardless of position" "open"  "$NETWORK"
assert_eq "positional arg captured"              "/tmp/proj" "${REMAINING_ARGS[0]:-}"

section "parse_agent_flag — failure modes"
# These all exit 1 — assert_rc handles via subshell.
assert_rc "no agent and not invoked-as → exit 1" 1 parse_agent_flag /tmp/proj
assert_rc "unknown agent → exit 1"               1 parse_agent_flag --agent bogus /tmp/proj
assert_rc "unknown network → exit 1"             1 parse_agent_flag --agent claude --network bogus /tmp/proj
assert_rc "--agent with no value → exit 1"       1 parse_agent_flag --agent
assert_rc "--network with no value → exit 1"     1 parse_agent_flag --agent claude --network

assert_stderr_contains "missing-agent error names the option" \
    "agent" parse_agent_flag /tmp/proj
assert_stderr_contains "unknown-agent error lists known agents" \
    "claude" parse_agent_flag --agent zzznope /tmp/proj

# ── agent_get sanity ────────────────────────────────────────────────────────
# agent_get returns metadata for an agent. We don't pin its full shape (would
# break on additions) — just verify it runs cleanly for known agents and
# fails for unknown.
section "agent_get / validate_agent"
assert_rc "validate_agent claude → 0"  0 validate_agent claude
assert_rc "validate_agent pi → 0"      0 validate_agent pi
assert_rc "validate_agent gemini → 0"  0 validate_agent gemini
assert_rc "validate_agent bogus → 1"   1 validate_agent bogus
