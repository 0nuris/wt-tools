---
name: multi-repo-dispatch
description: Use when starting work that spans 2+ repos from a parent dir like ~/projects (no single git repo in cwd), or when picking up a Linear issue that touches multiple repos. Orchestrates parallel subagents in isolated worktrees and lands draft PRs only — never ready-for-review.
---

# Multi-Repo Dispatch

> **Deterministic enforcement (recommended):** install [`wt-tools`](https://github.com/<your-fork-owner>/wt-tools). When the PreToolUse hook is active, the rules below — draft PRs only, no `gh pr ready`, no `gh pr merge` from automation, no `git worktree remove --force` — are enforced at the harness level regardless of whether the model complies with this skill text. Without `wt-tools`, the prose below is the only guard.

## Overview

You are orchestrating, not implementing. From a parent directory containing many cloned repos, fan out work to one subagent per (repo, task) pair, each in its own worktree, in parallel. You collect, you do not code.

**Core principle:** One subagent per worktree, parallel dispatch, draft PRs only, partial progress preserved.

**Announce at start:** "I'm using multi-repo-dispatch to orchestrate <N> agents across <repos>."

## When to Use

- Cwd is a parent dir of repos (e.g. `~/projects`), not a single repo
- Linear issue touches 2+ repos
- Explicit instruction names 2+ repos to apply a change to

**Do NOT use when:**
- Work is genuinely confined to one repo (use a normal session in that repo instead)
- You are already running inside a subagent dispatched by another orchestrator (no nesting)

## The Iron Rule: Draft PRs Only

**Every PR opened by orchestration MUST be `gh pr create --draft`. Period.**

- Never omit `--draft`
- Never run `gh pr ready` (the agent contract forbids it; you never run it either)
- "Open PRs when done" from the user means **draft** PRs. Their review is the gate.
- This rule is bulletproof. See rationalization table below.

## Workflow (rigid — follow in order)

### Phase 1: Scope

**TaskCreate one task per planned (repo, agent) pair as you discover them.** Track partial progress at the orchestrator level.

**Linear input** (issue ID, URL, or "pick up SOF-XXX"):
1. **REQUIRED:** invoke `linear-identify-repos` skill. Do not grep ad-hoc. Do not trust prior audit comments. Re-run every time.
2. Use that skill's repo list as authoritative.

**Explicit input** ("apply X in MoveEarth and ios-field-app-api"):
1. Resolve each named dir under the parent: `ls -d <parent>/<repo-name>`.
2. If any name is ambiguous or missing, ask the user before proceeding.

**Either way:** if the resolved repo set has only one repo, STOP and tell the user to run a normal session in that repo. This skill is for ≥2 repos.

### Phase 2: Decompose adaptively

For each target repo, decide aloud: **one agent or multiple agents?**

- Default to **one agent per repo**.
- Split into multiple agents within a repo only if the work is two cleanly independent concerns (e.g. backend has an unrelated config refactor alongside the new endpoint). Splittable concerns must be testable in isolation.
- Announce the decision: "Repo `X`: 1 agent (cohesive). Repo `Y`: 2 agents (endpoint + migration are independent)."

### Phase 3: Worktree setup per agent

For each (repo, task) pair:
1. `cd <parent>/<repo>` (each repo is its own setup; the parent dir is not a git repo).
2. **REQUIRED:** invoke `using-git-worktrees` to create the isolated workspace.
3. Branch name: `<linear-id>-<short-slug>` (Linear input) or `<short-slug>` (explicit input).

**Never create branches in the repo's existing checkout.** Parallel agents would collide. Worktree per agent is the only safe arrangement, even if the user "isn't on a branch you'd disturb."

### Phase 4: Dispatch parallel subagents

**REQUIRED:** invoke `dispatching-parallel-agents` discipline. Send all subagent calls in ONE message (multiple tool blocks) so they run concurrently.

Use the subagent prompt template below. Every prompt MUST include the draft-PR contract verbatim.

### Phase 5: Collect

When subagents return, categorize each:
- **Clean + draft PR opened** → record PR URL
- **Clean + no diff needed** → record "no-op"
- **Failed / stalled** → record worktree path, branch name, last known state, error summary

**Ship the wins, surface failures.** Never roll back a successful agent because another failed. Failed worktrees are NOT cleaned up — the user inspects them.

### Phase 6: Linear coordination (only if Linear input)

If input was a Linear issue, invoke `linear-issue-operations` (or `linear-github-coordination` if multiple PRs need linking) to:
- Post ONE comment listing the draft PR URLs + any failures
- **Do NOT change issue state.** Drafts are not "in review". The user moves state when they mark PRs ready.

## Subagent prompt template

Each subagent gets a self-contained prompt — they do not inherit your session. Use this shape:

```
You are working on <repo> in worktree <abs path>, on branch <branch>.

# Task
<one focused task description — copied from the Linear issue's relevant slice or the user's explicit instruction>

# Constraints
- Work ONLY in this worktree. Do not touch other repos.
- You are a single-repo worker. Do NOT invoke `multi-repo-dispatch` — that skill is for the orchestrator, not for you. If you think the task needs multi-repo work, STOP and report back; the orchestrator decides.
- Follow this repo's existing patterns and run its tests before finishing.
- If you discover the task is wrong-scoped (e.g. needs a different repo), STOP and report — do not expand scope.

# Finishing contract
When your changes are complete and tests pass:
1. Commit with a message referencing <linear-id if any>.
2. Push the branch: git push -u origin <branch>
3. Open a DRAFT pull request:
   gh pr create --draft --title "<title>" --body "<body referencing the issue>" --base <default-branch>
4. NEVER mark the PR ready. NEVER run `gh pr ready`. NEVER omit `--draft`.

# Return
Report: PR URL (or "no diff needed" / failure summary), branch name, and any blockers for the orchestrator.
```

## Hard guardrails (loophole-closing)

- **Drafts only, no exceptions.** "User said 'open PRs'" = draft PRs. "PR will be reviewed anyway" = still draft. The skill exists to enforce drafts; if you remove the draft, you've removed the skill.
- **No nested orchestration.** Subagents you dispatch from this skill MUST NOT re-invoke `multi-repo-dispatch`. The subagent prompt template forbids it. If a subagent reports back asking to orchestrate further, that's a sign the original decomposition was wrong — re-scope at the orchestrator level, do not let the subagent recurse.
- **No cross-repo subagent.** One agent never touches two repos. Two repos = two agents minimum.
- **Preserve all worktrees on failure.** Do not delete branches or worktrees of failed agents. The user needs them to debug.
- **No silent Linear state changes.** Comment only. State transitions belong to the human.
- **Parent dir is not a git repo.** Do not run git commands from `~/projects`. Always `cd` into a specific repo first.

## Common rationalizations — STOP

| Rationalization | Reality |
|---|---|
| "User said 'open PRs', not 'open draft PRs'" | Draft is the default this skill enforces. Read it again. |
| "Drafts are pointless because I'll mark it ready right after" | The user marks PRs ready. Not you. |
| "I'm a single agent, serial work is fine" | Then you're not orchestrating. Dispatch subagents in parallel. |
| "Worktrees are overhead for a clean repo" | Parallel agents on the same repo collide without them. |
| "I can grep faster than running linear-identify-repos" | The skill exists because grep misses ripple effects. Use it. |
| "One agent failed, I should roll back the wins" | Ship the wins. Surface the failure. Always. |
| "I should move the Linear issue to In Review" | Drafts are not in review. Comment-only. |
| "It's only one repo — I'll still orchestrate" | Single-repo = normal session. This skill is for ≥2 repos. |

## Red flags — STOP and re-read this skill

- About to run `gh pr create` without `--draft`
- About to run `gh pr ready`
- About to work in a repo's main checkout instead of a worktree
- About to dispatch one subagent to two repos
- About to delete a failed agent's worktree or branch
- About to call `save_issue` to change Linear state
- About to recurse — orchestrating from inside an orchestrated subagent
- About to skip `linear-identify-repos` "because the issue already has an audit comment"

All of these mean: STOP. Re-read the relevant guardrail.

## Quick reference

| Step | Skill invoked |
|---|---|
| Repo identification (Linear input) | `linear-identify-repos` |
| Worktree creation per agent | `using-git-worktrees` |
| Parallel dispatch discipline | `dispatching-parallel-agents` |
| Linear PR linking (multi-PR) | `linear-github-coordination` |
| Linear comment posting | `linear-issue-operations` |

| Decision | Default |
|---|---|
| Agents per repo | 1 (split only for cleanly independent concerns) |
| Branch location | Always a worktree, never the main checkout |
| PR state | Draft, always |
| Linear state | Comment only, never change state |
| On partial failure | Ship wins, preserve failed worktrees, report |

## Cross-references

- **REQUIRED:** `using-git-worktrees` — per-agent isolation
- **REQUIRED:** `dispatching-parallel-agents` — fan-out discipline
- **REQUIRED for Linear input:** `linear-identify-repos` — authoritative repo mapping
- **For Linear coordination:** `linear-issue-operations`, `linear-github-coordination`
