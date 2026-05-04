#!/bin/bash
# audit.sh — verify sandbox isolation invariants
#
# Runs INSIDE a sandbox container. Reads $SANDBOX_NETWORK to choose policy:
#   locked (default) — verify allowlist policy: per-agent domains reachable, others blocked
#   open             — verify open policy: public reachable, private blocked
#
# Exit code: 0 if all checks pass, 1 otherwise.
# Output ends with a parseable line: AUDIT_RESULT mode=... pass=N fail=N warn=N

set -uo pipefail

NETWORK="${SANDBOX_NETWORK:-locked}"

PASS=0
FAIL=0
WARN=0

ok()    { PASS=$((PASS+1)); echo -e "\033[0;32m[PASS]\033[0m $1"; }
fail()  { FAIL=$((FAIL+1)); echo -e "\033[0;31m[FAIL]\033[0m $1"; }
warning() { WARN=$((WARN+1)); echo -e "\033[1;33m[WARN]\033[0m $1"; }

section() { echo ""; echo "=== $1 ==="; }

check() {
    local desc="$1"; shift
    # shellcheck disable=SC2294  # eval is intentional: $@ is a single string holding a compound command
    if eval "$@" >/dev/null 2>&1; then
        ok "$desc"
    else
        fail "$desc"
    fi
}

# Inverse: passes if command FAILS
check_not() {
    local desc="$1"; shift
    # shellcheck disable=SC2294  # eval is intentional: $@ is a single string holding a compound command
    if ! eval "$@" >/dev/null 2>&1; then
        ok "$desc"
    else
        fail "$desc"
    fi
}

echo "Sandbox audit — mode: $NETWORK"
echo "================================================================"

# ── STRUCTURAL CHECKS (mode-independent) ────────────────────────────────────

section "FILESYSTEM — host directories not visible"
for path in /Users /Applications /Library /Volumes /private; do
    check_not "$path not visible" "[ -d $path ]"
done

section "FILESYSTEM — workspace mount"
check "/workspace exists and is writable" \
      "[ -d /workspace ] && touch /workspace/.audit-write-test && rm /workspace/.audit-write-test"

section "USERS — UID separation"
check "agent user exists with non-root UID" \
      "id agent | grep -qE 'uid=[0-9]+\\(agent\\)' && [ \"\$(id -u agent)\" -ne 0 ]"
check "proxy system user exists (UID 13)" "id proxy | grep -q 'uid=13(proxy)'"
check "agent != proxy" "[ \"\$(id -u agent)\" != \"\$(id -u proxy)\" ]"

section "FILE OWNERSHIP — config files root-owned, not agent-writable"
check "/etc/squid-locked.conf is root-owned" \
      "[ \"\$(stat -c '%U' /etc/squid-locked.conf)\" = root ]"
check "/etc/squid-open.conf is root-owned" \
      "[ \"\$(stat -c '%U' /etc/squid-open.conf)\" = root ]"
check "/etc/nftables-locked.conf is root-owned" \
      "[ \"\$(stat -c '%U' /etc/nftables-locked.conf)\" = root ]"
check "/etc/nftables-open.conf is root-owned" \
      "[ \"\$(stat -c '%U' /etc/nftables-open.conf)\" = root ]"
check "/etc/squid/domains.txt is root-owned" \
      "[ \"\$(stat -c '%U' /etc/squid/domains.txt)\" = root ]"
check_not "agent cannot write /etc/squid-locked.conf" \
          "sudo -u agent test -w /etc/squid-locked.conf"
check_not "agent cannot write /etc/nftables-locked.conf" \
          "sudo -u agent test -w /etc/nftables-locked.conf"
check_not "agent cannot write /etc/squid/domains.txt" \
          "sudo -u agent test -w /etc/squid/domains.txt"

section "HOME — no leaked credentials"
check_not "no .ssh in /home/agent"   "[ -d /home/agent/.ssh ]"
check_not "no .aws in /home/agent"   "[ -d /home/agent/.aws ]"
check_not "no .gnupg in /home/agent" "[ -d /home/agent/.gnupg ]"
check_not "no .kube in /home/agent"  "[ -d /home/agent/.kube ]"

section "PROXY — squid running and reachable"
# We test that squid is RUNNING (pgrep) and that REQUESTS through it succeed
# (curl below). Together these are sufficient evidence it's listening on
# 127.0.0.1:3128 — no need for a separate ss/netstat check (and ss isn't
# in the base image anyway).
check "squid process running" "pgrep -x squid"
check "curl through proxy reaches a sanity domain" \
      "curl -sf -o /dev/null --max-time 8 --proxy http://127.0.0.1:3128 http://ports.ubuntu.com"

section "NFTABLES — ruleset loaded"
check "nft ruleset has sandbox table" \
      "sudo nft list ruleset 2>/dev/null | grep -q 'table inet sandbox'"
# nft can render the user constraint as: skuid "proxy" / skuid proxy / skuid 13
# depending on version + whether name resolution kicked in. Any of those works
# for our purposes — we just need to confirm a skuid clause is in the ruleset.
check "nftables has proxy-uid bypass" \
      "sudo nft list ruleset 2>/dev/null | grep -q skuid"

# ── DIRECT BYPASS — should fail in both modes ──────────────────────────────

section "NETWORK — direct bypass (without proxy) must be blocked by nftables"
check_not "direct HTTPS to public IP blocked" \
          "curl -sf --noproxy '*' --max-time 4 -o /dev/null https://8.8.8.8"
check_not "direct HTTP  to public IP blocked" \
          "curl -sf --noproxy '*' --max-time 4 -o /dev/null http://8.8.8.8"

# ── MODE-DEPENDENT CHECKS ───────────────────────────────────────────────────

if [ "$NETWORK" = "locked" ]; then

    section "LOCKED — allowlisted domains reachable via proxy"
    check "github.com reachable" \
          "curl -sf -o /dev/null --max-time 8 --proxy http://127.0.0.1:3128 https://github.com"
    check "pypi.org reachable" \
          "curl -sf -o /dev/null --max-time 8 --proxy http://127.0.0.1:3128 https://pypi.org"
    check "registry.npmjs.org reachable" \
          "curl -sf -o /dev/null --max-time 8 --proxy http://127.0.0.1:3128 https://registry.npmjs.org"

    section "LOCKED — non-allowlisted domains denied via proxy"
    check_not "example.com denied" \
              "curl -sf -o /dev/null --max-time 4 --proxy http://127.0.0.1:3128 http://example.com"
    check_not "facebook.com denied" \
              "curl -sf -o /dev/null --max-time 4 --proxy http://127.0.0.1:3128 http://facebook.com"
    check_not "reddit.com denied" \
              "curl -sf -o /dev/null --max-time 4 --proxy http://127.0.0.1:3128 http://reddit.com"
    check_not "marlin-2.docker.com denied (Docker telemetry)" \
              "curl -sf -o /dev/null --max-time 4 --proxy http://127.0.0.1:3128 http://marlin-2.docker.com"

elif [ "$NETWORK" = "open" ]; then

    section "OPEN — public domains reachable via proxy"
    check "example.com reachable" \
          "curl -sf -o /dev/null --max-time 8 --proxy http://127.0.0.1:3128 http://example.com"
    check "github.com reachable" \
          "curl -sf -o /dev/null --max-time 8 --proxy http://127.0.0.1:3128 https://github.com"
    # Bare-public-IP positive test. Specifically guards against netmask typos
    # in the deny chain that would only show up for bare-IP requests in
    # certain ranges (e.g. accidentally writing `dst 8.0.0.0/8` instead of
    # `dst 80.0.0.0/8`, or `dst 1.0.0.0/8` instead of `dst 10.0.0.0/8`).
    # Named-host tests above don't catch these because they resolve to other
    # IP ranges.
    #
    # We verify the property by reading squid's own access log, NOT by
    # checking whether curl successfully reached the upstream. This matters
    # because well-known public DNS resolver IPs (1.1.1.1, 8.8.8.8, 9.9.9.9)
    # are routinely intercepted, blocked, or null-routed by ISPs and corporate
    # networks. We don't care if the operator's network actually reaches
    # 8.8.8.8 — we care whether squid would have *allowed* the request.
    #
    # Squid logs `TCP_DENIED/403` when its ACL chain denies a request; any
    # other action code (TCP_MISS, TCP_MISS_ABORTED, TCP_TUNNEL, etc.) means
    # the chain allowed it. We send a request, give squid a moment to flush
    # its log buffer, then check for absence of TCP_DENIED.
    check "squid does not deny bare-IP 8.8.8.8 (regression: deny-chain netmask typos)" \
          "{ curl -s -o /dev/null --max-time 3 --proxy http://127.0.0.1:3128 http://8.8.8.8 || true; } ; \
           sleep 1; \
           ! sudo grep -q 'TCP_DENIED.*http://8.8.8.8' /var/log/squid/access.log 2>/dev/null"

    section "OPEN — private destinations blocked via proxy"
    check_not "RFC1918 192.168.1.1 blocked" \
              "curl -sf -o /dev/null --max-time 4 --proxy http://127.0.0.1:3128 http://192.168.1.1"
    check_not "RFC1918 10.0.0.1 blocked" \
              "curl -sf -o /dev/null --max-time 4 --proxy http://127.0.0.1:3128 http://10.0.0.1"
    check_not "RFC1918 172.16.0.1 blocked" \
              "curl -sf -o /dev/null --max-time 4 --proxy http://127.0.0.1:3128 http://172.16.0.1"
    check_not "Link-local 169.254.169.254 blocked (cloud metadata)" \
              "curl -sf -o /dev/null --max-time 4 --proxy http://127.0.0.1:3128 http://169.254.169.254"
    check_not "CGNAT 100.64.0.1 blocked" \
              "curl -sf -o /dev/null --max-time 4 --proxy http://127.0.0.1:3128 http://100.64.0.1"

    section "OPEN — private destinations blocked at nftables (defense in depth)"
    check_not "direct connection to 192.168.1.1 fails (nftables drop)" \
              "curl -sf --noproxy '*' --max-time 3 -o /dev/null http://192.168.1.1"
    check_not "direct connection to 10.0.0.1 fails (nftables drop)" \
              "curl -sf --noproxy '*' --max-time 3 -o /dev/null http://10.0.0.1"
    check_not "direct connection to 169.254.169.254 fails (nftables drop)" \
              "curl -sf --noproxy '*' --max-time 3 -o /dev/null http://169.254.169.254"

    section "OPEN — IPv6 disabled in container"
    check "IPv6 disabled (all)" \
          "[ \"\$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)\" = 1 ]"
    check "IPv6 disabled (default)" \
          "[ \"\$(cat /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null)\" = 1 ]"

else
    fail "Unknown SANDBOX_NETWORK mode: $NETWORK"
fi

# ── SUMMARY ─────────────────────────────────────────────────────────────────

echo ""
echo "================================================================"
echo "Sandbox audit summary — mode: $NETWORK"
echo "Passed:   $PASS"
echo "Failed:   $FAIL"
echo "Warnings: $WARN"
echo "================================================================"
echo "AUDIT_RESULT mode=$NETWORK pass=$PASS fail=$FAIL warn=$WARN"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
