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

# ---- idempotency + repair -----------------------------------------------

@test "link: second run is an idempotent no-op (0 created, exit 0)" {
    wt_make_repo alpha
    wt_ignore alpha node_modules
    wt_make_artifact alpha node_modules/
    wt_make_worktree alpha feature
    wt_link_run "$WT_LAST_WT_PATH"

    run wt_link_run "$WT_LAST_WT_PATH"
    [ "$status" -eq 0 ]
    [[ "$output" == *"created 0"* ]]
    [[ "$output" == *"ok 1"* ]]
}

@test "link: repairs a dangling symlink" {
    wt_make_repo alpha
    wt_ignore alpha node_modules
    wt_make_artifact alpha node_modules/
    wt_make_worktree alpha feature
    ln -s /nonexistent/path "$WT_LAST_WT_PATH/node_modules"

    run wt_link_run "$WT_LAST_WT_PATH"
    [ "$status" -eq 0 ]
    [ "$(readlink "$WT_LAST_WT_PATH/node_modules")" = "$WT_ROOT/alpha/node_modules" ]
    [[ "$output" == *"repaired 1"* ]]
}

@test "link: repoints a symlink aimed at the wrong target" {
    wt_make_repo alpha
    wt_ignore alpha node_modules
    wt_make_artifact alpha node_modules/
    wt_make_worktree alpha feature
    mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
    ln -s "$BATS_TEST_TMPDIR/elsewhere" "$WT_LAST_WT_PATH/node_modules"

    run wt_link_run "$WT_LAST_WT_PATH"
    [ "$status" -eq 0 ]
    [ "$(readlink "$WT_LAST_WT_PATH/node_modules")" = "$WT_ROOT/alpha/node_modules" ]
    [[ "$output" == *"repaired 1"* ]]
}

# ---- conflicts ----------------------------------------------------------

@test "link: real .env file in worktree is a conflict; emits rm -f one-liner; exit 1" {
    wt_make_repo alpha
    wt_ignore alpha node_modules .env
    wt_make_artifact alpha node_modules/
    wt_make_artifact alpha .env "MAIN=1"
    wt_make_worktree alpha feature
    printf 'LOCAL=1\n' > "$WT_LAST_WT_PATH/.env"   # real file, not a link

    run wt_link_run "$WT_LAST_WT_PATH"
    [ "$status" -eq 1 ]
    [[ "$output" == *"conflict"* ]]
    [[ "$output" == *"rm -f \"$WT_LAST_WT_PATH/.env\" && wt-link"* ]]
    # not clobbered
    [ "$(cat "$WT_LAST_WT_PATH/.env")" = "LOCAL=1" ]
}

@test "link: real node_modules dir in worktree is a conflict; emits rm -rf one-liner" {
    wt_make_repo alpha
    wt_ignore alpha node_modules
    wt_make_artifact alpha node_modules/
    wt_make_worktree alpha feature
    mkdir -p "$WT_LAST_WT_PATH/node_modules/real"

    run wt_link_run "$WT_LAST_WT_PATH"
    [ "$status" -eq 1 ]
    [[ "$output" == *"rm -rf \"$WT_LAST_WT_PATH/node_modules\" && wt-link"* ]]
}

# ---- expected-but-absent node_modules -----------------------------------

@test "link: package.json but no node_modules in main → exit 1 + npm hint" {
    wt_make_repo alpha
    wt_ignore alpha node_modules
    wt_make_artifact alpha package.json '{}'
    wt_make_worktree alpha feature

    run wt_link_run "$WT_LAST_WT_PATH"
    [ "$status" -eq 1 ]
    [[ "$output" == *"main has no node_modules"* ]]
    [[ "$output" == *"npm install"* ]]
    [[ "$output" == *"$WT_ROOT/alpha"* ]]
}

@test "link: pnpm-lock.yaml yields a pnpm install hint" {
    wt_make_repo alpha
    wt_ignore alpha node_modules
    wt_make_artifact alpha package.json '{}'
    wt_make_artifact alpha pnpm-lock.yaml ''
    wt_make_worktree alpha feature

    run wt_link_run "$WT_LAST_WT_PATH"
    [ "$status" -eq 1 ]
    [[ "$output" == *"pnpm install"* ]]
}
