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
