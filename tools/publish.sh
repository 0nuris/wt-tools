#!/usr/bin/env bash
# publish.sh — push wt-tools to GitHub on demand.
#
# Refuses if the working tree is dirty or if there are unpushed commits
# ahead of the proposed origin. Detects the owner via `gh api user` and
# prompts if unavailable. Defaults to --public.
#
# Usage:
#   bash tools/publish.sh                  # interactive, public
#   bash tools/publish.sh --private        # private repo
#   bash tools/publish.sh --owner ORG      # explicit owner instead of gh user
#   OWNER=foo bash tools/publish.sh        # same via env var
#
# Required: gh, git.

set -euo pipefail

VISIBILITY="--public"
OWNER="${OWNER:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --private) VISIBILITY="--private"; shift ;;
    --public) VISIBILITY="--public"; shift ;;
    --owner) OWNER="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "publish.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null || { echo "publish.sh: gh CLI required" >&2; exit 1; }
command -v git >/dev/null || { echo "publish.sh: git required" >&2; exit 1; }

# Anchor to the wt-tools repo root (parent of this script's dir).
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$REPO_ROOT"

# Detect owner.
if [[ -z "$OWNER" ]]; then
  OWNER="$(gh api user --jq .login 2>/dev/null || true)"
  if [[ -z "$OWNER" ]]; then
    read -r -p "GitHub owner (org or username): " OWNER
  fi
fi
[[ -n "$OWNER" ]] || { echo "publish.sh: no owner; aborting" >&2; exit 1; }

REMOTE_NAME="$OWNER/wt-tools"

# Refuse if working tree dirty.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "publish.sh: working tree is dirty. Commit or stash before publishing." >&2
  git status --short >&2
  exit 1
fi

# Refuse if origin already exists with a different URL.
if git remote get-url origin >/dev/null 2>&1; then
  current="$(git remote get-url origin)"
  expected="https://github.com/$REMOTE_NAME.git"
  expected_ssh="git@github.com:$REMOTE_NAME.git"
  if [[ "$current" != "$expected" && "$current" != "$expected_ssh" ]]; then
    echo "publish.sh: origin already set to $current (expected $expected). Refusing." >&2
    exit 1
  fi
  echo "publish.sh: origin already configured. Pushing only."
  git push -u origin HEAD
  echo
  echo "Pushed. Repo URL:"
  gh repo view "$REMOTE_NAME" --json url --jq .url 2>/dev/null || \
    echo "  https://github.com/$REMOTE_NAME"
  exit 0
fi

echo "publish.sh:"
echo "  owner:      $OWNER"
echo "  repo:       $REMOTE_NAME"
echo "  visibility: ${VISIBILITY#--}"
read -r -p "Proceed? [y/N]: " confirm
[[ "$confirm" =~ ^[Yy] ]] || { echo "aborted"; exit 0; }

gh repo create "$REMOTE_NAME" --source=. "$VISIBILITY" --push

echo
echo "Published:"
gh repo view "$REMOTE_NAME" --json url --jq .url
echo
echo "If your README or skill files still reference '<your-fork-owner>',"
echo "consider running:"
echo "  sed -i.bak 's|<your-fork-owner>|$OWNER|g' README.md"
echo "  git add README.md && git commit -m 'Update README owner link' && git push"
