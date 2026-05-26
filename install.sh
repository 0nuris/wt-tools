#!/usr/bin/env bash
# wt-tools installer — idempotent.
#
# Steps:
#   1. Resolve install dir (this repo's location).
#   2. Symlink bin/wt-audit and bin/wt-clean into $PREFIX (default ~/.local/bin).
#   3. Optionally merge the PreToolUse hook into ~/.claude/settings.json.
#   4. Optionally copy the config template to ~/.config/wt-tools/wt-tools.conf.
#
# Usage:
#   bash install.sh              # interactive
#   bash install.sh --yes        # accept all prompts
#   PREFIX=/usr/local/bin bash install.sh --yes
#
# Required deps: bash, git, jq.

set -euo pipefail

YES=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y) YES=1 ;;
    --help|-h) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown arg: $arg" >&2; exit 2 ;;
  esac
done

WT_TOOLS_HOME="$(cd "$(dirname "$0")" && pwd -P)"
PREFIX="${PREFIX:-$HOME/.local/bin}"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
CONFIG_PATH="${CONFIG_PATH:-$HOME/.config/wt-tools/wt-tools.conf}"

# ---- deps ----------------------------------------------------------------
need() {
  command -v "$1" >/dev/null 2>&1 || { echo "install.sh: missing required dep: $1" >&2; exit 1; }
}
need bash
need git
need jq

# ---- ask helper ----------------------------------------------------------
ask() {
  local prompt="$1" default="${2:-y}"
  if (( YES )); then
    echo "  [auto-yes] $prompt"
    return 0
  fi
  local reply
  read -r -p "  $prompt [${default}/n]: " reply
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy] ]]
}

# ---- 1. symlink bin/ -----------------------------------------------------
echo "wt-tools installer"
echo "  WT_TOOLS_HOME: $WT_TOOLS_HOME"
echo "  PREFIX:        $PREFIX"
echo

mkdir -p "$PREFIX"
for script in wt-audit wt-clean; do
  src="$WT_TOOLS_HOME/bin/$script"
  dst="$PREFIX/$script"
  if [[ -L "$dst" ]] && [[ "$(readlink "$dst")" == "$src" ]]; then
    echo "  ok:    $dst -> $src (already linked)"
    continue
  fi
  if [[ -e "$dst" || -L "$dst" ]]; then
    if ask "overwrite existing $dst?"; then
      rm -f "$dst"
    else
      echo "  skip:  $dst (left as-is)"
      continue
    fi
  fi
  ln -s "$src" "$dst"
  echo "  link:  $dst -> $src"
done

# Warn if PREFIX is not on PATH.
case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *)
    echo
    echo "  note:  $PREFIX is not in your PATH. Add this to your shell rc:"
    echo "         export PATH=\"$PREFIX:\$PATH\""
    ;;
esac

# ---- 2. merge hook into settings.json -----------------------------------
echo
if ask "install Claude Code PreToolUse hook into $CLAUDE_SETTINGS?"; then
  fragment_tmp="$(mktemp)"
  sed "s|__WT_TOOLS_HOME__|$WT_TOOLS_HOME|g" "$WT_TOOLS_HOME/hooks/settings.fragment.json" > "$fragment_tmp"

  if [[ -f "$CLAUDE_SETTINGS" ]]; then
    ts="$(date +%Y%m%d-%H%M%S)"
    cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.bak.$ts"
    echo "  backup: $CLAUDE_SETTINGS.bak.$ts"

    merged_tmp="$(mktemp)"
    # Idempotent merge: strip any existing wt-tools hook entries (identified
    # by the `wt-validate-bash` substring in .command — a reliable signal
    # since Claude Code preserves the .command field on round-trip), then
    # concat the fresh set. User's own hooks are preserved.
    jq -s '
      .[0] as $existing | .[1] as $new |
      $existing
      | .hooks //= {}
      | .hooks.PreToolUse //= []
      | .hooks.PreToolUse |= (
          map(
            .hooks |= (map(select(
              ._wt_tools_rule == null
              and ((.command // "") | contains("wt-validate-bash") | not)
            )))
          )
          | map(select(.hooks != null and (.hooks | length) > 0))
        )
      | .hooks.PreToolUse += ($new.hooks.PreToolUse // [])
    ' "$CLAUDE_SETTINGS" "$fragment_tmp" > "$merged_tmp"

    mv "$merged_tmp" "$CLAUDE_SETTINGS"
    echo "  merge: $CLAUDE_SETTINGS (idempotent — existing wt-tools entries replaced)"
  else
    mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
    cp "$fragment_tmp" "$CLAUDE_SETTINGS"
    echo "  write: $CLAUDE_SETTINGS (new file)"
  fi

  rm -f "$fragment_tmp"
else
  echo "  skip: hook not installed."
fi

# ---- 2b. install + patch multi-repo-dispatch skill ----------------------
SKILL_FILE="${SKILL_FILE:-$HOME/.claude/skills/multi-repo-dispatch/SKILL.md}"
SKILL_SOURCE="$WT_TOOLS_HOME/skills/multi-repo-dispatch/SKILL.md"

echo
if [[ ! -f "$SKILL_FILE" ]] && [[ -f "$SKILL_SOURCE" ]]; then
  if ask "install the multi-repo-dispatch skill to $SKILL_FILE?"; then
    mkdir -p "$(dirname "$SKILL_FILE")"
    cp "$SKILL_SOURCE" "$SKILL_FILE"
    echo "  copy: $SKILL_FILE (from $SKILL_SOURCE)"
  else
    echo "  skip: skill not installed."
  fi
fi

# Patch the installed skill's wt-tools link with the detected GitHub owner.
if [[ -f "$SKILL_FILE" ]] && grep -q '<your-fork-owner>' "$SKILL_FILE"; then
  if ask "patch $SKILL_FILE wt-tools link with your GitHub owner?"; then
    OWNER=""
    if command -v gh >/dev/null 2>&1; then
      OWNER="$(gh api user --jq .login 2>/dev/null || true)"
    fi
    if [[ -z "$OWNER" ]]; then
      if (( YES )); then
        echo "  warn: gh not authenticated and --yes passed — leaving placeholder."
        echo "        run install.sh again without --yes (or after 'gh auth login') to patch."
      else
        read -r -p "  GitHub owner (org or username): " OWNER
      fi
    fi
    if [[ -n "$OWNER" ]]; then
      cp "$SKILL_FILE" "$SKILL_FILE.bak.$(date +%Y%m%d-%H%M%S)"
      # sed -i differs between GNU and BSD; use the portable two-arg form.
      sed -i.tmp "s|<your-fork-owner>/wt-tools|$OWNER/wt-tools|g" "$SKILL_FILE"
      rm -f "$SKILL_FILE.tmp"
      echo "  patch: $SKILL_FILE (owner = $OWNER)"
    fi
  else
    echo "  skip: skill file left as-is."
  fi
fi

# ---- 2bb. tracker skill substitutions in the installed skill ------------
if [[ -f "$SKILL_FILE" ]] && grep -q '<tracker-identify-repos>' "$SKILL_FILE"; then
  echo
  echo "Tracker integration"
  echo "  The bundled skill can pick up issues from a tracker (Linear / Jira /"
  echo "  GitHub Issues / etc.) if you have helper skills that talk to it. If you"
  echo "  don't, explicit input mode (\"apply X in repos A, B\") still works."

  TRACKER_IDENTIFY="${WT_TRACKER_IDENTIFY:-}"
  TRACKER_COMMENT="${WT_TRACKER_COMMENT:-}"
  TRACKER_LINK_PRS="${WT_TRACKER_LINK_PRS:-}"

  if (( YES )); then
    if [[ -z "$TRACKER_IDENTIFY$TRACKER_COMMENT$TRACKER_LINK_PRS" ]]; then
      echo "  skip: --yes and no WT_TRACKER_* env vars set. Run tools/configure-tracker.sh later."
    fi
  else
    if ask "configure tracker integration now?"; then
      read -r -p "  Skill name for repo identification (Enter to skip): " TRACKER_IDENTIFY
      read -r -p "  Skill name for issue commenting     (Enter to skip): " TRACKER_COMMENT
      read -r -p "  Skill name for PR linking           (Enter to skip): " TRACKER_LINK_PRS
    else
      echo "  skip: tracker not configured. Run tools/configure-tracker.sh later."
    fi
  fi

  if [[ -n "$TRACKER_IDENTIFY$TRACKER_COMMENT$TRACKER_LINK_PRS" ]]; then
    cp "$SKILL_FILE" "$SKILL_FILE.bak.$(date +%Y%m%d-%H%M%S)"
    [[ -n "$TRACKER_IDENTIFY" ]] && sed -i.tmp "s|<tracker-identify-repos>|$TRACKER_IDENTIFY|g" "$SKILL_FILE"
    [[ -n "$TRACKER_COMMENT" ]]  && sed -i.tmp "s|<tracker-comment>|$TRACKER_COMMENT|g"           "$SKILL_FILE"
    [[ -n "$TRACKER_LINK_PRS" ]] && sed -i.tmp "s|<tracker-link-prs>|$TRACKER_LINK_PRS|g"         "$SKILL_FILE"
    rm -f "$SKILL_FILE.tmp"
    echo "  patch: tracker skills substituted in $SKILL_FILE."
  fi
fi

# ---- 2c. shell completions ----------------------------------------------
echo
if ask "install shell completions (zsh + bash)?"; then
  # bash
  bash_dst="${BASH_COMPLETION_USER_DIR:-$HOME/.local/share/bash-completion/completions}/wt-tools.bash"
  mkdir -p "$(dirname "$bash_dst")"
  cp "$WT_TOOLS_HOME/completions/wt-tools.bash" "$bash_dst"
  echo "  copy: $bash_dst"
  echo "        source from ~/.bashrc:  source \"$bash_dst\""

  # zsh — best-effort placement under ~/.zsh/completions/ (must be on $fpath)
  zsh_dir="$HOME/.zsh/completions"
  mkdir -p "$zsh_dir"
  cp "$WT_TOOLS_HOME/completions/wt-tools.zsh" "$zsh_dir/_wt-tools"
  echo "  copy: $zsh_dir/_wt-tools"
  echo "        add to ~/.zshrc (once):  fpath=(\"$zsh_dir\" \$fpath); autoload -U compinit && compinit"
else
  echo "  skip: completions not installed. Source manually from $WT_TOOLS_HOME/completions/ if desired."
fi

# ---- 3. copy + customize config template --------------------------------
echo
if [[ -f "$CONFIG_PATH" ]]; then
  echo "  ok:   $CONFIG_PATH (already present, not overwriting)"
else
  if ask "copy config template to $CONFIG_PATH?"; then
    mkdir -p "$(dirname "$CONFIG_PATH")"
    cp "$WT_TOOLS_HOME/config/wt-tools.conf.example" "$CONFIG_PATH"
    echo "  copy: $CONFIG_PATH"

    # WT_ROOT is required and has no default — the user picks where their
    # cloned repos live. No probing, no assumed conventions.
    WT_ROOT_VAL="${WT_ROOT:-}"
    if [[ -z "$WT_ROOT_VAL" ]]; then
      if (( YES )); then
        echo "  ERROR: --yes mode requires WT_ROOT env var (the parent dir of your cloned repos)." >&2
        echo "         Example: WT_ROOT=\"\$HOME/code\" bash install.sh --yes" >&2
        exit 1
      fi
      while [[ -z "$WT_ROOT_VAL" ]]; do
        read -r -p "  Where do you keep cloned repos? (required, absolute path): " WT_ROOT_VAL
        [[ -z "$WT_ROOT_VAL" ]] && echo "  (this is required — wt-audit/wt-clean have no sensible default to fall back on)"
      done
    fi
    # Expand ~ if user typed it.
    WT_ROOT_VAL="${WT_ROOT_VAL/#~/$HOME}"

    # Match the empty WT_ROOT="" line in the example template; replace with
    # the user's chosen value. Escape any | in the value for sed safety.
    SAFE_ROOT="${WT_ROOT_VAL//|/\\|}"
    sed -i.tmp "s|^WT_ROOT=\"\"$|WT_ROOT=\"$SAFE_ROOT\"|" "$CONFIG_PATH"
    rm -f "$CONFIG_PATH.tmp"
    echo "        WT_ROOT set to $WT_ROOT_VAL"

    if [[ ! -d "$WT_ROOT_VAL" ]]; then
      echo "  warn: $WT_ROOT_VAL does not exist yet. wt-audit will find no repos until it does."
    fi
  else
    echo "  skip: config not copied. wt-audit and wt-clean will refuse to run"
    echo "        until WT_ROOT is set (in env or a config you write later)."
  fi
fi

# ---- done ----------------------------------------------------------------
echo
echo "wt-tools installed."
echo
echo "Next:"
echo "  - Run:  wt-audit              (read-only inventory of all repos under \$WT_ROOT)"
echo "  - Edit: $CONFIG_PATH"
echo "  - Test the hook in Claude Code by attempting \`gh pr create\` without --draft."
