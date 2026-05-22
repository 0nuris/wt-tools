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
    # Idempotent merge: strip any existing wt-tools-tagged hook entries
    # (identified by the `_wt_tools_rule` marker on each inner hook), then
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

# ---- 3. copy config template --------------------------------------------
echo
if [[ -f "$CONFIG_PATH" ]]; then
  echo "  ok:   $CONFIG_PATH (already present, not overwriting)"
else
  if ask "copy config template to $CONFIG_PATH?"; then
    mkdir -p "$(dirname "$CONFIG_PATH")"
    cp "$WT_TOOLS_HOME/config/wt-tools.conf.example" "$CONFIG_PATH"
    echo "  copy: $CONFIG_PATH"
  else
    echo "  skip: config not copied (defaults will apply)."
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
