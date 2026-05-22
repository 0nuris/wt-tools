#!/usr/bin/env bash
# Shared bats fixture helpers for audit.bats and clean.bats.
#
# Each test should call:
#   wt_setup_fixture            # creates a fresh WT_ROOT in $BATS_TEST_TMPDIR
#   wt_make_repo NAME           # makes a git repo with one empty commit
#   wt_make_worktree REPO BRANCH [DIR] # adds a linked worktree
#
# Cleanup is automatic via BATS_TEST_TMPDIR.

# Initialize a fresh, isolated WT_ROOT for the current test.
wt_setup_fixture() {
  export WT_ROOT="$BATS_TEST_TMPDIR/projects"
  mkdir -p "$WT_ROOT"
  # Empty config — tests provide their own env overrides.
  export WT_TOOLS_CONFIG="$BATS_TEST_TMPDIR/empty.conf"
  : > "$WT_TOOLS_CONFIG"
}

# Create a git repo with an initial commit on `main`.
# Side-effect: sets $WT_LAST_REPO_PATH (callers reference if needed).
wt_make_repo() {
  local name="$1" path="$WT_ROOT/$1"
  mkdir -p "$path"
  git -C "$path" init -q -b main
  git -C "$path" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  WT_LAST_REPO_PATH="$path"
}

# Add a linked worktree to a repo. If DIR is omitted, uses .worktrees/<branch>.
# Side-effect: sets $WT_LAST_WT_PATH (callers reference if needed).
wt_make_worktree() {
  local repo="$1" branch="$2" dir="${3:-}"
  local repo_path="$WT_ROOT/$repo"
  local wt_path
  if [[ -n "$dir" ]]; then
    wt_path="$dir"
  else
    wt_path="$repo_path/.worktrees/$branch"
  fi
  git -C "$repo_path" worktree add -q "$wt_path" -b "$branch"
  WT_LAST_WT_PATH="$wt_path"
}

# Run wt-audit with the fixture's env. Args forwarded.
wt_audit_run() {
  WT_ROOT="$WT_ROOT" WT_TOOLS_CONFIG="$WT_TOOLS_CONFIG" \
    bash "$BATS_TEST_DIRNAME/../bin/wt-audit" "$@"
}

# Run wt-clean with the fixture's env. Args forwarded.
wt_clean_run() {
  WT_ROOT="$WT_ROOT" WT_TOOLS_CONFIG="$WT_TOOLS_CONFIG" \
    bash "$BATS_TEST_DIRNAME/../bin/wt-clean" "$@"
}
