#!/usr/bin/env bats
# Tests for bin/wt-audit using temp fixture repos.

load fixtures/setup

setup() {
    wt_setup_fixture
}

# ---- empty / minimal cases ----------------------------------------------

@test "audit: empty WT_ROOT prints no-worktrees message" {
    run wt_audit_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"no linked worktrees found"* ]]
}

@test "audit: repo with no linked worktrees produces empty table" {
    wt_make_repo solo
    run wt_audit_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"no linked worktrees found"* ]]
}

@test "audit: --json on empty WT_ROOT returns []" {
    run wt_audit_run --json
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

# ---- single linked worktree ---------------------------------------------

@test "audit: one repo with one linked worktree shows 1 row" {
    wt_make_repo alpha
    wt_make_worktree alpha feature
    run wt_audit_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"alpha"* ]]
    [[ "$output" == *"feature"* ]]
}

@test "audit: --json returns valid JSON array with expected fields" {
    wt_make_repo alpha
    wt_make_worktree alpha feature
    run wt_audit_run --json
    [ "$status" -eq 0 ]
    echo "$output" | jq -e 'type == "array" and length == 1' >/dev/null
    echo "$output" | jq -e '.[0] | has("repo") and has("path") and has("branch") and has("merged") and has("upstream_gone") and has("dirty") and has("sibling_dir") and has("detached") and has("removable")' >/dev/null
}

@test "audit: branch field matches the created branch name" {
    wt_make_repo alpha
    wt_make_worktree alpha myfeature
    run wt_audit_run --json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.[0].branch')" = "myfeature" ]
}

# ---- dirty detection ----------------------------------------------------

@test "audit: dirty=yes when worktree has uncommitted changes" {
    wt_make_repo alpha
    wt_make_worktree alpha feature
    echo modified > "$WT_LAST_WT_PATH/newfile.txt"
    run wt_audit_run --json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.[0].dirty')" = "yes" ]
}

@test "audit: dirty=no when worktree is clean" {
    wt_make_repo alpha
    wt_make_worktree alpha feature
    run wt_audit_run --json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.[0].dirty')" = "no" ]
}

# ---- sibling-dir detection ----------------------------------------------

@test "audit: sibling_dir=yes when worktree is outside .worktrees/" {
    wt_make_repo alpha
    wt_make_worktree alpha feature "$WT_ROOT/alpha-sibling"
    run wt_audit_run --json
    [ "$status" -eq 0 ]
    # Find the entry for the sibling-dir worktree (path contains alpha-sibling).
    [ "$(echo "$output" | jq -r '.[] | select(.path | contains("alpha-sibling")) | .sibling_dir')" = "yes" ]
}

# ---- detached HEAD ------------------------------------------------------

@test "audit: detached=yes for detached-HEAD worktree" {
    wt_make_repo alpha
    local repo="$WT_ROOT/alpha"
    git -C "$repo" worktree add -q --detach "$repo/.worktrees/detached"
    run wt_audit_run --json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.[0].detached')" = "yes" ]
}

# ---- filtering ----------------------------------------------------------

@test "audit: --repo NAME restricts output to that repo" {
    wt_make_repo alpha
    wt_make_repo beta
    wt_make_worktree alpha a-feature
    wt_make_worktree beta b-feature
    run wt_audit_run --json --repo beta
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq 'length')" = "1" ]
    [ "$(echo "$output" | jq -r '.[0].repo')" = "beta" ]
}

@test "audit: WT_IGNORE_REPOS skips listed repos" {
    wt_make_repo alpha
    wt_make_repo beta
    wt_make_worktree alpha a-feature
    wt_make_worktree beta b-feature
    WT_IGNORE_REPOS="beta" run wt_audit_run --json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq 'length')" = "1" ]
    [ "$(echo "$output" | jq -r '.[0].repo')" = "alpha" ]
}

# ---- removable filter ---------------------------------------------------

@test "audit: --filter removable returns only stale/merged/upstream-gone rows" {
    wt_make_repo alpha
    wt_make_worktree alpha feature
    # Fresh worktree is not stale (default stale-days=30), not merged, not gone.
    run wt_audit_run --json --filter removable
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq 'length')" = "0" ]
}

@test "audit: --stale-days 0 marks fresh worktrees as stale (and removable)" {
    wt_make_repo alpha
    wt_make_worktree alpha feature
    run wt_audit_run --json --stale-days 0
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.[0].stale')" = "yes" ]
    [ "$(echo "$output" | jq -r '.[0].removable')" = "yes" ]
}

# ---- summary footer -----------------------------------------------------

@test "audit: table mode prints summary footer" {
    wt_make_repo alpha
    wt_make_worktree alpha feature
    run wt_audit_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 worktrees total"* ]]
    [[ "$output" == *"removable"* ]]
}

@test "audit: --json mode does NOT print summary footer" {
    wt_make_repo alpha
    wt_make_worktree alpha feature
    run wt_audit_run --json
    [ "$status" -eq 0 ]
    [[ "$output" != *"worktrees total"* ]]
    # Output must still be valid JSON
    echo "$output" | jq -e '.' >/dev/null
}

@test "audit: --filter removable mode does NOT print summary footer (the list IS the candidates)" {
    wt_make_repo alpha
    wt_make_worktree alpha feature
    run wt_audit_run --filter removable
    [ "$status" -eq 0 ]
    [[ "$output" != *"worktrees total"* ]]
}

# ---- per-repo config layering -------------------------------------------

@test "audit: per-repo .wt-tools.conf overrides stale-days for that repo only" {
    wt_make_repo alpha
    wt_make_repo beta
    wt_make_worktree alpha feature
    wt_make_worktree beta feature
    # alpha has a per-repo conf forcing stale-days to 0.
    echo 'WT_STALE_DAYS_AUDIT=0' > "$WT_ROOT/alpha/.wt-tools.conf"
    run wt_audit_run --json
    [ "$status" -eq 0 ]
    # alpha's worktree should be stale (per-repo override = 0)
    [ "$(echo "$output" | jq -r '.[] | select(.repo == "alpha") | .stale')" = "yes" ]
    # beta's worktree should NOT be stale (global default = 30)
    [ "$(echo "$output" | jq -r '.[] | select(.repo == "beta") | .stale')" = "no" ]
}

@test "audit: .wt-tools.local.conf overrides .wt-tools.conf for the same repo" {
    wt_make_repo alpha
    wt_make_worktree alpha feature
    # Shared conf says stale-days=999 (never stale).
    echo 'WT_STALE_DAYS_AUDIT=999' > "$WT_ROOT/alpha/.wt-tools.conf"
    # Local override says stale-days=0 (always stale). Local wins.
    echo 'WT_STALE_DAYS_AUDIT=0' > "$WT_ROOT/alpha/.wt-tools.local.conf"
    run wt_audit_run --json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.[0].stale')" = "yes" ]
}
