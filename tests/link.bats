#!/usr/bin/env bats
# Tests for bin/wt-link using temp fixture repos.

load fixtures/setup

setup() {
    wt_setup_fixture
}

@test "link: outside any git repo exits 2" {
    run wt_link_run "$BATS_TEST_TMPDIR"
    [ "$status" -eq 2 ]
    [[ "$output" == *"not inside a git repository"* ]]
}

@test "link: run from the main checkout exits 2 (main is the source)" {
    wt_make_repo alpha
    run wt_link_run "$WT_ROOT/alpha"
    [ "$status" -eq 2 ]
    [[ "$output" == *"main checkout"* ]]
}

# ---- auto-detect + create -----------------------------------------------

@test "link: links node_modules and .env from main into the worktree" {
    wt_make_repo alpha
    wt_ignore alpha node_modules .env .next
    wt_make_artifact alpha node_modules/
    wt_make_artifact alpha .env "SECRET=1"
    wt_make_artifact alpha .next/
    wt_make_worktree alpha feature

    run wt_link_run "$WT_LAST_WT_PATH"
    [ "$status" -eq 0 ]
    [ -L "$WT_LAST_WT_PATH/node_modules" ]
    [ "$(readlink "$WT_LAST_WT_PATH/node_modules")" = "$WT_ROOT/alpha/node_modules" ]
    [ -L "$WT_LAST_WT_PATH/.env" ]
}

@test "link: build dirs on the denylist are NOT linked" {
    wt_make_repo alpha
    wt_ignore alpha node_modules .next
    wt_make_artifact alpha node_modules/
    wt_make_artifact alpha .next/
    wt_make_worktree alpha feature

    run wt_link_run "$WT_LAST_WT_PATH"
    [ "$status" -eq 0 ]
    [ ! -e "$WT_LAST_WT_PATH/.next" ]
    [[ "$output" == *"created 1"* ]]
}

@test "link: a linked node_modules is uncommittable even under a dir-only rule" {
    wt_make_repo alpha
    # Committed dir-only rule — the dangerous case (does NOT ignore a symlink).
    printf 'node_modules/\n' > "$WT_ROOT/alpha/.gitignore"
    git -C "$WT_ROOT/alpha" -c user.email=t@t -c user.name=t add .gitignore
    git -C "$WT_ROOT/alpha" -c user.email=t@t -c user.name=t commit -q -m gitignore
    wt_make_artifact alpha node_modules/
    wt_make_worktree alpha feature

    run wt_link_run "$WT_LAST_WT_PATH"
    [ "$status" -eq 0 ]
    [ -L "$WT_LAST_WT_PATH/node_modules" ]
    # The guarantee: git does not see the symlink as committable.
    run git -C "$WT_LAST_WT_PATH" status --porcelain
    [[ "$output" != *"node_modules"* ]]
}
