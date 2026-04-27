#!/usr/bin/env bats
#
# Unit tests for bootstrap.bash. We source the script with TEST_MODE set so
# main() does not run, then exercise individual functions against a
# per-test HOME sandbox.

setup() {
    export TEST_HOME="$(mktemp -d)"
    export HOME="$TEST_HOME"
    export REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    # Unset env vars the script looks at so each test controls its own.
    unset AAB_CLAUDE_CODE_MODEL AAB_CLAUDE_CODE_INFERENCE_PROVIDER \
          AAB_CLAUDE_CODE_MODEL_THIRD_PARTY_PREFIX \
          ANTHROPIC_API_KEY ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN \
          GH_TOKEN GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL \
          AAB_CLAUDE_CODE_PLUGINS_FILE AAB_CLAUDE_CODE_PLUGINS_URL
    # shellcheck disable=SC1091
    source "$REPO_ROOT/bootstrap.bash"
}

teardown() {
    rm -rf "$TEST_HOME"
}

@test "log writes to stdout with bootstrap prefix" {
    run log "hello"
    [ "$status" -eq 0 ]
    [ "$output" = "[bootstrap] hello" ]
}

@test "warn writes to stderr with WARN prefix" {
    run warn "bad"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[bootstrap] WARN: bad"* ]]
}

@test "need_sudo returns empty string for uid 0, 'sudo' otherwise" {
    result=$(need_sudo)
    if [ "$(id -u)" -eq 0 ]; then
        [ "$result" = "" ]
    else
        [ "$result" = "sudo" ]
    fi
}

@test "skip_brev_onboarding writes valid JSON to BREV_ONBOARDING" {
    skip_brev_onboarding
    [ -f "$BREV_ONBOARDING" ]
    python3 -c "import json; json.load(open('$BREV_ONBOARDING'))"
    grep -q '"hasRunBrevShell": true' "$BREV_ONBOARDING"
}

@test "skip_brev_onboarding backs up pre-existing onboarding file" {
    mkdir -p "$BREV_DIR"
    echo '{"old": true}' > "$BREV_ONBOARDING"
    skip_brev_onboarding
    local backup_count
    backup_count=$(find "$BREV_DIR" -maxdepth 1 -name 'onboarding_step.json.bak.*' | wc -l)
    [ "$backup_count" -ge 1 ]
}

@test "write_settings uses default model when AAB_CLAUDE_CODE_MODEL unset" {
    write_settings
    [ -f "$SETTINGS_FILE" ]
    python3 -c "import json; d=json.load(open('$SETTINGS_FILE')); assert d['model']=='$DEFAULT_CLAUDE_CODE_MODEL', d['model']"
}

@test "write_settings honors AAB_CLAUDE_CODE_MODEL override" {
    AAB_CLAUDE_CODE_MODEL="claude-sonnet-4-6" write_settings
    python3 -c "import json; d=json.load(open('$SETTINGS_FILE')); assert d['model']=='claude-sonnet-4-6', d['model']"
}

@test "write_settings sets bypassPermissions and sandbox env" {
    write_settings
    python3 - <<PY
import json
d = json.load(open("$SETTINGS_FILE"))
assert d["permissions"]["defaultMode"] == "bypassPermissions"
assert d["skipDangerousModePermissionPrompt"] is True
assert d["env"]["CLAUDE_CODE_SANDBOXED"] == "1"
assert d["effortLevel"] == "max"
PY
}

@test "write_settings backs up pre-existing settings.json" {
    mkdir -p "$CLAUDE_DIR"
    echo '{"model": "old"}' > "$SETTINGS_FILE"
    write_settings
    local backup_count
    backup_count=$(find "$CLAUDE_DIR" -maxdepth 1 -name 'settings.json.bak.*' | wc -l)
    [ "$backup_count" -ge 1 ]
}

@test "skip_onboarding creates .claude.json with hasCompletedOnboarding=true" {
    skip_onboarding
    [ -f "$CLAUDE_JSON" ]
    python3 -c "import json; d=json.load(open('$CLAUDE_JSON')); assert d['hasCompletedOnboarding'] is True"
}

@test "skip_onboarding pre-approves ANTHROPIC_API_KEY fingerprint when set" {
    ANTHROPIC_API_KEY="sk-ant-test-0123456789abcdef0123456789abcdef" skip_onboarding
    python3 - <<PY
import json
d = json.load(open("$CLAUDE_JSON"))
approved = d["customApiKeyResponses"]["approved"]
# Fingerprint is the last 20 chars of the key.
assert "f0123456789abcdef" in approved[0], approved
PY
}

@test "skip_onboarding preserves existing fields in .claude.json" {
    mkdir -p "$(dirname "$CLAUDE_JSON")"
    cat > "$CLAUDE_JSON" <<JSON
{"userID": "u-123", "hasCompletedOnboarding": false}
JSON
    skip_onboarding
    python3 - <<PY
import json
d = json.load(open("$CLAUDE_JSON"))
assert d["userID"] == "u-123"
assert d["hasCompletedOnboarding"] is True
PY
}

@test "skip_onboarding is idempotent (second call does not duplicate fingerprint)" {
    ANTHROPIC_API_KEY="sk-ant-test-0123456789abcdef0123456789abcdef" skip_onboarding
    ANTHROPIC_API_KEY="sk-ant-test-0123456789abcdef0123456789abcdef" skip_onboarding
    python3 - <<PY
import json
d = json.load(open("$CLAUDE_JSON"))
approved = d["customApiKeyResponses"]["approved"]
assert len(approved) == 1, approved
PY
}

@test "update_bashrc writes managed block with both markers" {
    update_bashrc
    [ -f "$BASHRC" ]
    grep -q "$BASHRC_MARKER_BEGIN" "$BASHRC"
    grep -q "$BASHRC_MARKER_END" "$BASHRC"
}

@test "update_bashrc is idempotent (single managed block after two runs)" {
    update_bashrc
    update_bashrc
    local begin_count end_count
    begin_count=$(grep -c "^${BASHRC_MARKER_BEGIN}$" "$BASHRC")
    end_count=$(grep -c "^${BASHRC_MARKER_END}$" "$BASHRC")
    [ "$begin_count" -eq 1 ]
    [ "$end_count" -eq 1 ]
}

@test "update_bashrc honors third-party provider selection" {
    AAB_CLAUDE_CODE_INFERENCE_PROVIDER="third-party" update_bashrc
    grep -q 'AAB_CLAUDE_CODE_INFERENCE_PROVIDER="third-party"' "$BASHRC"
}

@test "sourcing bootstrap.bash does NOT execute main" {
    # setup() already sourced the script. If main had run, it would have
    # attempted to install Claude Code via curl; instead the function is
    # merely defined.
    type main >/dev/null
    # And no settings file should exist yet — write_settings was never
    # called by a main() invocation at source time.
    [ ! -f "$SETTINGS_FILE" ]
}
