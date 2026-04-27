#!/usr/bin/env bash
# Run the project's tests. Mirrors the jobs in .github/workflows/ci.yml so
# "works locally" == "will pass CI".
#
# Usage:
#   ./test.bash              lint + unit (default; fast, no side effects)
#   ./test.bash --lint       bash -n + shellcheck
#   ./test.bash --unit       bats suite (tests/bootstrap.bats)
#   ./test.bash --e2e        runs bootstrap.bash on THIS host + assertions.
#                            Destructive: overwrites ~/.claude/settings.json,
#                            rewrites the ~/.bashrc managed block, modifies
#                            global git config, and installs claude / brev
#                            / gh. Only run on a disposable machine.
#   ./test.bash --secrets    gitleaks scan of full history + working tree
#   ./test.bash --all        everything above, in order
#   ./test.bash -h|--help    print this usage

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

need() {
    command -v "$1" >/dev/null 2>&1 \
        || { echo "test.bash: missing dependency: $1" >&2; return 1; }
}

run_lint() {
    echo "=== lint ==="
    need bash
    need shellcheck
    bash -n bootstrap.bash
    shellcheck -S warning bootstrap.bash tests/e2e-assertions.bash
}

run_unit() {
    echo "=== unit (bats) ==="
    need bats
    need python3
    bats tests/bootstrap.bats
}

run_e2e() {
    echo "=== e2e (runs bootstrap.bash on this host — DESTRUCTIVE) ==="
    need bash
    need python3
    need curl
    need git
    : "${GIT_AUTHOR_NAME:=CI Bot}"
    : "${GIT_AUTHOR_EMAIL:=ci@example.com}"
    : "${AAB_CLAUDE_CODE_MODEL:=claude-opus-4-7}"
    : "${AAB_CLAUDE_CODE_INFERENCE_PROVIDER:=anthropic}"
    export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL \
           AAB_CLAUDE_CODE_MODEL AAB_CLAUDE_CODE_INFERENCE_PROVIDER

    bash bootstrap.bash
    bash tests/e2e-assertions.bash

    # Re-run and re-assert to verify idempotency.
    bash bootstrap.bash
    bash tests/e2e-assertions.bash

    # Exercise the provider-switch function. The default Ubuntu ~/.bashrc
    # returns early for non-interactive shells, so extract just the
    # managed block and source that to get at the function.
    local block
    block=$(mktemp)
    awk '/^# >>> autonomous-agent-bootstrap >>>$/,/^# <<< autonomous-agent-bootstrap <<<$/' \
        "$HOME/.bashrc" > "$block"
    bash -c "
        set -euo pipefail
        # shellcheck disable=SC1090
        . '$block'
        claude_code_switch_inference_provider third-party
        grep -q 'AAB_CLAUDE_CODE_INFERENCE_PROVIDER=\"third-party\"' \"\$HOME/.bashrc\"
        claude_code_switch_inference_provider anthropic
        grep -q 'AAB_CLAUDE_CODE_INFERENCE_PROVIDER=\"anthropic\"' \"\$HOME/.bashrc\"
    "
    rm -f "$block"
    echo "=== e2e passed ==="
}

run_secrets() {
    echo "=== secret scan (gitleaks) ==="
    need gitleaks
    gitleaks detect --source . --redact --verbose --exit-code 1
    gitleaks detect --source . --no-git --redact --verbose --exit-code 1
}

usage() {
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

if [ $# -eq 0 ]; then
    run_lint
    run_unit
    exit 0
fi

for arg in "$@"; do
    case "$arg" in
        --lint)    run_lint ;;
        --unit)    run_unit ;;
        --e2e)     run_e2e ;;
        --secrets) run_secrets ;;
        --all)
            run_lint
            run_unit
            run_e2e
            run_secrets
            ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "test.bash: unknown arg: $arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done
