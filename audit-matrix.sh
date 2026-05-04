#!/usr/bin/env bash
# audit-matrix.sh — runs audit.sh inside every (agent x network-mode) combination
# and prints a signal-rich summary table.
#
# Requires: agent-sandbox setup has been run, audit.sh is in this directory.
# Exits non-zero if any cell shows failures.

# shellcheck disable=SC2059  # printf format strings include ANSI color vars by design

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS=(claude pi gemini)
MODES=(locked open)
TEST_PROJECT="${HOME}/.agent-sandbox-audit-tmp"

# ── Colors (printf-interpreted) ─────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# ── Helpers ─────────────────────────────────────────────────────────────────

# Strip ANSI escape sequences from stdin. Required for grep/sed against
# audit output, which is colorized via echo -e.
strip_ansi() {
    sed 's/\x1b\[[0-9;]*m//g'
}

# ── Pre-flight ──────────────────────────────────────────────────────────────
if ! command -v podman >/dev/null 2>&1; then
    echo "podman not found" >&2; exit 2
fi

if [ ! -f "$SCRIPT_DIR/audit.sh" ]; then
    echo "audit.sh not found alongside this script (expected at $SCRIPT_DIR/audit.sh)" >&2
    exit 2
fi

for a in "${AGENTS[@]}"; do
    if ! podman image exists "agent-sandbox-${a}:latest"; then
        echo "Image agent-sandbox-${a}:latest missing. Run: ./agent-sandbox setup" >&2
        exit 2
    fi
done

# Make the test workspace world-writable so the agent UID inside the container
# can write to it regardless of host UID / podman userns mapping. Real project
# directories are written by the user as the container's effective owner; for
# this synthetic test we don't have that luxury, so we open the perms.
mkdir -p "$TEST_PROJECT"
chmod 777 "$TEST_PROJECT"
cp "$SCRIPT_DIR/audit.sh" "$TEST_PROJECT/audit.sh"
chmod +x "$TEST_PROJECT/audit.sh"

# ── Run matrix ──────────────────────────────────────────────────────────────

declare -A RESULT_PASS RESULT_FAIL RESULT_WARN RESULT_OUTCOME
TOTAL_FAIL=0
START_TIME=$(date +%s)

for agent in "${AGENTS[@]}"; do
    for mode in "${MODES[@]}"; do
        cell="${agent}/${mode}"
        ctr_name="sandbox-${agent}-$(basename "$TEST_PROJECT" | tr -cd 'a-z0-9-')"

        # Make sure no prior container blocks us
        podman rm -f "$ctr_name" >/dev/null 2>&1 || true

        printf "${DIM}── Running %-8s × %-8s${NC}\n" "$agent" "$mode"

        # Run audit inside the sandbox. Bypass the agent-sandbox CLI's
        # refuse-on-existing check by going direct to podman, since this is
        # automated testing and we just `rm -f`'d any prior container.
        AGENT_VOL="${agent}-sandbox-auth"
        case "$agent" in
            claude) CONFIG_DIR=/home/agent/.claude   ; PORTS=() ;;
            pi)     CONFIG_DIR=/home/agent/.pi       ; PORTS=(-p 8085) ;;
            gemini) CONFIG_DIR=/home/agent/.gemini   ; PORTS=(-p 8085) ;;
        esac

        # IPv6 disable for open mode (must match what agent-sandbox does)
        SYSCTLS=()
        if [ "$mode" = "open" ]; then
            SYSCTLS=(--sysctl "net.ipv6.conf.all.disable_ipv6=1"
                     --sysctl "net.ipv6.conf.default.disable_ipv6=1")
        fi

        OUTPUT=$(podman run --rm \
            --name "$ctr_name" \
            --hostname "audit-${agent}-${mode}" \
            --cap-add=NET_ADMIN \
            -v "${TEST_PROJECT}:/workspace:rw" \
            -v "${AGENT_VOL}:${CONFIG_DIR}:rw" \
            -e "SANDBOX_NETWORK=${mode}" \
            "${PORTS[@]+"${PORTS[@]}"}" \
            "${SYSCTLS[@]+"${SYSCTLS[@]}"}" \
            "agent-sandbox-${agent}:latest" \
            bash -c 'sleep 4; SANDBOX_NETWORK='"$mode"' bash /workspace/audit.sh' 2>&1) || true

        # Strip ANSI from captured output before parsing — audit colorizes with
        # echo -e, and the [FAIL] tag is prefixed by an escape sequence.
        CLEAN_OUTPUT=$(printf '%s\n' "$OUTPUT" | strip_ansi)

        # Parse the AUDIT_RESULT line
        SUMMARY_LINE=$(echo "$CLEAN_OUTPUT" | grep '^AUDIT_RESULT' | tail -1)
        if [ -n "$SUMMARY_LINE" ]; then
            P=$(echo "$SUMMARY_LINE" | grep -oE 'pass=[0-9]+' | cut -d= -f2)
            F=$(echo "$SUMMARY_LINE" | grep -oE 'fail=[0-9]+' | cut -d= -f2)
            W=$(echo "$SUMMARY_LINE" | grep -oE 'warn=[0-9]+' | cut -d= -f2)
            RESULT_PASS[$cell]=$P
            RESULT_FAIL[$cell]=$F
            RESULT_WARN[$cell]=$W
            if [ "${F:-0}" -eq 0 ]; then
                RESULT_OUTCOME[$cell]="PASS"
            else
                RESULT_OUTCOME[$cell]="FAIL"
                TOTAL_FAIL=$((TOTAL_FAIL + F))
                # Show failing checks (now that ANSI is stripped, [FAIL] is at column 1)
                echo "$CLEAN_OUTPUT" | grep '^\[FAIL\]' | sed 's/^/        /'
            fi
        else
            RESULT_PASS[$cell]=0
            RESULT_FAIL[$cell]=0
            RESULT_WARN[$cell]=0
            RESULT_OUTCOME[$cell]="ERROR"
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
            echo "        (audit did not produce a summary line — container may have failed to start)"
            echo "$CLEAN_OUTPUT" | tail -10 | sed 's/^/        /'
        fi
    done
done

ELAPSED=$(($(date +%s) - START_TIME))

# ── Cleanup ─────────────────────────────────────────────────────────────────
rm -rf "$TEST_PROJECT"

# ── Summary table ───────────────────────────────────────────────────────────
printf "\n"
printf "${BOLD}=========================================================${NC}\n"
printf "${BOLD}  Audit matrix summary (%ss)${NC}\n" "$ELAPSED"
printf "${BOLD}=========================================================${NC}\n"
printf "\n"

# Header
printf "  %-10s" "agent"
for mode in "${MODES[@]}"; do
    printf "  %-22s" "$mode"
done
printf "\n"
printf "  %-10s" "──────────"
for mode in "${MODES[@]}"; do
    printf "  %-22s" "──────────────────────"
done
printf "\n"

# Rows
for agent in "${AGENTS[@]}"; do
    printf "  %-10s" "$agent"
    for mode in "${MODES[@]}"; do
        cell="${agent}/${mode}"
        outcome=${RESULT_OUTCOME[$cell]:-MISSING}
        p=${RESULT_PASS[$cell]:-0}
        f=${RESULT_FAIL[$cell]:-0}
        w=${RESULT_WARN[$cell]:-0}
        case "$outcome" in
            PASS)  color=$GREEN ;;
            FAIL)  color=$RED ;;
            *)     color=$YELLOW ;;
        esac
        cell_text=$(printf "%s %d pass / %d fail" "$outcome" "$p" "$f")
        if [ "$w" != "0" ]; then
            cell_text="$cell_text / $w warn"
        fi
        printf "  ${color}%-22s${NC}" "$cell_text"
    done
    printf "\n"
done
printf "\n"

# Final status
if [ "$TOTAL_FAIL" -eq 0 ]; then
    printf "${GREEN}${BOLD}OVERALL: PASS${NC} — all %d cells clean\n" \
        $((${#AGENTS[@]} * ${#MODES[@]}))
    exit 0
else
    printf "${RED}${BOLD}OVERALL: FAIL${NC} — %d failed checks across the matrix\n" "$TOTAL_FAIL"
    exit 1
fi
