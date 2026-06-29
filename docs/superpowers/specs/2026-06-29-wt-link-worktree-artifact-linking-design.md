# wt-link — Worktree Artifact Linking (design)

- **Date:** 2026-06-29
- **Status:** Approved in brainstorming; pending written-spec review
- **Repo:** wt-tools
- **Author:** jbarnett (with Claude)

## Problem / motivation

When agents work in git worktrees — created by Claude Code's native `EnterWorktree`
(→ `.claude/worktrees/`), by `git worktree add` (→ `.worktrees/` or sibling dirs) —
the new worktree is missing everything gitignored: `node_modules` (1.2 GB in
MoveEarthWeb, 691 MB / 448 MB elsewhere), `.env` / `.env.local`, and other
config/secret files.

The standard remedy (`npm install` in the worktree) **fails in this environment**:
`~/.claude/settings.json` hard-denies all dependency installs and `chmod`. An agent
that hits this dead-ends — observed verbatim: *"npm install permission denied,"*
blocking typecheck/lint/test/build.

**Goal:** at worktree setup, make the shareable gitignored artifacts available in the
new worktree by **symlinking them from the repo's main checkout** — no install, no
chmod — and provide a deterministic, **idempotent repair path** an agent (or the user)
can run when something is still missing, surfacing the few human-only steps as
ready-to-run commands.

## Environment constraints (load-bearing)

From `~/.claude/settings.json` `permissions.deny`:

- `chmod`, `chown` denied → cannot create/repair executable git hooks ⇒ a
  `post-checkout` hook trigger is **out**.
- `npm install` / `npm ci` / `npm i` / `yarn add|install` / `pnpm add|install` /
  `pip install` denied → agents cannot install dependencies anywhere.
- `rm -rf` denied. Plain `rm <file>` / `rm <symlink>` is **allowed**.
- `~/.local/bin` is on `PATH`; bin scripts are mode `100755`.
- `Bash(bash *)` is allowed ⇒ `wt-link` is invoked as `bash …/wt-link` (or by name,
  since it's executable). Its internal subprocesses (`ln`, `rm`, `git`, `mkdir`) are
  **not** individually gated by the permission system — only the single outer `bash`
  call is.

**Design rule (trust):** `wt-link` MUST respect these guardrails. Even though, as a
`bash` subprocess, it *could* technically run `npm install` or `chmod` and bypass the
deny list, it never does. The user set those denies deliberately. For anything blocked,
`wt-link` emits a human-run command instead of silently subverting the guardrail.

## Command interface

```
wt-link [WORKTREE_PATH] [--dry-run] [--quiet] [-h|--help]
```

- `WORKTREE_PATH` — target worktree. Default: current directory.
- `--dry-run` — report desired-vs-actual; make no changes.
- `--quiet` — print only problems + the summary line.
- Exit codes:
  - `0` — reconciled; nothing pending (includes the idempotent no-op re-run).
  - `1` — a human-only action is pending (e.g. main missing `node_modules`) or an
    unresolved conflict remains.
  - `2` — usage error / not in a git repo / target is the main checkout / main not
    found on disk.

Re-running `wt-link` **is** the repair path. There is no separate `--repair` flag:
idempotent reconciliation covers create, repoint, and dangling-link repair.

## Algorithm

1. Resolve `WORKTREE_PATH` (arg or `cwd`) to an absolute path. Require it be inside a
   git repo (`git -C … rev-parse`). Else exit `2`.
2. Identify the main checkout: `git -C <target> worktree list --porcelain`; the first
   `worktree ` line is the main worktree (robust — no path arithmetic). If `target` ==
   main → exit `2`: *"run this inside a linked worktree; the main checkout is the
   source — nothing to link."* If main's path doesn't exist on disk → exit `2`.
3. Load config (layered, mirroring `wt-audit`/`wt-clean`):
   - Global: `. "${WT_TOOLS_CONFIG:-$HOME/.config/wt-tools/wt-tools.conf}"`.
   - Per-repo, sourced from the **main checkout** dir (so the gitignored
     `.wt-tools.local.conf` is reliably present): `.wt-tools.conf` then
     `.wt-tools.local.conf`, in a subshell.
   - Resolve `WT_LINK_AUTO`, `WT_LINK_PATHS`, `WT_LINK_EXCLUDE`.
4. Build the candidate set:
   - If `WT_LINK_AUTO=true` (default): `git -C <main> ls-files --others --ignored
     --exclude-standard --directory`. The `--directory` flag collapses a fully-ignored
     dir to `node_modules/`, `.next/`, etc.; root files appear as `.env`. Keep only
     root-level entries (no internal `/`); strip the trailing `/`.
   - Always union with `WT_LINK_PATHS` (explicit; entries may be nested, e.g.
     `config/local.json`). The root-level filter and denylist (step 5) do **not**
     apply to `WT_LINK_PATHS`.
   - **Expected-but-absent guard:** if main has a `package.json` but no `node_modules`,
     inject `node_modules` into the candidate set anyway, so step 7 detects and warns.
     (Auto-detect can't list what isn't there; this is the `MoveEarth` case — the
     primary motivating scenario.)
5. Apply the denylist to **auto-detected** entries only (explicit `WT_LINK_PATHS`
   always wins and is never denied). Denylist = built-in set ∪ `WT_LINK_EXCLUDE`,
   matched by basename and glob (e.g. `*.log`):
   - Built-in: `.next .nuxt .svelte-kit dist build out .output coverage .turbo .cache
     .parcel-cache .vite .pytest_cache __pycache__ *.log .DS_Store Thumbs.db`.
   - Dependency dirs (`node_modules`, `.venv`) are **not** denied — they are shareable.
6. For each candidate that exists in main (`test -e <main>/<entry>`):
   - `source=<main>/<entry>` (absolute), `target=<worktree>/<entry>`.
   - `target` is a symlink:
     - `readlink target` == `source` → **OK, skip**.
     - else (wrong target or dangling) → `rm` the symlink, recreate → **repaired**.
   - `target` exists as a **real** file/dir (not a symlink) → **conflict**: never
     clobber it, but report it and **emit a destructive escape-hatch command** for the
     human to run by choice (`rm -rf` for a dir, `rm -f` for a file — `rm -rf` of a
     real dir is denied to agents, so this is human-only by necessity):
     ```
     conflict: <target> is a real <dir|file>, not a link to main — left as-is.
       to replace it with the shared copy from main:
         ! rm -rf "<target>" && wt-link "<worktree>"     # dir
         ! rm -f  "<target>" && wt-link "<worktree>"     # file
     ```
     Counts as a pending-human item. For files especially, the human should confirm the
     content isn't worktree-unique before removing it.
   - `target` absent → `mkdir -p "$(dirname target)"`; `ln -s "$source" "$target"` →
     **created**.
7. For a candidate **absent in main** (`test ! -e source`): record a **human-only**
   item. This arises for (a) the injected `node_modules` guard from step 4, and (b) any
   `WT_LINK_PATHS` entry that names something main doesn't have. For `node_modules`,
   emit the package-manager-specific install hint (below); for a missing
   `WT_LINK_PATHS` entry, report it by name. (Detecting absent dep dirs for other
   ecosystems — e.g. Python `.venv` — is out of scope for v1; only `node_modules` gets
   the expected-but-absent guard.)
8. Print a summary: `created N, repaired M, ok K, conflicts C, pending P` (where `ok`
   = already-correct links left untouched, `conflicts` = real entries blocking a link,
   `pending` = absent-in-main human-only installs). Pending-human total = `C + P`;
   exit `1` if `C + P > 0`, else `0`.

## Package-manager detection (install hint only)

Detected from lockfiles in main: `pnpm-lock.yaml` → `pnpm`; `yarn.lock` → `yarn`;
`bun.lockb` → `bun`; else → `npm`. Hint:

```
main checkout has no node_modules — wt-link can't install it (blocked here).
Run once, then re-run wt-link:
    ! (cd "<main>" && <pm> install)
```

`wt-link` never runs the install itself.

## Configuration

Added to `config/wt-tools.conf.example` (so `install.sh` ships them), with comments.
Same precedence as existing knobs (global < repo-shared < repo-personal; per-invocation
env override):

```sh
# Auto-detect gitignored root entries in the main checkout and link them.
# false = link ONLY what WT_LINK_PATHS names (predictable mode).
WT_LINK_AUTO="${WT_LINK_AUTO:-true}"

# Force-include extra paths (space-separated; may be nested). Always linked,
# never subject to the denylist. e.g. "certs/ service-account.json"
WT_LINK_PATHS="${WT_LINK_PATHS:-}"

# Extend the built-in build/cache/log denylist (space-separated; basenames/globs).
WT_LINK_EXCLUDE="${WT_LINK_EXCLUDE:-}"
```

## Integration / triggers

**A. Automatic (orchestrated).** Edit the repo's `skills/multi-repo-dispatch/SKILL.md`
(re-running `install.sh` propagates it to `~/.claude/skills/...`):

- Phase 3 (worktree setup per agent): after the worktree exists, run `wt-link` in it.
  This replaces the implicit `npm install` expectation.
- Subagent prompt template — add: *"Dependencies and config are symlinked from the main
  checkout, not installed. Do NOT run `npm`/`pnpm`/`yarn` install (blocked here). If
  deps or config are missing/broken, run `wt-link` to reconcile. If it reports a
  human-only step, STOP and report it to the orchestrator — do not work around it."*
  This is the clause that stops the next agent from dead-ending.

**B. Manual (single-repo / native `.claude/worktrees` session).** `wt-link` defaults to
`cwd`, so the user or an agent runs `wt-link` from inside any worktree, regardless of
how it was created. Documented in the README.

**C. NOT a git hook.** `chmod` is blocked (can't make a hook executable, and the hook
isn't a tracked file so `git update-index --chmod` can't help), and whether native
`EnterWorktree` fires `post-checkout` is unverified/unreliable. Explicitly out of scope.

## install.sh / doctor.sh

- `install.sh`: add `wt-link` to the `bin/` symlink loop alongside `wt-audit`/
  `wt-clean`. The config template already carries `WT_LINK_*`, so no extra prompts.
- `doctor.sh`: add a one-line pointer that `wt-link --dry-run` checks a specific
  worktree's link health. No new hard checks in v1.

## Edge cases / error handling

- `target` == main → exit `2`, clear message.
- not in a git repo → exit `2`.
- main path missing on disk (e.g. moved) → exit `2`.
- candidate is itself a symlink in main → link to it as-is (do not dereference).
- real file/dir already in worktree → never clobber; report as a conflict and emit the
  destructive `! rm … && wt-link` escape-hatch one-liner (step 6). No `--force` flag in
  v1 — the agent can't `rm -rf` a real dir anyway (denied), so replacement is human-run
  by necessity; the tool's job is to *emit* the exact command, not perform it.
- dangling / wrong-target symlink in worktree → repaired (`rm` + recreate).
- `WT_LINK_AUTO=false` → only `WT_LINK_PATHS` considered.
- spaces in paths → quote everywhere; a spaced-path case is in the tests.
- entry in both `WT_LINK_PATHS` and the denylist → explicit include wins.

## Testing (bats, `tests/`)

Fixture: a temp git repo (main) with `node_modules/`, `.env`, `.next/`, a `*.log`;
add a linked worktree; run `wt-link` against it.

1. Links `node_modules` and `.env`; `.next` NOT linked (denylist).
2. Idempotent: second run → 0 created, exit `0`.
3. Dangling symlink repaired.
4. Wrong-target symlink repointed.
5. Real `.env` file in worktree → conflict: left as-is, exit `1`, emits
   `! rm -f "<wt>/.env" && wt-link "<wt>"`. A real `node_modules` dir → same, with
   `rm -rf`.
6. Main has `package.json` but no `node_modules` → exit `1`, correct PM hint
   (npm/pnpm/yarn/bun per lockfile) via the expected-but-absent guard.
7. `WT_LINK_PATHS` adds a nested file (`config/local.json`) with `mkdir -p` of parent.
8. `WT_LINK_EXCLUDE` drops an otherwise-linked entry.
9. `WT_LINK_AUTO=false` links only `WT_LINK_PATHS`.
10. Run from the main checkout → exit `2`.
11. Run outside any git repo → exit `2`.
12. Path with spaces handled.

## Docs

- README: new `## Linking shared artifacts into worktrees (wt-link)` section —
  what/why, automatic + manual use, the config knobs, the repair loop, and the
  human-only-steps behavior.
- README: update the "Not in scope" `wt-create` bullet to clarify `wt-link` is a
  *post-create setup helper* (worktree creation is still delegated).
- README: add `bin/wt-link` to the "What's in the box" table.

## Out of scope (v1)

- Running installs or `chmod` on the user's behalf (blocked by design + guardrails).
- A worktree-creation wrapper (still delegated to `using-git-worktrees` / native tools).
- pnpm content-addressed store migration (a better long-term dedupe, but symlinks were
  chosen).
- Linking individual files nested inside ignored dirs beyond explicit `WT_LINK_PATHS`.
- Global (`~/worktrees`) layouts.
