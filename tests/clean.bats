#!/usr/bin/env bats
# Tests for bin/wt-clean using temp fixture repos.

load fixtures/setup

setup() {
    wt_setup_fixture
}

# ---- dry-run / no candidates --------------------------------------------

@test "clean: no candidates prints message and exits 0" {
    wt_make_repo alpha
    wt_make_worktree alpha feature
    # Fresh worktree, no stale, not merged, not gone — not removable.
    run wt_clean_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"no candidate worktrees"* ]]
}

@test "clean: dry-run with --stale-days 0 lists candidate but does not remove" {
    wt_make_repo alpha
    wt_make_worktree alpha feature
    local wt_path="$WT_LAST_WT_PATH"
    run wt_clean_run --include-detached --include-sibling-dirs --stale-days 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"dry-run"* ]]
    [[ "$output" == *"feature"* ]]
    [ -d "$wt_path" ]   # not removed
}

# ---- --apply removes ----------------------------------------------------

@test "clean: --apply --stale-days 0 actually removes the worktree" {
    wt_make_repo alpha
    wt_make_worktree alpha feature
    local wt_path="$WT_LAST_WT_PATH"
    run wt_clean_run --apply --stale-days 0
    [ "$status" -eq 0 ]
    [ ! -d "$wt_path" ]
    [[ "$output" == *"removed"* ]]
}

# ---- safety: skip detached unless --include-detached --------------------

@test "clean: detached worktrees skipped by default (no candidates)" {
    wt_make_repo alpha
    git -C "$WT_ROOT/alpha" worktree add -q --detach "$WT_ROOT/alpha/.worktrees/detached"
    run wt_clean_run --apply --stale-days 0
    [ "$status" -eq 0 ]
    # Detached worktree skipped because --include-detached not passed.
    [[ "$output" == *"no candidate worktrees"* ]]
    [ -d "$WT_ROOT/alpha/.worktrees/detached" ]
}

@test "clean: --include-detached + --apply removes detached worktree" {
    wt_make_repo alpha
    git -C "$WT_ROOT/alpha" worktree add -q --detach "$WT_ROOT/alpha/.worktrees/detached"
    local wt_path="$WT_ROOT/alpha/.worktrees/detached"
    run wt_clean_run --apply --include-detached --stale-days 0
    [ "$status" -eq 0 ]
    [ ! -d "$wt_path" ]
}

# ---- safety: skip sibling-dir unless --include-sibling-dirs -------------

@test "clean: sibling-dir worktrees skipped by default" {
    wt_make_repo alpha
    wt_make_worktree alpha feature "$WT_ROOT/alpha-sibling"
    run wt_clean_run --apply --stale-days 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"no candidate worktrees"* ]]
    [ -d "$WT_ROOT/alpha-sibling" ]
}

@test "clean: --include-sibling-dirs + --apply removes sibling-dir worktree" {
    wt_make_repo alpha
    wt_make_worktree alpha feature "$WT_ROOT/alpha-sibling"
    run wt_clean_run --apply --include-sibling-dirs --stale-days 0
    [ "$status" -eq 0 ]
    [ ! -d "$WT_ROOT/alpha-sibling" ]
}

# ---- safety: skip dirty unless --force ----------------------------------

@test "clean: dirty worktrees skipped by default" {
    wt_make_repo alpha
    wt_make_worktree alpha feature
    echo modified > "$WT_LAST_WT_PATH/uncommitted.txt"
    run wt_clean_run --apply --stale-days 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"no candidate worktrees"* ]]
    [ -d "$WT_LAST_WT_PATH" ]
}

@test "clean: --force + --apply removes dirty worktree" {
    wt_make_repo alpha
    wt_make_worktree alpha feature
    echo modified > "$WT_LAST_WT_PATH/uncommitted.txt"
    local wt_path="$WT_LAST_WT_PATH"
    run wt_clean_run --apply --force --stale-days 0
    [ "$status" -eq 0 ]
    [ ! -d "$wt_path" ]
}

# ---- --also-delete-branch ----------------------------------------------

@test "clean: --also-delete-branch removes branch after worktree" {
    wt_make_repo alpha
    wt_make_worktree alpha feature
    # Need the branch to be mergeable for -d to work. Merge it into main first.
    git -C "$WT_ROOT/alpha" merge --no-ff -q -m merge feature 2>/dev/null || true
    run wt_clean_run --apply --also-delete-branch --stale-days 0
    [ "$status" -eq 0 ]
    # Branch should be gone.
    run git -C "$WT_ROOT/alpha" rev-parse --verify --quiet refs/heads/feature
    [ "$status" -ne 0 ]
}

# ---- --repo filter -----------------------------------------------------

@test "clean: --repo NAME restricts removal to that repo" {
    wt_make_repo alpha
    wt_make_repo beta
    wt_make_worktree alpha a-feat
    wt_make_worktree beta b-feat
    run wt_clean_run --apply --stale-days 0 --repo beta
    [ "$status" -eq 0 ]
    [ -d "$WT_ROOT/alpha/.worktrees/a-feat" ]   # alpha untouched
    [ ! -d "$WT_ROOT/beta/.worktrees/b-feat" ]  # beta removed
}
