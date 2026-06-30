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

# ---- input + substitution helpers ----------------------------------------
require_absolute() {
  # $1 = value, $2 = label. Returns 0 if absolute, 1 + diagnostic otherwise.
  case "$1" in
    /*) return 0 ;;
    *)  echo "  ERROR: $2 must be an absolute path (got: $1)." >&2; return 1 ;;
  esac
}

sed_escape_replacement() {
  # Escape the chars sed interprets in a replacement string with | delimiter.
  # \ and & are sed-special; | is our chosen delimiter.
  printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

verify_substitution() {
  # $1 = file, $2 = fixed string that must be present after, $3 = label.
  if ! grep -Fq -- "$2" "$1"; then
    echo "  ERROR: $3 substitution did not take effect in $1." >&2
    echo "         Expected to find: $2" >&2
    echo "         (template may have changed shape — file an issue if you reach this)" >&2
    exit 1
  fi
}

verify_placeholder_removed() {
  # $1 = file, $2 = fixed string that must NO LONGER be present, $3 = label.
  if grep -Fq -- "$2" "$1"; then
    echo "  ERROR: $3 substitution did not take effect in $1." >&2
    echo "         Still contains placeholder: $2" >&2
    exit 1
  fi
}

# ---- 1. symlink bin/ -----------------------------------------------------
echo "wt-tools installer"
echo "  WT_TOOLS_HOME: $WT_TOOLS_HOME"
echo "  PREFIX:        $PREFIX"
echo

mkdir -p "$PREFIX"
for script in wt-audit wt-clean wt-link; do
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
      SAFE_OWNER="$(sed_escape_replacement "$OWNER")"
      # sed -i differs between GNU and BSD; use the portable two-arg form.
      sed -i.tmp "s|<your-fork-owner>/wt-tools|$SAFE_OWNER/wt-tools|g" "$SKILL_FILE"
      rm -f "$SKILL_FILE.tmp"
      verify_placeholder_removed "$SKILL_FILE" "<your-fork-owner>/wt-tools" "owner"
      echo "  patch: $SKILL_FILE (owner = $OWNER)"
    fi
  else
    echo "  skip: skill file left as-is."
  fi
fi

# ---- 2bb. tracker skill substitutions in the installed skill ------------
# Gate on ANY tracker placeholder remaining — a previous partial run may
# have substituted some but not others.
if [[ -f "$SKILL_FILE" ]] && grep -qE '<tracker-(identify-repos|comment|link-prs)>' "$SKILL_FILE"; then
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
    if [[ -n "$TRACKER_IDENTIFY" ]]; then
      SAFE="$(sed_escape_replacement "$TRACKER_IDENTIFY")"
      sed -i.tmp "s|<tracker-identify-repos>|$SAFE|g" "$SKILL_FILE"
      verify_placeholder_removed "$SKILL_FILE" "<tracker-identify-repos>" "tracker-identify-repos"
    fi
    if [[ -n "$TRACKER_COMMENT" ]]; then
      SAFE="$(sed_escape_replacement "$TRACKER_COMMENT")"
      sed -i.tmp "s|<tracker-comment>|$SAFE|g" "$SKILL_FILE"
      verify_placeholder_removed "$SKILL_FILE" "<tracker-comment>" "tracker-comment"
    fi
    if [[ -n "$TRACKER_LINK_PRS" ]]; then
      SAFE="$(sed_escape_replacement "$TRACKER_LINK_PRS")"
      sed -i.tmp "s|<tracker-link-prs>|$SAFE|g" "$SKILL_FILE"
      verify_placeholder_removed "$SKILL_FILE" "<tracker-link-prs>" "tracker-link-prs"
    fi
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

# Prompt the user for WT_ROOT (or honor the env var), validate as absolute,
# and rewrite the WT_ROOT=... line in $CONFIG_PATH. The sed pattern matches
# any current value, so this works both for a fresh template (WT_ROOT="")
# and for fixing up an existing config whose WT_ROOT got cleared somehow.
prompt_and_set_wt_root() {
  local val="${WT_ROOT:-}"
  if [[ -z "$val" ]]; then
    if (( YES )); then
      echo "  ERROR: --yes mode requires WT_ROOT env var (the parent dir of your cloned repos)." >&2
      echo "         Example: WT_ROOT=\"\$HOME/code\" bash install.sh --yes" >&2
      exit 1
    fi
    while :; do
      read -r -p "  Where do you keep cloned repos? (required, absolute path): " val
      if [[ -z "$val" ]]; then
        echo "  (this is required — wt-audit/wt-clean have no sensible default to fall back on)"
        continue
      fi
      val="${val/#~/$HOME}"
      require_absolute "$val" "WT_ROOT" || continue
      break
    done
  else
    val="${val/#~/$HOME}"
    require_absolute "$val" "WT_ROOT" || exit 1
  fi

  local safe; safe="$(sed_escape_replacement "$val")"
  # Match any current double-quoted value (including empty).
  sed -i.tmp 's|^WT_ROOT="[^"]*"$|WT_ROOT="'"$safe"'"|' "$CONFIG_PATH"
  rm -f "$CONFIG_PATH.tmp"
  verify_substitution "$CONFIG_PATH" "WT_ROOT=\"$val\"" "WT_ROOT"
  echo "        WT_ROOT set to $val"
  if [[ ! -d "$val" ]]; then
    echo "  warn: $val does not exist yet. wt-audit will find no repos until it does."
  fi
}

if [[ -f "$CONFIG_PATH" ]]; then
  # Config exists — inspect effective WT_ROOT and only update if empty.
  EXISTING_WT_ROOT="$( . "$CONFIG_PATH" 2>/dev/null; printf '%s' "${WT_ROOT:-}" )"
  if [[ -n "$EXISTING_WT_ROOT" ]] && [[ -d "$EXISTING_WT_ROOT" ]]; then
    echo "  ok:   $CONFIG_PATH (WT_ROOT=$EXISTING_WT_ROOT, valid)"
  elif [[ -n "$EXISTING_WT_ROOT" ]]; then
    echo "  warn: $CONFIG_PATH has WT_ROOT=$EXISTING_WT_ROOT, but that directory does not exist."
    echo "        wt-audit will be empty until $EXISTING_WT_ROOT is created (or WT_ROOT is changed)."
  else
    echo "  fix:  $CONFIG_PATH exists but WT_ROOT is empty — let's set it."
    prompt_and_set_wt_root
  fi
else
  if ask "copy config template to $CONFIG_PATH?"; then
    mkdir -p "$(dirname "$CONFIG_PATH")"
    cp "$WT_TOOLS_HOME/config/wt-tools.conf.example" "$CONFIG_PATH"
    echo "  copy: $CONFIG_PATH"
    prompt_and_set_wt_root
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
