#!/usr/bin/env bats
# Tests for bin/wt-validate-bash — the deterministic enforcer.
#
# The validator reads stdin JSON with the same schema Claude Code's PreToolUse
# hook sends. We feed it crafted JSON and assert the output.

setup() {
    VALIDATOR="$BATS_TEST_DIRNAME/../bin/wt-validate-bash"
    # Most tests exercise rule logic in isolation. WT_ENFORCE_SCOPE=all skips
    # the worktree-only scope check so the rule logic itself can be asserted
    # without fixture worktrees. Dedicated scope tests below clear this.
    export WT_ENFORCE_SCOPE=all
}

# Helper: build the JSON payload Claude Code's PreToolUse hook delivers,
# parameterized on the command string and (optional) cwd.
mk_input() {
    local cmd="$1" cwd="${2:-}"
    jq -n --arg cmd "$cmd" --arg cwd "$cwd" '{
        session_id: "test",
        hook_event_name: "PreToolUse",
        tool_name: "Bash",
        cwd: $cwd,
        tool_input: {command: $cmd}
    }'
}

# Helper: run validator with rule + command. Capture stdout + exit code.
run_validator() {
    local rule="$1"; shift
    local cmd="$1"
    run bash -c "$(printf 'echo %q | bash %q %q' "$(mk_input "$cmd")" "$VALIDATOR" "$rule")"
}

# Helper: run validator with rule + command + cwd, respecting WT_ENFORCE_SCOPE
# (the test should set it).
run_validator_cwd() {
    local rule="$1" cmd="$2" cwd="$3"
    run bash -c "$(printf 'echo %q | bash %q %q' "$(mk_input "$cmd" "$cwd")" "$VALIDATOR" "$rule")"
}

# ---- draft-prs rule ------------------------------------------------------

@test "draft-prs: blocks gh pr create without --draft" {
    run_validator draft-prs "gh pr create --title X --body Y"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    [[ "$output" == *"draft"* ]]
}

@test "draft-prs: allows gh pr create with --draft" {
    run_validator draft-prs "gh pr create --draft --title X --body Y"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "draft-prs: allows gh pr create with --draft in non-first position" {
    run_validator draft-prs "gh pr create --title X --draft --body Y"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "draft-prs: bypass with WT_ALLOW_NONDRAFT=1 prefix" {
    run_validator draft-prs "WT_ALLOW_NONDRAFT=1 gh pr create --title X"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "draft-prs: bypass with WT_ALLOW_NONDRAFT=true prefix" {
    run_validator draft-prs "WT_ALLOW_NONDRAFT=true gh pr create --title X"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---- no-pr-ready rule ----------------------------------------------------

@test "no-pr-ready: blocks gh pr ready" {
    run_validator no-pr-ready "gh pr ready 123"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "no-pr-ready: no bypass available" {
    run_validator no-pr-ready "WT_ALLOW_NONDRAFT=1 WT_ALLOW_FORCE=1 gh pr ready 123"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
    [[ "$output" == *"No bypass available"* ]]
}

# ---- no-pr-merge rule ----------------------------------------------------

@test "no-pr-merge: blocks gh pr merge" {
    run_validator no-pr-merge "gh pr merge 123 --squash"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "no-pr-merge: bypass with WT_ALLOW_MERGE=1" {
    run_validator no-pr-merge "WT_ALLOW_MERGE=1 gh pr merge 123 --squash"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---- no-force-remove rule ------------------------------------------------

@test "no-force-remove: blocks --force" {
    run_validator no-force-remove "git worktree remove --force .worktrees/foo"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "no-force-remove: allows non-force" {
    run_validator no-force-remove "git worktree remove .worktrees/foo"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "no-force-remove: bypass with WT_ALLOW_FORCE=1" {
    run_validator no-force-remove "WT_ALLOW_FORCE=1 git worktree remove --force .worktrees/foo"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---- defer cases ---------------------------------------------------------

@test "unknown rule: defers (exit 0, no output)" {
    run_validator unknown-rule "gh pr create"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "empty command: defers" {
    input="$(jq -n '{tool_input: {command: ""}}')"
    run bash -c "echo $(printf '%q' "$input") | bash $(printf '%q' "$VALIDATOR") draft-prs"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---- sanity: defer when the rule's target command is not in the input ----

@test "sanity: draft-prs defers on a command without 'gh pr create' tokens" {
    # If Claude Code's if-filter ever spuriously routes a non-matching command
    # here, the validator should defer cleanly instead of denying everything
    # that lacks --draft.
    run_validator draft-prs "echo done; git -C /tmp diff --stat"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "sanity: no-pr-ready defers on a command without 'gh pr ready' tokens" {
    run_validator no-pr-ready "echo gh pr something-else"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "sanity: no-pr-merge defers on unrelated command" {
    run_validator no-pr-merge "git log --oneline"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "sanity: no-force-remove defers on unrelated command" {
    run_validator no-force-remove "rm -rf /tmp/foo"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "sanity: draft-prs enforces when 'gh pr create' appears in compound" {
    # Compound command where the gh pr create subcommand DOES need a --draft.
    run_validator draft-prs "echo before; gh pr create --title X --body Y; echo after"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"deny"'* ]]
}

# ---- scope: worktree-only enforcement ------------------------------------

@test "scope: defers in a main checkout (default scope=worktree)" {
    unset WT_ENFORCE_SCOPE
    # Build a temp main checkout
    local tmpdir
    tmpdir="$(mktemp -d)"
    git -C "$tmpdir" init -q
    run_validator_cwd draft-prs "gh pr create --title X" "$tmpdir"
    rm -rf "$tmpdir"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "scope: defers in a non-git directory" {
    unset WT_ENFORCE_SCOPE
    local tmpdir
    tmpdir="$(mktemp -d)"
    run_validator_cwd draft-prs "gh pr create --title X" "$tmpdir"
    rm -rf "$tmpdir"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "scope: defers when cwd is empty" {
    unset WT_ENFORCE_SCOPE
    run_validator_cwd draft-prs "gh pr create --title X" ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "scope: enforces inside a linked worktree" {
    unset WT_ENFORCE_SCOPE
    local tmpdir wt
    tmpdir="$(mktemp -d)"
    git -C "$tmpdir" init -q -b main
    git -C "$tmpdir" commit -q --allow-empty -m init
    wt="$tmpdir/.worktrees/foo"
    git -C "$tmpdir" worktree add -q "$wt" -b foo
    run_validator_cwd draft-prs "gh pr create --title X" "$wt"
    git -C "$tmpdir" worktree remove "$wt" 2>/dev/null || true
    rm -rf "$tmpdir"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"deny"'* ]]
}

# ---- inspect-wrapped rule (catches bash -c / sh -c wrapped commands) ----

@test "inspect-wrapped: blocks bash -c \"gh pr create ...\"" {
    run_validator inspect-wrapped 'bash -c "gh pr create --title X --body Y"'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"deny"'* ]]
    [[ "$output" == *"draft"* ]]
}

@test "inspect-wrapped: blocks sh -c \"gh pr create ...\"" {
    run_validator inspect-wrapped 'sh -c "gh pr create --title X --body Y"'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"deny"'* ]]
}

@test "inspect-wrapped: allows bash -c \"gh pr create --draft ...\"" {
    run_validator inspect-wrapped 'bash -c "gh pr create --draft --title X --body Y"'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "inspect-wrapped: blocks single-quoted bash -c 'gh pr create ...'" {
    run_validator inspect-wrapped "bash -c 'gh pr create --title X --body Y'"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"deny"'* ]]
}

@test "inspect-wrapped: blocks bash -lc \"gh pr create ...\" (flag cluster)" {
    run_validator inspect-wrapped 'bash -lc "gh pr create --title X --body Y"'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"deny"'* ]]
}

@test "inspect-wrapped: blocks bash -c \"gh pr ready 1\"" {
    run_validator inspect-wrapped 'bash -c "gh pr ready 1"'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"deny"'* ]]
    [[ "$output" == *"gh pr ready"* ]]
}

@test "inspect-wrapped: blocks bash -c \"gh pr merge 1 --squash\"" {
    run_validator inspect-wrapped 'bash -c "gh pr merge 1 --squash"'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"deny"'* ]]
    [[ "$output" == *"gh pr merge"* ]]
}

@test "inspect-wrapped: blocks bash -c \"git worktree remove --force /tmp/x\"" {
    run_validator inspect-wrapped 'bash -c "git worktree remove --force /tmp/x"'
    [ "$status" -eq 0 ]
    [[ "$output" == *'"deny"'* ]]
    [[ "$output" == *"--force"* ]]
}

@test "inspect-wrapped: allows bash -c \"git worktree remove /tmp/x\" (no --force)" {
    run_validator inspect-wrapped 'bash -c "git worktree remove /tmp/x"'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "inspect-wrapped: honors WT_ALLOW_NONDRAFT=1 prefix" {
    run_validator inspect-wrapped 'WT_ALLOW_NONDRAFT=1 bash -c "gh pr create --title X --body Y"'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "inspect-wrapped: honors WT_ALLOW_MERGE=1 prefix" {
    run_validator inspect-wrapped 'WT_ALLOW_MERGE=1 bash -c "gh pr merge 1 --squash"'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "inspect-wrapped: honors WT_ALLOW_FORCE=1 prefix" {
    run_validator inspect-wrapped 'WT_ALLOW_FORCE=1 bash -c "git worktree remove --force /tmp/x"'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "inspect-wrapped: defers when wrapped command has no rule match" {
    run_validator inspect-wrapped 'bash -c "echo hello world"'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "inspect-wrapped: defers when bash has no -c flag" {
    run_validator inspect-wrapped 'bash script.sh'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "inspect-wrapped: defers when outer command is not bash/sh" {
    run_validator inspect-wrapped 'python -c "import os; os.system(\"gh pr create\")"'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "inspect-wrapped: scope check defers in main checkout (default scope)" {
    unset WT_ENFORCE_SCOPE
    local tmpdir
    tmpdir="$(mktemp -d)"
    git -C "$tmpdir" init -q -b main
    git -C "$tmpdir" commit -q --allow-empty -m init
    run_validator_cwd inspect-wrapped 'bash -c "gh pr create --title X"' "$tmpdir"
    rm -rf "$tmpdir"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "inspect-wrapped: scope check enforces inside a linked worktree" {
    unset WT_ENFORCE_SCOPE
    local tmpdir wt
    tmpdir="$(mktemp -d)"
    git -C "$tmpdir" init -q -b main
    git -C "$tmpdir" commit -q --allow-empty -m init
    wt="$tmpdir/.worktrees/foo"
    git -C "$tmpdir" worktree add -q "$wt" -b foo
    run_validator_cwd inspect-wrapped 'bash -c "gh pr create --title X"' "$wt"
    git -C "$tmpdir" worktree remove "$wt" 2>/dev/null || true
    rm -rf "$tmpdir"
    [ "$status" -eq 0 ]
    [[ "$output" == *'"deny"'* ]]
}

# ---- threat-model notes (no asserts; documentation of how evasion actually works) ----
#
# After commit landing the `inspect-wrapped` rule + `Bash(bash *)` / `Bash(sh *)`
# matchers, the validator catches `bash -c "..."` and `sh -c "..."` wrappers
# around the four blocked patterns. The `if` filter routes any bash/sh
# invocation through the inspect-wrapped path; the validator slices past the
# -c flag, strips outer quote chars from the tokenized args, and re-runs all
# four rule checks against the wrapped tokens.
#
# Still NOT caught (documented limitations):
#   - Heredocs: `bash <<EOF\ngh pr create\nEOF` — needs heredoc parsing
#   - String concatenation: `cmd="gh pr"; $cmd create` — requires variable expansion
#   - Aliases: `alias gpc='gh pr create'; gpc` — shell-runtime resolution
#   - Indirect script invocation: `./run.sh` calling `gh pr create` — needs file-execution sandbox
#   - Other interpreters: `python -c "..."`, `node -e "..."` — only bash/sh wrap shell commands
#
# That layered design is intentional: the `if` filter handles "is this
# command in scope?"; the validator handles "given it is in scope, does it
# satisfy the rule?" Testing the if-filter requires invoking through Claude
# Code itself, which is out of scope for unit tests.
