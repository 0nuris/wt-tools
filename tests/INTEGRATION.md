# Integration test — hook end-to-end

Manual checklist. Run once after every change to `wt-validate-bash`, `hooks/settings.fragment.json`, or `install.sh`. Bats covers unit-level rule logic; this checklist covers the round-trip through Claude Code's hook dispatch.

Driving Claude Code's CLI to automate this is out of scope.

## Setup

Run from any starting dir:

```bash
mkdir -p /tmp/wt-integration && cd /tmp/wt-integration
git init -q -b main testrepo
cd testrepo
git commit -q --allow-empty -m init
git worktree add -q .worktrees/feature -b feature
```

You now have:
- `/tmp/wt-integration/testrepo` — main checkout
- `/tmp/wt-integration/testrepo/.worktrees/feature` — linked worktree on branch `feature`

## A. Inside the linked worktree (default scope=worktree → ENFORCE)

In a fresh Claude Code session launched with `cd /tmp/wt-integration/testrepo/.worktrees/feature`:

| # | Command attempted | Expected |
|---|---|---|
| A1 | `gh pr create --title test --body test` | denied; reason mentions `--draft`; hint includes `WT_ALLOW_NONDRAFT=1` |
| A2 | `gh pr create --draft --title test --body test` | hook does NOT block; command may still fail for unrelated reasons (no remote) — that's fine |
| A3 | `gh pr ready 1` | denied; reason mentions "No bypass available" |
| A4 | `WT_ALLOW_NONDRAFT=1 gh pr create --title test --body test` | hook does NOT block (bypass honored) |
| A5 | `git worktree remove --force /tmp/dummy` | denied; reason mentions `WT_ALLOW_FORCE=1` |
| A6 | `WT_ALLOW_FORCE=1 git worktree remove --force /tmp/dummy` | hook does NOT block (then fails for unrelated reasons — fine) |
| A7 | `gh pr merge 123 --squash` | denied; reason mentions `WT_ALLOW_MERGE=1` |

## B. Inside the main checkout (scope=worktree → DEFER)

In a fresh Claude Code session launched with `cd /tmp/wt-integration/testrepo`:

| # | Command attempted | Expected |
|---|---|---|
| B1 | `gh pr create --title test --body test` | hook does NOT block (scope=worktree, main checkout defers); command fails for unrelated reasons — fine |
| B2 | `gh pr ready 1` | hook does NOT block |
| B3 | `gh pr merge 123 --squash` | hook does NOT block |
| B4 | `git worktree remove --force /tmp/dummy` | hook does NOT block |

## C. Outside any git repo (scope=worktree → DEFER)

In a fresh Claude Code session launched with `cd /tmp`:

| # | Command attempted | Expected |
|---|---|---|
| C1 | `gh pr create --title test --body test` | hook does NOT block |

## D. Scope override (WT_ENFORCE_SCOPE=all)

Edit `~/.config/wt-tools/wt-tools.conf`, set `WT_ENFORCE_SCOPE=all`, then in a fresh Claude Code session from `/tmp` (non-git):

| # | Command attempted | Expected |
|---|---|---|
| D1 | `gh pr create --title test --body test` | denied (scope override) |

Reset `WT_ENFORCE_SCOPE=worktree` when done.

## Teardown

```bash
rm -rf /tmp/wt-integration
```

## Pass criteria

All rows match expected. If any deviates, the hook layer has regressed and the regression is what the test was for — investigate before shipping.

## Run log

| Date | wt-tools commit | Outcome |
|---|---|---|
| _e.g. 2026-05-22_ | _e.g. 377f834_ | _e.g. all 12 rows match_ |
