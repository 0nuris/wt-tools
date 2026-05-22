#!/usr/bin/env bats
# Tests for bin/wt-validate-bash — the deterministic enforcer.
#
# The validator reads stdin JSON with the same schema Claude Code's PreToolUse
# hook sends. We feed it crafted JSON and assert the output.

setup() {
    VALIDATOR="$BATS_TEST_DIRNAME/../bin/wt-validate-bash"
}

# Helper: build the JSON payload Claude Code's PreToolUse hook delivers,
# parameterized on the command string.
mk_input() {
    jq -n --arg cmd "$1" '{
        session_id: "test",
        hook_event_name: "PreToolUse",
        tool_name: "Bash",
        tool_input: {command: $cmd}
    }'
}

# Helper: run validator with rule + command. Capture stdout + exit code.
run_validator() {
    local rule="$1"; shift
    local cmd="$1"
    run bash -c "$(printf 'echo %q | bash %q %q' "$(mk_input "$cmd")" "$VALIDATOR" "$rule")"
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

# ---- threat-model notes (no asserts; documentation of how evasion actually works) ----
#
# The validator alone is conservative: when invoked with the draft-prs rule on
# *any* command lacking a --draft token, it denies. The real evasion path is
# the hook's `if` filter (in settings.fragment.json), which uses permission-rule
# syntax like `Bash(gh pr create*)`. Commands wrapped in `bash -c "..."`, fed
# via heredocs, or built by string concatenation do not match that pattern, so
# the validator never runs for them.
#
# That layered design is intentional: the `if` filter handles "is this
# command in scope?"; the validator handles "given it is in scope, does it
# satisfy the rule?" Testing the if-filter requires invoking through Claude
# Code itself, which is out of scope for unit tests.
