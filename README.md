# wt-tools

Cross-repo audit, gated cleanup, and **deterministic Claude Code enforcement** for git worktrees.

The pitch: when you orchestrate work across multiple repos (one agent per repo, each in its own worktree), the rules that keep things safe — draft-PRs-only, no `gh pr merge` from automation, no `git worktree remove --force` — should be enforced, not requested. Skills and prose can be ignored. A PreToolUse hook can't.

## What's in the box

| | What | Type |
|---|---|---|
| `bin/wt-audit` | Cross-repo read-only worktree inventory | Script |
| `bin/wt-clean` | Gated destructive cleanup (dry-run by default) | Script |
| `bin/wt-validate-bash` | The hook validator | Script |
| `hooks/settings.fragment.json` | PreToolUse rules | Hook config |
| `config/wt-tools.conf.example` | Sourceable POSIX shell config | Config |
| `skills/multi-repo-dispatch/SKILL.md` | The orchestration playbook the hook enforces | Claude Code skill |
| `install.sh` | Idempotent installer | Script |

## Requirements

- `bash` 3.2+
- `git`
- `jq`
- Claude Code (only for the hook layer — the audit/clean scripts work standalone)

### Skill dependencies (only if you use the bundled `multi-repo-dispatch` skill)

The orchestration skill at `skills/multi-repo-dispatch/SKILL.md` invokes other skills by name. The skill itself documents them, but in short:

| Skill | From | When needed |
|---|---|---|
| `using-git-worktrees` | [superpowers plugin](https://github.com/anthropics/claude-code) | always (per-agent worktree creation) |
| `dispatching-parallel-agents` | superpowers | always (parallel fan-out discipline) |
| `<tracker-identify-repos>`, `<tracker-comment>`, `<tracker-link-prs>` | **you provide** — point them at your tracker (Linear / Jira / GitHub Issues / …) | only when picking up a tracked issue; for explicit input ("apply X in repos A and B") no tracker skills are needed |

The skill ships with `<tracker-…>` placeholders. After install, open `~/.claude/skills/multi-repo-dispatch/SKILL.md` and substitute each placeholder with the actual name of a skill you have (or delete the tracker-input path entirely if you don't have any tracker-helper skills).

`wt-tools` itself (the audit/clean/validator) has no skill dependencies — those are listed only because the bundled skill references them.

## Install

```bash
git clone <repo-url> ~/projects/wt-tools
cd ~/projects/wt-tools
bash install.sh                # interactive
# or:  bash install.sh --yes   # accept all prompts
```

What `install.sh` does:

1. Symlinks `bin/wt-audit` and `bin/wt-clean` into `$PREFIX` (default `~/.local/bin`).
2. Asks whether to merge the PreToolUse hook into `~/.claude/settings.json`. Writes a timestamped `.bak` first. The merge **appends** to existing `PreToolUse` hooks — it never overwrites your config.
3. Asks whether to copy the config template to `~/.config/wt-tools/wt-tools.conf`.

Uninstall: remove the symlinks in `$PREFIX`, restore the `.bak` settings.json file, delete the config file.

## Usage

```bash
wt-audit                              # table view of all linked worktrees under ~/projects
wt-audit --repo MoveEarth             # one repo
wt-audit --json                       # machine-readable
wt-audit --json --filter removable    # only candidates
wt-audit --stale-days 14              # mark anything older than 14 days as stale

wt-clean                              # dry-run with safe defaults
wt-clean --apply                      # actually remove (rare with default filters)
wt-clean --include-detached --include-sibling-dirs --force --stale-days 7 --apply
                                      # broad sweep; use deliberately
```

### `wt-clean` safety defaults

Without flags, `wt-clean` skips:

- detached-HEAD worktrees (`--include-detached` to include)
- worktrees outside the configured `WT_WORKTREE_DIR` convention (`--include-sibling-dirs` to include)
- worktrees with uncommitted changes (`--force` to include)

A removable worktree must be `merged into default branch`, `upstream-gone`, or `stale` (older than `WT_STALE_DAYS_CLEAN`). The dry-run prints the candidate list with reasons; no surprises.

## The PreToolUse hook (deterministic enforcement)

When installed, the hook blocks specific Bash commands from inside Claude Code — **but only when the session is running inside a linked git worktree**. Main checkouts, non-git directories, and parent-orchestrator sessions are unaffected:

| Command pattern | Default in linked worktree | Per-invocation bypass |
|---|---|---|
| `gh pr create` without `--draft` | **deny** | prefix with `WT_ALLOW_NONDRAFT=1` |
| `gh pr ready ...` | **deny** | none (the user marks PRs ready) |
| `gh pr merge ...` | **deny** | prefix with `WT_ALLOW_MERGE=1` |
| `git worktree remove --force ...` | **deny** | prefix with `WT_ALLOW_FORCE=1` |

The hook uses Claude Code's `if` field to pre-filter — the validator only runs for matching commands, not on every Bash call.

### Scope: why worktrees only

The model writes the rules. Worktrees are the model's workspace; the main checkout is yours. Default behavior:

| Session cwd | Behavior |
|---|---|
| `~/projects/some-repo/.worktrees/foo/` (linked worktree) | **enforce** |
| `~/projects/some-repo/` (main checkout) | defer (no enforcement) |
| `~/projects/` (parent orchestrator dir) | defer |
| `~/some-random-dir/` (not a git repo) | defer |
| inside a submodule | defer (treated as main-session) |

Scope is detected by reading `cwd` from the PreToolUse JSON payload and checking whether `GIT_DIR != GIT_COMMON_DIR` (the canonical "linked worktree" signal).

To enforce everywhere, set in `wt-tools.conf`:

```sh
WT_ENFORCE_SCOPE=all
```

### Bypass mechanism (visible, auditable)

Bypass env vars are prefixed onto the command itself:

```bash
WT_ALLOW_NONDRAFT=1 gh pr create --title "Hotfix" --body "..."
```

The validator parses the prefix from the command string. The bypass shows up verbatim in the Claude Code transcript, so you can audit when one was used. There is **no** session-wide off-switch besides the global `disableAllHooks: true` setting, which kills every hook in your config — usually overkill.

### Threat model — read this before trusting the hook

The validator does **token-level matching after whitespace splitting** of the bash command string. It catches the model's normal invocation patterns. It does NOT catch:

- Heredoc-fed commands: `bash <<EOF\ngh pr create\nEOF`
- `bash -c "gh pr create ..."` (the `if` filter doesn't match either)
- Commands built by string concatenation: `cmd="gh pr"; $cmd create`
- Aliased commands
- Anything routed through scripts that aren't visible in the literal Bash command string

These are documented limitations, not bugs. The hook is a **floor** for the common case (the model directly invokes `gh` / `git`), not a sandbox.

### Disable temporarily

Set in your settings.json:

```json
{ "disableAllHooks": true }
```

This kills every hook for that scope (project / user / managed). Re-enable by removing the key.

## Configuration

Three layers, in order of precedence (last wins):

1. **Global** — `~/.config/wt-tools/wt-tools.conf`. Installed by `install.sh`.
2. **Repo-shared** — `<repo>/.wt-tools.conf`. Committed to the repo so a whole team picks up the same overrides.
3. **Repo-personal** — `<repo>/.wt-tools.local.conf`. Gitignored; your private toggles on top of the team's shared config.

All three are POSIX-shell-sourceable. Common knobs:

```sh
WT_ROOT="$HOME/projects"
WT_WORKTREE_DIR=".worktrees"
WT_STALE_DAYS_AUDIT=30
WT_STALE_DAYS_CLEAN=60
WT_ENFORCE_SCOPE="worktree"   # or "all"
WT_IGNORE_REPOS=""
```

Any value can be overridden per-invocation via env var: `WT_ROOT=/tmp/test wt-audit`.

**Worked example.** Repo `core-api` allows non-draft PRs while everywhere else stays strict:

```sh
# ~/projects/core-api/.wt-tools.conf  (committed)
# Reason: hotfix workflow requires immediate ready PRs.
# Note: this only affects validate-bash when run from a worktree inside core-api.
WT_ENFORCE_SCOPE="all"
```

…then in `~/projects/core-api/.wt-tools.local.conf` (gitignored) a single dev might further override `WT_STALE_DAYS_AUDIT` for their own audit habits without affecting teammates.

## Layout assumptions

`wt-tools` assumes:

- One **parent dir** (`$WT_ROOT`, default `~/projects`) containing your cloned repos.
- Each repo's worktrees live at `<repo>/$WT_WORKTREE_DIR/...` (default `.worktrees/`). Sibling-dir worktrees still show up in the audit but are skipped by default in `wt-clean`.

There's no support for a global worktree directory (`~/worktrees/...`). If you need that, fork and add it.

## Testing

```bash
bats tests/                # full suite
bash tests/validate-bash.bats   # if you don't want to install bats-core, the smoke
                                 # logic is straightforward to translate
```

bats install on macOS: `brew install bats-core`.

## Not in scope (yet)

- A `wt-create` wrapper. Use `git worktree add` directly or the `using-git-worktrees` superpowers skill.
- A `wt-dispatch` script for multi-repo parallel orchestration. That responsibility belongs in a Claude Code skill (`multi-repo-dispatch` or similar). `wt-tools` enforces the rules; the skill provides the playbook.
- Linear / Jira / Asana integration.
- Branch-naming conventions.

## License

MIT. See `LICENSE`.
