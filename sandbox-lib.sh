#!/bin/bash
# sandbox-lib.sh — Shared library for the agent-sandbox Podman sandbox tool.
#
# Provides: logging, podman utilities, volume management, base image generation,
# the locked/open squid + nftables config files baked into the base image.
#
# Sourced by agent-sandbox. Designed to be reusable by other Podman-based
# tooling that wants the same logging primitives and base image layer.

# Guard against double-sourcing
[[ -n "${_SANDBOX_LIB_LOADED:-}" ]] && return 0
_SANDBOX_LIB_LOADED=1

# ── Colours and logging ──────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[sandbox]${NC} $*"; }
ok()   { echo -e "${GREEN}[  ok  ]${NC} $*"; }
warn() { echo -e "${YELLOW}[ warn ]${NC} $*"; }
err()  { echo -e "${RED}[error ]${NC} $*" >&2; }

# ── Podman utilities ─────────────────────────────────────────────────────────

require_podman() {
    if ! command -v podman &>/dev/null; then
        err "podman not found. Install with: brew install podman"
        exit 1
    fi
    if ! podman machine info &>/dev/null 2>&1; then
        err "Podman machine not running. Start with: podman machine start"
        exit 1
    fi
}

image_exists() {
    podman image exists "$1" 2>/dev/null
}

container_exists() {
    podman container exists "$1" 2>/dev/null
}

volume_exists() {
    podman volume exists "$1" 2>/dev/null
}

volume_ensure() {
    local vol="$1"
    local label="${2:-}"
    if ! volume_exists "$vol"; then
        podman volume create "$vol" ${label:+--label "$label"}
        ok "Volume created: ${vol}"
    else
        ok "Volume exists: ${vol}"
    fi
}

volume_remove() {
    local vol="$1"
    if volume_exists "$vol"; then
        podman volume rm "$vol"
        ok "Volume removed: ${vol}"
    fi
}

list_containers_by_prefix() {
    local prefix="$1"
    podman ps -a --filter "name=^${prefix}-" --format '{{.Names}}\t{{.State}}\t{{.Created}}' 2>/dev/null
}

# ── Container naming ─────────────────────────────────────────────────────────

sanitize_name() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g'
}

container_name_for() {
    local prefix="$1" qualifier="$2" project_name="$3"
    echo "${prefix}-${qualifier}-$(sanitize_name "$project_name")"
}

# ── Path utilities ───────────────────────────────────────────────────────────

resolve_project_path() {
    local raw="$1"
    local resolved
    resolved="$(cd "$raw" 2>/dev/null && pwd)" || {
        err "Project path does not exist: $raw"
        exit 1
    }
    echo "$resolved"
}

# ── Base image generation ────────────────────────────────────────────────────
# Writes the shared base image Dockerfile and the four config files
# (squid-locked.conf, squid-open.conf, nftables-locked.conf, nftables-open.conf)
# to the specified build directory. Agent/tool-specific images layer on top.

write_base_build_context() {
    local build_dir="$1"
    mkdir -p "${build_dir}/base"

    # Base Dockerfile — shared tools, no agent packages, no domain allowlist.
    # DEBIAN_FRONTEND scoped per-RUN to avoid persisting into runtime ENV.
    cat > "${build_dir}/base/Dockerfile" << 'DOCKERFILE'
FROM ubuntu:24.04

RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    squid nftables curl ca-certificates git jq ripgrep fd-find \
    less vim-tiny sudo python3 python3-pip python3-venv \
    zip unzip wget \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd

RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# uv + ruff
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && curl -LsSf https://astral.sh/ruff/install.sh | sh \
    && mv /root/.local/bin/uv /usr/local/bin/ \
    && mv /root/.local/bin/uvx /usr/local/bin/ \
    && mv /root/.local/bin/ruff /usr/local/bin/

RUN useradd -m -s /bin/bash agent \
    && echo "agent ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/agent

RUN printf 'Acquire::http::Proxy "http://127.0.0.1:3128";\nAcquire::https::Proxy "http://127.0.0.1:3128";\n' \
    > /etc/apt/apt.conf.d/95proxy

# Two squid configs and two nftables configs, baked in. Entrypoint selects
# between them via $SANDBOX_NETWORK at container start. Files live at top of
# /etc/ (not /etc/squid/) because squid is invoked with -f to point at the
# right one — the canonical /etc/squid/squid.conf path is unused.
COPY squid-locked.conf    /etc/squid-locked.conf
COPY squid-open.conf      /etc/squid-open.conf
COPY nftables-locked.conf /etc/nftables-locked.conf
COPY nftables-open.conf   /etc/nftables-open.conf

# Proxy env set AFTER installs — squid doesn't exist during build
ENV HTTP_PROXY=http://127.0.0.1:3128 \
    HTTPS_PROXY=http://127.0.0.1:3128 \
    http_proxy=http://127.0.0.1:3128 \
    https_proxy=http://127.0.0.1:3128 \
    NO_PROXY=localhost,127.0.0.1 \
    no_proxy=localhost,127.0.0.1

WORKDIR /workspace
DOCKERFILE

    # ── squid-locked.conf — default-deny allowlist (per-agent domains.txt)
    # This is the original squid.conf, unchanged. Domain allowlist is mounted
    # by the per-agent image at /etc/squid/domains.txt.
    cat > "${build_dir}/base/squid-locked.conf" << 'SQUIDCONF'
http_port 127.0.0.1:3128
acl allowed_domains dstdomain "/etc/squid/domains.txt"
acl SSL_ports port 443
acl Safe_ports port 80
acl Safe_ports port 443
acl CONNECT method CONNECT
http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow allowed_domains
http_access deny all
access_log /var/log/squid/access.log
cache_log /var/log/squid/cache.log
cache deny all
forwarded_for delete
via off
cache_effective_user proxy
cache_effective_group proxy
pid_filename /run/squid/squid.pid
shutdown_lifetime 2 seconds
SQUIDCONF

    # ── squid-open.conf — public allow, private deny (defense in depth alongside nftables)
    # Loopback denial below is for proxy DESTINATIONS, not squid's own listener.
    # Do not "fix" this — it stops the agent from making squid proxy to itself.
    cat > "${build_dir}/base/squid-open.conf" << 'SQUIDCONF'
http_port 127.0.0.1:3128
acl SSL_ports port 443
acl Safe_ports port 80
acl Safe_ports port 443
acl CONNECT method CONNECT
http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports

# Private destinations (IPv4)
acl rfc1918   dst 10.0.0.0/8
acl rfc1918   dst 172.16.0.0/12
acl rfc1918   dst 192.168.0.0/16
acl linklocal dst 169.254.0.0/16
acl loopback  dst 127.0.0.0/8
acl cgnat     dst 100.64.0.0/10
acl mcast     dst 224.0.0.0/4
acl bcast     dst 255.255.255.255/32
acl reserved  dst 192.0.0.0/24
acl reserved  dst 192.0.2.0/24
acl reserved  dst 198.18.0.0/15
acl reserved  dst 198.51.100.0/24
acl reserved  dst 203.0.113.0/24
acl reserved  dst 240.0.0.0/4
# Private destinations (IPv6) — defense in depth even with IPv6 stack disabled
acl ipv6_ula    dst fc00::/7
acl ipv6_lladdr dst fe80::/10
acl ipv6_loop   dst ::1/128

http_access deny rfc1918
http_access deny linklocal
http_access deny loopback
http_access deny cgnat
http_access deny mcast
http_access deny bcast
http_access deny reserved
http_access deny ipv6_ula
http_access deny ipv6_lladdr
http_access deny ipv6_loop
http_access allow all

access_log /var/log/squid/access.log
cache_log /var/log/squid/cache.log
cache deny all
forwarded_for delete
via off
cache_effective_user proxy
cache_effective_group proxy
pid_filename /run/squid/squid.pid
shutdown_lifetime 2 seconds
SQUIDCONF

    # ── nftables-locked.conf — proxy-user-only egress on 80/443
    # Same as the original nftables.conf, unchanged.
    cat > "${build_dir}/base/nftables-locked.conf" << 'NFTABLES'
#!/usr/sbin/nft -f
flush ruleset
table inet sandbox {
    chain output {
        type filter hook output priority 0; policy accept;
        oifname "lo" accept
        tcp dport 53 accept
        udp dport 53 accept
        meta skuid proxy tcp dport { 80, 443 } accept
        tcp dport { 80, 443 } reject with tcp reset
        accept
    }
}
NFTABLES

    # ── nftables-open.conf — proxy-user-only on 80/443, plus drop private destinations
    # for everyone (including the proxy user) as defense in depth against squid mistakes.
    cat > "${build_dir}/base/nftables-open.conf" << 'NFTABLES'
#!/usr/sbin/nft -f
flush ruleset
table inet sandbox {
    chain output {
        type filter hook output priority 0; policy accept;
        oifname "lo" accept
        tcp dport 53 accept
        udp dport 53 accept
        # Drop egress to private destinations regardless of source UID
        ip daddr 10.0.0.0/8     drop
        ip daddr 172.16.0.0/12  drop
        ip daddr 192.168.0.0/16 drop
        ip daddr 169.254.0.0/16 drop
        ip daddr 100.64.0.0/10  drop
        # Standard proxy-user-only on 80/443
        meta skuid proxy tcp dport { 80, 443 } accept
        tcp dport { 80, 443 } reject with tcp reset
        accept
    }
}
NFTABLES

    ok "Base build context written to ${build_dir}/base"
}

# Build the shared base image
build_base_image() {
    local build_dir="$1"
    local image_name="${2:-agent-sandbox-base}"
    local image_tag="${3:-latest}"

    log "Building base image..."
    if ! podman build -t "${image_name}:${image_tag}" "${build_dir}/base"; then
        err "Base image build failed"
        return 1
    fi
    ok "Base image: ${image_name}:${image_tag}"
}

# ── Entrypoint template (UNUSED — see IMPROVEMENTS.md item #1) ───────────────
# Currently dead code: agent-sandbox writes its own three entrypoint heredocs
# inline rather than calling this helper. Kept for now to avoid breaking any
# downstream consumers; see IMPROVEMENTS.md for the consolidation plan.

write_entrypoint() {
    local output_path="$1"
    local agent_name="$2"
    local agent_setup_block="${3:-}"   # Extra bash commands for agent-specific config
    local exec_wrapper="${4:-}"        # Wrap the final exec (e.g., dbus-run-session)

    cat > "$output_path" << ENTRYPOINT_HEADER
#!/bin/bash
# --- Network mode selection (validated; fail closed) ---
case "\${SANDBOX_NETWORK:-locked}" in
    locked) SQUID_CONF=/etc/squid-locked.conf  ; NFT_CONF=/etc/nftables-locked.conf ;;
    open)   SQUID_CONF=/etc/squid-open.conf    ; NFT_CONF=/etc/nftables-open.conf ;;
    *)      echo "[entrypoint] FATAL: invalid SANDBOX_NETWORK='\${SANDBOX_NETWORK}'" >&2
            exit 1 ;;
esac

# --- Squid proxy ---
mkdir -p /run/squid /var/log/squid
chown proxy:proxy /run/squid /var/log/squid
squid -f "\$SQUID_CONF" -z --foreground 2>/dev/null || true
squid -f "\$SQUID_CONF" -NYC &
SQUID_PID=\$!

for _ in \$(seq 1 30); do
    if curl -sf -o /dev/null --proxy http://127.0.0.1:3128 http://ports.ubuntu.com 2>/dev/null; then
        break
    fi
    sleep 0.2
done

# --- nftables ---
nft -f "\$NFT_CONF" 2>/dev/null || true

ENTRYPOINT_HEADER

    # Agent-specific setup block
    if [ -n "$agent_setup_block" ]; then
        echo "$agent_setup_block" >> "$output_path"
        echo "" >> "$output_path"
    fi

    # Prompt with random colour and optional [OPEN] tag
    cat >> "$output_path" << ENTRYPOINT_PROMPT
# --- Prompt (visual indicator for open mode; user can override) ---
COLORS=(31 32 33 34 35 36 91 92 93 94 95 96)
CLR=\${COLORS[\$((RANDOM % \${#COLORS[@]}))]}
NETMODE_TAG=""
if [ "\${SANDBOX_NETWORK:-locked}" = "open" ]; then
    NETMODE_TAG="\\\\[\\\\033[1;31m\\\\][OPEN]\\\\[\\\\033[0m\\\\] "
fi
echo "# SANDBOX_NETWORK=\${SANDBOX_NETWORK:-locked} — override PS1 below to taste" \\
    >> /home/agent/.bashrc
echo "PS1='\${NETMODE_TAG}\\\\[\\\\033[1;\${CLR}m\\\\]${agent_name}@\\\\h\\\\[\\\\033[0m\\\\]:\\\\[\\\\033[1;34m\\\\]\\\\w\\\\[\\\\033[0m\\\\]\\\$ '" \\
    >> /home/agent/.bashrc
echo "export SANDBOX_NETWORK=\${SANDBOX_NETWORK:-locked}" >> /home/agent/.bashrc

ENTRYPOINT_PROMPT

    # Shutdown handler
    cat >> "$output_path" << 'ENTRYPOINT_SHUTDOWN'
# --- Shutdown ---
cleanup() { kill "$SQUID_PID" 2>/dev/null; wait "$SQUID_PID" 2>/dev/null; exit 0; }
trap cleanup SIGTERM SIGINT

ENTRYPOINT_SHUTDOWN

    # Exec block
    if [ -n "$exec_wrapper" ]; then
        cat >> "$output_path" << ENTRYPOINT_EXEC_WRAP
# --- Exec (wrapped) ---
CMD="\${*:-/bin/bash}"
exec sudo -u agent --preserve-env=HTTP_PROXY,HTTPS_PROXY,http_proxy,https_proxy,NO_PROXY,no_proxy \\
    env HOME=/home/agent \\
    ${exec_wrapper}
ENTRYPOINT_EXEC_WRAP
    else
        cat >> "$output_path" << 'ENTRYPOINT_EXEC'
# --- Exec ---
CMD="${*:-/bin/bash}"
exec sudo -u agent --preserve-env=HTTP_PROXY,HTTPS_PROXY,http_proxy,https_proxy,NO_PROXY,no_proxy \
    env HOME=/home/agent \
    bash -c "cd /workspace && $CMD"
ENTRYPOINT_EXEC
    fi
}
