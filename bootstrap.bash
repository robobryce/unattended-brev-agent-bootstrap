#!/usr/bin/env bash
# Bootstrap a fresh, non-interactive Claude Code install.
#
# Does four things, idempotently:
#   1. Installs Claude Code (native installer) if not already present.
#   2. Writes ~/.claude/settings.json with unattended-mode defaults
#      (bypassPermissions, sandboxed, max effort, opus-4-7).
#   3. Pre-populates ~/.claude.json with hasCompletedOnboarding=true so the
#      first `claude` launch skips the theme / color-scheme wizard.
#   4. Appends PATH / alias / env exports to ~/.bashrc so interactive shells
#      pick up ~/.local/bin and run `claude` with --dangerously-skip-permissions.
#
# Can be run from a local checkout or piped via `curl ... | bash`.
# Safe to re-run. Existing settings.json and .claude.json are backed up before
# overwrite.

set -euo pipefail

CLAUDE_DIR="${HOME}/.claude"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"
CLAUDE_JSON="${HOME}/.claude.json"
BASHRC="${HOME}/.bashrc"
BASHRC_MARKER_BEGIN="# >>> unattended-claude-code bootstrap >>>"
BASHRC_MARKER_END="# <<< unattended-claude-code bootstrap <<<"

log() { printf '[bootstrap] %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Install Claude Code (native installer) if missing.
# ---------------------------------------------------------------------------
install_claude() {
    if command -v claude >/dev/null 2>&1; then
        log "claude already installed: $(command -v claude) ($(claude --version 2>&1 | head -1))"
        return
    fi
    if [[ -x "${HOME}/.local/bin/claude" ]]; then
        log "claude found at ~/.local/bin/claude but not on PATH yet; will be picked up after PATH update"
        return
    fi
    log "installing Claude Code via native installer..."
    curl -fsSL https://claude.ai/install.sh | bash
}

# ---------------------------------------------------------------------------
# 2. Write ~/.claude/settings.json.
# ---------------------------------------------------------------------------
write_settings() {
    mkdir -p "${CLAUDE_DIR}"
    if [[ -f "${SETTINGS_FILE}" ]]; then
        local backup="${SETTINGS_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
        cp "${SETTINGS_FILE}" "${backup}"
        log "backed up existing settings.json -> ${backup}"
    fi
    cat > "${SETTINGS_FILE}" <<'JSON'
{
  "model": "claude-opus-4-7",
  "effortLevel": "max",
  "permissions": {
    "defaultMode": "bypassPermissions"
  },
  "skipDangerousModePermissionPrompt": true,
  "env": {
    "CLAUDE_CODE_SANDBOXED": "1",
    "CLAUDE_CODE_EFFORT_LEVEL": "max"
  }
}
JSON
    log "wrote ${SETTINGS_FILE}"
}

# ---------------------------------------------------------------------------
# 3. Skip the first-run onboarding (theme / color-scheme prompt).
#
# The gate for the onboarding wizard is `hasCompletedOnboarding` in
# ~/.claude.json (NOT ~/.claude/settings.json). Setting it to true before the
# first `claude` launch makes it pick the default theme and proceed straight
# into the REPL. Preserve any pre-existing fields (auth tokens, userID, etc.)
# by merging instead of overwriting.
# ---------------------------------------------------------------------------
skip_onboarding() {
    command -v python3 >/dev/null 2>&1 || { log "ERROR: python3 required to edit ~/.claude.json"; exit 1; }
    python3 - "${CLAUDE_JSON}" <<'PY'
import json, os, shutil, sys, time
path = sys.argv[1]
data = {}
if os.path.exists(path):
    backup = f"{path}.bak.{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(path, backup)
    print(f"[bootstrap] backed up existing .claude.json -> {backup}")
    try:
        with open(path) as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError):
        data = {}
data["hasCompletedOnboarding"] = True
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2)
print(f"[bootstrap] set hasCompletedOnboarding=true in {path}")
PY
}

# ---------------------------------------------------------------------------
# 4. Append unattended-mode block to ~/.bashrc (idempotent via markers).
# ---------------------------------------------------------------------------
update_bashrc() {
    touch "${BASHRC}"
    if grep -qF "${BASHRC_MARKER_BEGIN}" "${BASHRC}"; then
        log "bashrc already has unattended-claude-code block; leaving it alone"
        return
    fi
    cat >> "${BASHRC}" <<EOF

${BASHRC_MARKER_BEGIN}
# Sources env file created by the Claude Code native installer, ensures
# ~/.local/bin is on PATH, and makes every interactive 'claude' invocation
# skip the permission prompt so the agent can run unattended.
if [ -f "\$HOME/.local/bin/env" ]; then
    . "\$HOME/.local/bin/env"
fi
export PATH="\$HOME/.local/bin:\$PATH"
export CLAUDE_CODE_SANDBOXED=1
alias claude='claude --dangerously-skip-permissions'
${BASHRC_MARKER_END}
EOF
    log "appended unattended-mode block to ${BASHRC}"
}

main() {
    install_claude
    write_settings
    skip_onboarding
    update_bashrc
    log "done. Open a new shell (or 'source ~/.bashrc') so the PATH / alias take effect."
}

main "$@"
