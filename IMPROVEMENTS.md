# Improvement plan

Observations from reading `agent-sandbox` (843 lines) and `sandbox-lib.sh` (288 lines) end to end. Items are ordered by impact, not effort. Each item has: **what**, **why it matters**, **proposed fix**, and **rough effort**.

The shipped patch (network modes, refuse-on-existing, port fix, IPv6 disable) intentionally did *not* tackle these. They're separate work, listed here so they don't get lost.

---

## Tier 1 — worth doing soon

### 1.1. `write_entrypoint` in `sandbox-lib.sh` is dead code

**What:** The library defines a parameterized `write_entrypoint` helper (lines 219–288 of the original `sandbox-lib.sh`, around 215–293 of the shipped version with network-mode awareness). It's never called by `agent-sandbox`. The `agent-sandbox` script writes its own three entrypoint heredocs inline.

**Why it matters:** Three near-identical entrypoint generators in `agent-sandbox` are the largest single source of code duplication in the project. Every change to entrypoint behavior (the network-mode case statement, the IPv6 disable that we ended up moving to `podman run`, the prompt customization, future additions) must be made in three places. Cross-agent drift is inevitable. Already happened: pi's entrypoint has a typo or omission someone might never notice because diffing three heredocs is tedious.

**Proposed fix:** Refactor `agent-sandbox` to use `write_entrypoint`, with these extensions to the helper:

- Accept a `network_aware` boolean (or just always emit the case statement — there's no cost when locked is the only mode used).
- Accept the `agent_setup_block` as the per-agent middle section (already supported).
- Accept the `exec_wrapper` for gemini's dbus-run-session case (already supported).

The three entrypoint heredocs collapse to three calls of the form:

```bash
write_entrypoint "${BUILD_DIR}/claude/entrypoint.sh" claude \
    "$CLAUDE_SETUP_BLOCK" ""
write_entrypoint "${BUILD_DIR}/pi/entrypoint.sh" pi \
    "$PI_SETUP_BLOCK" ""
write_entrypoint "${BUILD_DIR}/gemini/entrypoint.sh" gemini \
    "$GEMINI_SETUP_BLOCK" "dbus-run-session -- bash -c '..."
```

**Effort:** ~half a day. Two careful tasks: (a) extracting the per-agent middle blocks from the current heredocs into separate variables, (b) updating `write_entrypoint` to handle the network-mode case statement consistently. Risk: heredoc escaping is tricky — `write_entrypoint` already uses `<< 'X'` and `<< X` (with and without quotes) selectively. Test thoroughly with all three agents.

### 1.2. `image_exists` in `agent-sandbox` is called inconsistently

**What:** Looking at every call site, all are `image_exists "$img"` style — but the legacy version of the function in earlier lessons-learned could be called bare (`image_exists` with no arg). The current code is fine, but the function in `sandbox-lib.sh` doesn't validate its argument:

```bash
image_exists() {
    podman image exists "$1" 2>/dev/null
}
```

If called with no argument, `$1` is empty, and `podman image exists ""` exits with status 125 ("invalid argument"). That gets swallowed by `2>/dev/null` and the function returns 1. Looks like "image not found." Misleading.

**Why it matters:** Future callers — including a refactor that adds a new agent and forgets to pass the arg — will see false negatives. Setup will rebuild images that already exist; teardown will silently skip cleaning them up.

**Proposed fix:**
```bash
image_exists() {
    [ -n "${1:-}" ] || { err "image_exists: missing argument"; return 2; }
    podman image exists "$1" 2>/dev/null
}
```

Same treatment for `container_exists` and `volume_exists`.

**Effort:** 10 minutes.

### 1.3. `CLAUDE_PROJECT` env var is set for all agents

**What:** Line 737 of `agent-sandbox`:
```bash
-e "CLAUDE_PROJECT=${project_name}" \
```
This is set for pi and gemini containers too. Misnamed.

**Why it matters:** Cosmetic, but the agent inside reads this variable to know which project it's working on. A pi agent looking at `CLAUDE_PROJECT` is confusing for anyone reading shell scripts inside the container.

**Proposed fix:** Rename to `SANDBOX_PROJECT`, keep `CLAUDE_PROJECT` as a compat alias so any scripts that read it don't break:

```bash
-e "SANDBOX_PROJECT=${project_name}" \
-e "CLAUDE_PROJECT=${project_name}" \
```

Document the new name; mark the old one deprecated in the next release.

**Effort:** 15 minutes.

### 1.4. Legacy cleanup paths in `cmd_teardown` should sunset

**What:** Lines 562–565 and 585–588 of `agent-sandbox`:
```bash
# Legacy containers
local legacy=$(podman ps -a --filter "name=^claude-sandbox-" ...)
# ...
# Legacy image
if image_exists "claude-sandbox:latest"; then
    podman rmi "claude-sandbox:latest" 2>/dev/null
```

These handle the pre-multi-agent naming (when there was a single `claude-sandbox:latest` image and `claude-sandbox-<project>` containers). Anyone who's run `setup` since the multi-agent refactor doesn't have these.

**Why it matters:** Carrying compat code forever bloats the script and confuses readers. This is also untested (no audit covers legacy cleanup).

**Proposed fix:** For the public release, remove. New users never had the legacy. Internal users have already cleaned up (you'd notice if `teardown all` left stuff behind).

If keeping for one more release as a safety net, gate behind `--include-legacy` flag.

**Effort:** 5 minutes to delete; 30 minutes if adding the flag.

---

## Tier 2 — quality of life

### 2.1. Domain allowlists are duplicated across three heredocs

**What:** In `agent-sandbox`, each agent's `domains.txt` heredoc repeats the same "common" entries:

```
.github.com
.githubusercontent.com
pypi.org
files.pythonhosted.org
astral.sh
registry.npmjs.org
crates.io
static.crates.io
ports.ubuntu.com
archive.ubuntu.com
security.ubuntu.com
```

That's 11 lines × 3 agents = 33 lines of repetition. A change to add (say) `download.pytorch.org` requires three edits.

**Why it matters:** Maintenance overhead and drift risk. We've already had a near-incident: gemini's `domains.txt` was missing `.anthropic.com` (correct — gemini doesn't need it) but easy to imagine someone copy-pasting and forgetting which entries are common.

**Proposed fix:** Factor common entries into a `COMMON_DOMAINS` block in `sandbox-lib.sh` or at the top of `agent-sandbox`. Each per-agent heredoc concatenates `"$COMMON_DOMAINS"` plus the agent-specific additions:

```bash
COMMON_DOMAINS=$(cat <<'EOF'
# Git
.github.com
.githubusercontent.com
# Python packages
pypi.org
files.pythonhosted.org
# Astral (uv, ruff)
astral.sh
# npm
registry.npmjs.org
# Rust
crates.io
static.crates.io
# apt
ports.ubuntu.com
archive.ubuntu.com
security.ubuntu.com
EOF
)

# Then per-agent:
cat > "${BUILD_DIR}/claude/domains.txt" << DOMAINS
# Claude API + auth
.anthropic.com
.claude.ai
platform.claude.com
${COMMON_DOMAINS}
DOMAINS
```

Note: variable expansion in `cat << EOF` (no quotes around EOF) substitutes `${COMMON_DOMAINS}`. The current heredocs use `'DOMAINS'` (quoted) which suppresses substitution; needs adjustment.

**Effort:** 30 minutes including testing all three agents.

### 2.2. No project-local domain extension mechanism

**What:** A user working on a project that needs a non-allowlisted domain (e.g. an internal package mirror, an unusual CDN) has to either:
1. Edit `agent-sandbox`'s heredoc and rerun `setup` (rebuilds the image).
2. Use `--network=open` (way more permissive than they need).

**Why it matters:** Real friction. The "right" thing to do — add the one domain — is the most expensive option.

**Proposed fix (sketch):** Look for `.agent-sandbox/domains.txt` in the project directory at run-time. If present, append it to `/etc/squid/domains.txt` inside the container during entrypoint, before squid starts. Keep the file root-owned via a copy step in the entrypoint (it must run before privilege drop).

Caveats: this lets the project add to the allowlist. If the project is untrusted, that's a security regression. Mitigation: only honor `.agent-sandbox/domains.txt` if it's owned by the user (not the agent) and exists at the project root, not in subdirectories.

**Effort:** A day, including writing the security model documentation. Skip until a real user asks for it.

### 2.3. `cmd_status` doesn't show network mode of running containers

**What:** Status output is currently:
```
[  ok  ]   sandbox-claude-myproj (running, 2 minutes ago)
```
No indication of which network mode the container was started in.

**Why it matters:** Once you have multiple sandboxes running, knowing "which one was --network=open" matters. Currently you'd have to `podman inspect` each to find out.

**Proposed fix:** Modify the listing in `cmd_status` to include the network mode by reading `SANDBOX_NETWORK` from env:

```bash
local mode=$(podman inspect "$name" --format '{{range .Config.Env}}{{println .}}{{end}}' \
             | grep '^SANDBOX_NETWORK=' | cut -d= -f2)
echo "  $name (mode: ${mode:-unknown}, $state, $created)"
```

**Effort:** 15 minutes.

### 2.4. `cmd_update` doesn't prune dangling images

**What:** `cmd_update <agent>` rebuilds an image with `--no-cache`. The previous image with the same tag becomes dangling (unnamed). Over time these accumulate.

**Why it matters:** Disk usage. Each agent image is ~300 MB. After 5 updates without pruning, that's 1.5 GB of dangling images.

**Proposed fix:** After a successful rebuild, `podman image prune -f --filter "dangling=true"`. Or print a hint at the end of `cmd_update` telling the user to run it themselves.

**Effort:** 10 minutes.

### 2.5. Squid health-check timeout is silent on failure

**What:** Each entrypoint waits up to 6 seconds for squid to become reachable:
```bash
for _ in $(seq 1 30); do
    if curl -sf -o /dev/null --proxy http://127.0.0.1:3128 http://ports.ubuntu.com; then
        break
    fi
    sleep 0.2
done
```
If squid never starts, the loop just exits. The container continues. The agent will get connection errors when it tries to make HTTP requests.

**Why it matters:** Diagnostically: "why can't claude reach api.anthropic.com?" → "squid never started" → no obvious sign of this from container output.

**Proposed fix:** Track whether the loop succeeded. If it didn't, print a warning to stderr:

```bash
SQUID_READY=0
for _ in $(seq 1 30); do
    if curl -sf -o /dev/null --proxy http://127.0.0.1:3128 http://ports.ubuntu.com 2>/dev/null; then
        SQUID_READY=1
        break
    fi
    sleep 0.2
done
[ "$SQUID_READY" -eq 0 ] && echo "[entrypoint] WARNING: squid did not become reachable in 6s — network access may be broken" >&2
```

**Effort:** 5 minutes per entrypoint × 3 = 15 minutes. Or 5 minutes total if 1.1 (consolidate via `write_entrypoint`) lands first.

### 2.6. `set -uo pipefail` without `-e` means many error paths exit silently

**What:** Top of `agent-sandbox` has `set -uo pipefail`. No `-e`. Functions like `agent_get` return 1 on error but callers don't check. Failures get swallowed.

**Why it matters:** Real example: if `agent_get pi xyz` is called with a typo'd field name, the function `err`s and returns 1. The caller's `var="$(agent_get pi xyz)"` ends up with `var=""`. Subsequent code uses `$var` as if it's valid.

**Proposed fix:** This is intentional per the lessons-learned doc (`set -e` plus `((var++))` was a footgun). But the trade-off can be improved:
- Use `set -eo pipefail` (no `-u`, since some callers depend on unset vars defaulting).
- Replace `((var++))` with `var=$((var+1))` (already done in the audit scripts).
- Audit every place that calls `agent_get` or similar to make sure failures are caught.

This is invasive. Worth doing once; not worth doing piecemeal.

**Effort:** A day for a careful pass through both files.

---

## Tier 3 — nice to have

### 3.1. No version pinning for agents

**What:** Each agent installs `<package>@latest`. A breaking change in any of the upstream packages immediately breaks the next `setup` or `update`.

**Why it matters:** Reproducibility. If you build the image today and again next month, you may get different agent versions.

**Proposed fix:** Add a `version` field to each agent profile. Default is `latest`; users can override:
```bash
claude::version) echo "${CLAUDE_VERSION:-latest}" ;;
```
Then the Dockerfile heredoc reads `@${VERSION}` instead of `@latest`. Pin from the host with `CLAUDE_VERSION=1.2.3 ./agent-sandbox setup`.

**Effort:** Couple of hours. Modest payoff unless someone is hit by a breakage.

### 3.2. Hardcoded image names limit multi-tenancy

**What:** `IMAGE_BASE="agent-sandbox-base"` etc. are hardcoded constants.

**Why it matters:** Two users on the same machine sharing a Podman daemon would step on each other's images. Unusual for desktop use; could matter on a shared server.

**Proposed fix:** Allow override via env var: `AGENT_SANDBOX_PREFIX="${AGENT_SANDBOX_PREFIX:-agent-sandbox}"`. Same for the image base.

**Effort:** 30 minutes. Low priority for the typical use case.

### 3.3. No tests

**What:** The "tests" we have are validation scripts (`audit.sh`, `audit-matrix.sh`) that depend on a working podman setup and run images. There are no unit tests for the bash functions (`sanitize_name`, `container_name_for`, etc.).

**Why it matters:** Refactoring is scarier than it should be. Validation scripts (like `audit.sh` here) are a step in this direction but they require a working podman setup and run images.

**Proposed fix:** A `tests/unit.sh` that exercises the pure functions without needing podman:

```bash
test_sanitize_name() {
    [ "$(sanitize_name 'My Project')" = "my-project" ] || fail
    [ "$(sanitize_name 'Foo.v2')"     = "foo-v2" ]     || fail
    [ "$(sanitize_name 'UPPER_case')" = "upper-case" ] || fail
}
```

Add to a `tests/` directory; document running them in the README.

**Effort:** A day for full coverage. Half-day for the common functions. High value if you're going to keep iterating on the script.

### 3.4. Linux native podman support

**What:** `require_podman` in `sandbox-lib.sh` checks `podman machine info` to verify the machine is running. On macOS that's correct (podman runs in a Linux VM). On Linux, podman runs natively without a machine, so this check fails on every Linux invocation even though podman is fine.

**Why it matters:** Currently the tool is macOS-only by enforcement. The README acknowledges this ("Linux works partially"), but the gap is small — a one-line OS detection — and would unlock Linux users without much risk.

**Proposed fix:** Detect platform:
```bash
require_podman() {
    if ! command -v podman &>/dev/null; then
        err "podman not found. Install with: brew install podman (macOS) or your package manager (Linux)"
        exit 1
    fi
    if [ "$(uname)" = "Darwin" ] && ! podman machine info &>/dev/null 2>&1; then
        err "Podman machine not running. Start with: podman machine start"
        exit 1
    fi
}
```

**Effort:** 15 minutes plus testing on a Linux box.

---

## Suggested ordering

If you tackle this work in releases:

**v1.1 (next patch):** 1.2 (image_exists arg validation), 1.3 (env var rename), 2.3 (status shows mode), 2.5 (squid health check warning). All small, all visible improvements. ~1 hour.

**v1.2 (refactor release):** 1.1 (consolidate via write_entrypoint), 2.1 (factor common domains), 2.4 (prune on update), 3.4 (Linux support). The biggest payoff in code clarity. ~1 day.

**v1.3 (or never):** 1.4 (drop legacy), 2.2 (project-local domains), 2.6 (set -e refactor), 3.1–3.3 (versioning, multi-tenancy, tests). Larger scope, lower urgency. Pick based on what users ask for.

The Tier 1 items (1.1–1.4) don't *have* to land before public release — the tool works as-is — but they reduce the cost of every future change. If you can spare a half-day before publishing, doing 1.1 alone would be a meaningful quality win.
