#!/usr/bin/env bash
# doctor.sh — quick health check for a wt-tools installation.
#
# Reports state without changing anything. Useful after install.sh, or when
# wt-tools "isn't behaving" and you want to know what's missing.
#
# Usage:
#   bash tools/doctor.sh
#
# Exit code: 0 if everything looks healthy, 1 if any check failed.

set -uo pipefail

PREFIX="${PREFIX:-$HOME/.local/bin}"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
CONFIG_PATH="${CONFIG_PATH:-$HOME/.config/wt-tools/wt-tools.conf}"
SKILL_FILE="${SKILL_FILE:-$HOME/.claude/skills/multi-repo-dispatch/SKILL.md}"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

fail=0
warn=0

check() {
  local label="$1" status="$2" detail="${3:-}"
  case "$status" in
    ok)   green "  ✓ $label";          [[ -n "$detail" ]] && echo "      $detail" ;;
    fail) red   "  ✗ $label";          [[ -n "$detail" ]] && echo "      $detail"; fail=$((fail + 1)) ;;
    warn) yellow "  ! $label";         [[ -n "$detail" ]] && echo "      $detail"; warn=$((warn + 1)) ;;
  esac
}

echo "wt-tools doctor"
echo

# ---- 1. system deps -----------------------------------------------------
echo "deps:"
for cmd in bash git jq; do
  if command -v "$cmd" >/dev/null 2>&1; then
    check "$cmd" ok "$(command -v "$cmd")"
  else
    check "$cmd" fail "not on PATH — install it"
  fi
done
if command -v gh >/dev/null 2>&1; then
  check "gh" ok "$(command -v gh) — required only for PR-related commands"
else
  check "gh" warn "not on PATH — required if you use gh pr create / ready / merge"
fi

# ---- 2. bin scripts -----------------------------------------------------
echo
echo "bin:"
for s in wt-audit wt-clean; do
  dst="$PREFIX/$s"
  if [[ -L "$dst" ]]; then
    target="$(readlink "$dst")"
    if [[ -e "$target" ]]; then
      check "$dst" ok "-> $target"
    else
      check "$dst" fail "symlink target missing: $target"
    fi
  elif [[ -f "$dst" ]]; then
    check "$dst" warn "file (not symlink) — re-install to refresh on updates"
  else
    check "$dst" fail "not installed in $PREFIX — run install.sh"
  fi
done

case ":$PATH:" in
  *":$PREFIX:"*) check "PATH includes $PREFIX" ok ;;
  *)             check "PATH includes $PREFIX" warn "add: export PATH=\"$PREFIX:\$PATH\"" ;;
esac

# ---- 3. config ----------------------------------------------------------
echo
echo "config:"
if [[ -f "$CONFIG_PATH" ]]; then
  check "$CONFIG_PATH" ok
  # Source it in a subshell to catch syntax errors without affecting our env.
  if ( . "$CONFIG_PATH" ) >/dev/null 2>&1; then
    check "config syntactically valid" ok
  else
    check "config syntactically valid" fail "source fails — check shell syntax"
  fi
else
  check "$CONFIG_PATH" warn "not installed — defaults will apply (WT_ROOT=\$HOME/projects)"
fi

# ---- 4. Claude Code hook ------------------------------------------------
echo
echo "hook:"
if [[ -f "$CLAUDE_SETTINGS" ]]; then
  check "$CLAUDE_SETTINGS" ok
  if jq -e '.hooks.PreToolUse' "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
    n=$(jq '[.hooks.PreToolUse[].hooks[] | select(._wt_tools_rule != null)] | length' "$CLAUDE_SETTINGS")
    if [[ "$n" == "4" ]]; then
      check "wt-tools hook entries" ok "4 rules wired (draft-prs, no-pr-ready, no-pr-merge, no-force-remove)"
    elif [[ "$n" == "0" ]]; then
      check "wt-tools hook entries" fail "none found — run install.sh"
    else
      check "wt-tools hook entries" warn "$n of 4 wired — re-run install.sh"
    fi
  else
    check "PreToolUse hooks key" fail "no .hooks.PreToolUse in settings — run install.sh"
  fi
else
  check "$CLAUDE_SETTINGS" warn "not present — Claude Code not configured on this machine?"
fi

# ---- 5. skill -----------------------------------------------------------
echo
echo "skill:"
if [[ -f "$SKILL_FILE" ]]; then
  check "$SKILL_FILE" ok
  placeholders=$(grep -oE '<[a-z-]+-owner>|<tracker-[a-z-]+>' "$SKILL_FILE" 2>/dev/null | sort -u | tr '\n' ' ')
  if [[ -z "$placeholders" ]]; then
    check "placeholders" ok "all substituted"
  else
    check "placeholders" warn "remaining: $placeholders"
    echo "      Run tools/configure-tracker.sh, or substitute manually."
  fi
else
  check "$SKILL_FILE" warn "not installed — run install.sh"
fi

# ---- summary ------------------------------------------------------------
echo
if (( fail > 0 )); then
  red "Summary: $fail check(s) failed, $warn warning(s). See above."
  exit 1
elif (( warn > 0 )); then
  yellow "Summary: $warn warning(s). Installation usable, follow-ups suggested."
  exit 0
else
  green "Summary: all checks passed."
  exit 0
fi
