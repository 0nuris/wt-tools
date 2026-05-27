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

## Quick start

The 60-second flow:

```bash
git clone https://github.com/0nuris/wt-tools     # clones into ./wt-tools
cd wt-tools                                       # or wherever you cloned it
bash install.sh                                   # interactive — see below
bash tools/doctor.sh                              # confirms everything's wired
wt-audit                                          # smoke-test the read-only path
```

Where you put the clone is up to you — `install.sh` derives `WT_TOOLS_HOME` from its own location at run time, so the absolute path is captured wherever it lives.

Non-interactive (CI, scripted setup):

```bash
WT_ROOT="$HOME/code" \
WT_TRACKER_IDENTIFY=my-identify-repos \
WT_TRACKER_COMMENT=my-comment \
WT_TRACKER_LINK_PRS=my-link-prs \
  bash install.sh --yes
```

`WT_ROOT` is **required** in `--yes` mode (the parent dir of your cloned
repos — wt-audit/wt-clean have no default). The `WT_TRACKER_*` vars are
optional; skip them if you don't use a tracker. Wire tracker integration
later with `bash tools/configure-tracker.sh` if you change your mind.

### What `install.sh` does

1. Symlinks `bin/wt-audit` and `bin/wt-clean` into `$PREFIX` (default `~/.local/bin`).
2. Merges the PreToolUse hook into `~/.claude/settings.json` (timestamped `.bak` first). Idempotent — re-runs replace wt-tools entries, never duplicate them.
3. Detects your GitHub owner via `gh api user` and substitutes `<your-fork-owner>` in the installed skill (prompts if `gh` not authenticated).
4. Copies the `multi-repo-dispatch` skill from `skills/` to `~/.claude/skills/` if not already present.
5. Prompts for the three tracker skill names and substitutes them in the installed skill. Skip any prompt with Enter; come back later via `tools/configure-tracker.sh`.
6. Installs shell completions (bash + zsh).
7. Copies the config template to `~/.config/wt-tools/wt-tools.conf` if not already present.

### Tools to know about

| Script | What it does | When to run |
|---|---|---|
| `install.sh` | Full install / re-install | First time; after a `git pull` |
| `tools/configure-tracker.sh` | Substitute the three tracker placeholders in the installed skill | When you skipped during install, or when you switch trackers |
| `tools/doctor.sh` | Health-check the installation; report remaining placeholders | After install; whenever something feels off |
| `tools/publish.sh` | Publish *this* repo to GitHub (for maintainers / forks) | Only when shipping changes upstream |

Uninstall: `bash tools/uninstall.sh` (conservative — strips the hook + symlinks, keeps config/skill/completions). Add `--remove-config`, `--remove-skill`, `--remove-completions` to wipe those too. Pass `--yes` for non-interactive. Same `PREFIX` / `CLAUDE_SETTINGS` / `CONFIG_PATH` / `SKILL_FILE` env overrides as install.

## Usage

```bash
wt-audit                              # table view of all linked worktrees under $WT_ROOT
wt-audit --repo my-repo               # one repo
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

wt-tools identifies its own hook entries by the `wt-validate-bash` path in `.command`, since Claude Code's settings serializer doesn't preserve custom keys on round-trip.

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

The validator does **token-level matching after whitespace splitting** of the bash command string. It catches the model's normal invocation patterns plus the most common wrapper:

**Caught:**
- Direct invocations: `gh pr create ...`, `gh pr ready ...`, `gh pr merge ...`, `git worktree remove --force ...`
- `bash -c "..."` and `sh -c "..."` wrappers around any of the above (including flag clusters like `bash -lc`). The `inspect-wrapped` rule slices past the `-c` flag, strips outer quote chars from the tokenized args, and re-runs all four rule checks against the wrapped tokens. `WT_ALLOW_*` bypass env vars at the outer command's front still work.

**NOT caught (documented limitations):**
- Heredoc-fed commands: `bash <<EOF\ngh pr create\nEOF` — needs heredoc parsing
- Commands built by string concatenation: `cmd="gh pr"; $cmd create` — requires variable expansion
- Aliased commands: `alias gpc='gh pr create'; gpc` — shell-runtime resolution
- Anything routed through scripts that aren't visible in the literal Bash command string
- Other interpreters: `python -c "..."`, `node -e "..."` — only bash/sh wrap shell commands directly

These are documented limitations, not bugs. The hook is a **floor** for the common case + the most accessible wrapper, not a sandbox.

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
WT_ROOT="$HOME/code"          # required; no default — wt-audit/wt-clean refuse to run without it
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

- One **parent dir** (`$WT_ROOT` — required, no default; set by `install.sh` on first run or in `~/.config/wt-tools/wt-tools.conf`) containing your cloned repos.
- Each repo's worktrees live at `<repo>/$WT_WORKTREE_DIR/...` (default `.worktrees/`). Sibling-dir worktrees still show up in the audit but are skipped by default in `wt-clean`. If you find lots of sibling-dir worktrees in your audit, your `WT_WORKTREE_DIR` may not match your team's convention — `tools/doctor.sh` flags this.

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
