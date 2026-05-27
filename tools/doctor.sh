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

# Threshold for the sibling-dir mismatch heuristic. If ≥ this fraction of
# linked worktrees are outside the configured WT_WORKTREE_DIR (and there
# are at least 2 such worktrees), doctor flags a possible convention
# mismatch. 30 = 30%.
SIBLING_DIR_WARN_PCT="${SIBLING_DIR_WARN_PCT:-30}"

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
  # Inspect effective WT_ROOT and WT_WORKTREE_DIR.
  EFFECTIVE_ROOT="$(    . "$CONFIG_PATH" 2>/dev/null; printf '%s' "${WT_ROOT:-}" )"
  EFFECTIVE_WT_DIR="$(  . "$CONFIG_PATH" 2>/dev/null; printf '%s' "${WT_WORKTREE_DIR:-.worktrees}" )"
  if [[ -z "$EFFECTIVE_ROOT" ]]; then
    check "WT_ROOT" fail "not set — edit $CONFIG_PATH or export WT_ROOT (no default; required)"
  elif [[ -d "$EFFECTIVE_ROOT" ]]; then
    repo_count=$(find "$EFFECTIVE_ROOT" -mindepth 1 -maxdepth 2 -type d -name '.git' 2>/dev/null | wc -l | tr -d ' ')
    if (( repo_count > 0 )); then
      check "WT_ROOT=$EFFECTIVE_ROOT" ok "$repo_count git repos detected at depth ≤ 2"
    else
      check "WT_ROOT=$EFFECTIVE_ROOT" warn "directory exists but contains no git repos — wt-audit will be empty"
    fi
  else
    check "WT_ROOT=$EFFECTIVE_ROOT" warn "directory does not exist — edit $CONFIG_PATH or set WT_ROOT in env"
  fi
else
  check "$CONFIG_PATH" warn "not installed — wt-audit / wt-clean require WT_ROOT (set in env or run install.sh)"
fi

# ---- 4. Claude Code hook ------------------------------------------------
echo
echo "hook:"
# Identification is by the wt-validate-bash substring in .command, NOT by a
# marker field. Claude Code's settings serializer strips unknown JSON keys
# on round-trip (e.g. when the user toggles a CC setting), so any custom
# marker we add disappears at the first write. The command path is a known
# field and survives, and the rule name is the command's last token.
EXPECTED_RULES="draft-prs inspect-wrapped no-force-remove no-pr-merge no-pr-ready"
if [[ -f "$CLAUDE_SETTINGS" ]]; then
  check "$CLAUDE_SETTINGS" ok
  if jq -e '.hooks.PreToolUse' "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
    found_rules="$(jq -r '
      [.hooks.PreToolUse[]?.hooks[]?.command
        | select(. != null and contains("wt-validate-bash"))
        | split(" ") | last]
      | sort | unique | join(" ")
    ' "$CLAUDE_SETTINGS")"
    if [[ "$found_rules" == "$EXPECTED_RULES" ]]; then
      check "wt-tools hook entries" ok "5 rules wired ($found_rules)"
    elif [[ -z "$found_rules" ]]; then
      check "wt-tools hook entries" fail "no wt-validate-bash entries — run install.sh"
    else
      missing=""
      for r in $EXPECTED_RULES; do
        case " $found_rules " in *" $r "*) ;; *) missing="$missing $r" ;; esac
      done
      extra=""
      for r in $found_rules; do
        case " $EXPECTED_RULES " in *" $r "*) ;; *) extra="$extra $r" ;; esac
      done
      detail="found: $found_rules"
      [[ -n "$missing" ]] && detail="$detail; missing:$missing"
      [[ -n "$extra" ]]   && detail="$detail; unexpected:$extra"
      check "wt-tools hook entries" warn "$detail — re-run install.sh"
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

# ---- 6. convention sanity (sibling-dir ratio) ---------------------------
echo
echo "convention:"
# This check is informational. It only runs when wt-audit is installed and
# WT_ROOT is set + populated — otherwise earlier sections have already
# raised the relevant warning.
if [[ -x "$PREFIX/wt-audit" || -L "$PREFIX/wt-audit" ]] \
   && [[ -n "${EFFECTIVE_ROOT:-}" ]] && [[ -d "${EFFECTIVE_ROOT:-}" ]]; then
  audit_json="$( WT_TOOLS_CONFIG="$CONFIG_PATH" bash "$PREFIX/wt-audit" --json 2>/dev/null )"
  if [[ -n "$audit_json" ]] && total=$(jq 'length' <<<"$audit_json" 2>/dev/null) && [[ "$total" =~ ^[0-9]+$ ]]; then
    if (( total == 0 )); then
      check "sibling-dir convention" ok "no linked worktrees to evaluate"
    else
      sibling=$(jq '[.[] | select(.sibling_dir == "yes")] | length' <<<"$audit_json" 2>/dev/null || echo 0)
      pct=$(( sibling * 100 / total ))
      if (( sibling >= 2 )) && (( pct >= SIBLING_DIR_WARN_PCT )); then
        check "sibling-dir convention" warn "$sibling of $total worktrees ($pct%) live outside WT_WORKTREE_DIR='$EFFECTIVE_WT_DIR'"
        echo "      Either your repos use a different convention (e.g. 'worktrees/' without the dot, or"
        echo "      a sibling directory next to the repo) — set WT_WORKTREE_DIR in $CONFIG_PATH —"
        echo "      or they're intentional one-offs and you can ignore this."
      else
        check "sibling-dir convention" ok "$sibling of $total worktrees outside WT_WORKTREE_DIR='$EFFECTIVE_WT_DIR'"
      fi
    fi
  else
    check "sibling-dir convention" warn "wt-audit --json produced no parseable output — skipping"
  fi
else
  check "sibling-dir convention" ok "skipped (wt-audit not installed or WT_ROOT unset/missing)"
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
