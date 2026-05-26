#!/usr/bin/env bash
# wt-tools uninstaller — idempotent reverse of install.sh.
#
# Steps (in order):
#   1. Strip wt-tools entries from ~/.claude/settings.json (timestamped .bak first).
#   2. Remove symlinks from $PREFIX (only if they point into a wt-tools/ dir).
#   3. Optionally remove the config, skill, and completions.
#
# Conservative by default: in --yes mode, config/skill/completions are KEPT
# unless --remove-config / --remove-skill / --remove-completions is passed.
#
# Usage:
#   bash uninstall.sh                                              # interactive
#   bash uninstall.sh --yes                                        # strip hook + symlinks only
#   bash uninstall.sh --yes --remove-config --remove-skill --remove-completions
#
# Env overrides (same names as install.sh):
#   PREFIX, CLAUDE_SETTINGS, CONFIG_PATH, SKILL_FILE
#
# Required deps: bash, jq.

set -euo pipefail

YES=0
REMOVE_CONFIG=0
REMOVE_SKILL=0
REMOVE_COMPLETIONS=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y) YES=1 ;;
    --remove-config) REMOVE_CONFIG=1 ;;
    --remove-skill) REMOVE_SKILL=1 ;;
    --remove-completions) REMOVE_COMPLETIONS=1 ;;
    --help|-h) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "uninstall.sh: unknown arg: $arg" >&2; exit 2 ;;
  esac
done

PREFIX="${PREFIX:-$HOME/.local/bin}"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
CONFIG_PATH="${CONFIG_PATH:-$HOME/.config/wt-tools/wt-tools.conf}"
SKILL_FILE="${SKILL_FILE:-$HOME/.claude/skills/multi-repo-dispatch/SKILL.md}"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "uninstall.sh: missing required dep: $1" >&2; exit 1; }
}
need bash
need jq

ask() {
  local prompt="$1" default="${2:-n}"
  if (( YES )); then
    echo "  [auto-no] $prompt (use --remove-* flag to opt in)"
    return 1
  fi
  local hint="y/N"
  [[ "$default" == "y" ]] && hint="Y/n"
  local reply
  read -r -p "  $prompt [$hint]: " reply
  reply="${reply:-$default}"
  [[ "$reply" =~ ^[Yy] ]]
}

echo "wt-tools uninstaller"
echo "  PREFIX:          $PREFIX"
echo "  CLAUDE_SETTINGS: $CLAUDE_SETTINGS"
echo "  CONFIG_PATH:     $CONFIG_PATH"
echo "  SKILL_FILE:      $SKILL_FILE"
echo

# Outcomes for the summary.
removed_hook=0
removed_links=()
removed_config=0
removed_skill=0
removed_completions=0
kept_paths=()
new_settings_bak=""

# ---- 1. strip wt-tools hook entries from settings.json ------------------
echo "hook:"
if [[ -f "$CLAUDE_SETTINGS" ]]; then
  count_before=$(jq '
    [.hooks.PreToolUse[]?.hooks[]?.command
      | select(. != null and contains("wt-validate-bash"))] | length
  ' "$CLAUDE_SETTINGS")
  if (( count_before > 0 )); then
    ts="$(date +%Y%m%d-%H%M%S)"
    new_settings_bak="$CLAUDE_SETTINGS.bak.$ts"
    cp "$CLAUDE_SETTINGS" "$new_settings_bak"
    echo "  backup: $new_settings_bak"

    merged_tmp="$(mktemp)"
    # Same wt-validate-bash substring filter install.sh uses to identify
    # wt-tools entries — survives Claude Code settings round-trips.
    jq '
      .hooks //= {}
      | .hooks.PreToolUse //= []
      | .hooks.PreToolUse |= (
          map(
            .hooks |= (map(select(
              ((.command // "") | contains("wt-validate-bash")) | not
            )))
          )
          | map(select(.hooks != null and (.hooks | length) > 0))
        )
    ' "$CLAUDE_SETTINGS" > "$merged_tmp"
    mv "$merged_tmp" "$CLAUDE_SETTINGS"
    echo "  strip:  $count_before wt-tools entry(ies) removed from $CLAUDE_SETTINGS"
    removed_hook=1
  else
    echo "  ok: no wt-tools entries to remove."
  fi
else
  echo "  skip: $CLAUDE_SETTINGS not present."
fi

# ---- 2. remove symlinks --------------------------------------------------
echo
echo "bin:"
for s in wt-audit wt-clean; do
  dst="$PREFIX/$s"
  if [[ -L "$dst" ]]; then
    target="$(readlink "$dst")"
    case "$target" in
      */wt-tools/*)
        rm -f "$dst"
        echo "  remove: $dst (-> $target)"
        removed_links+=("$dst")
        ;;
      *)
        echo "  skip:   $dst (-> $target, not a wt-tools binary)"
        kept_paths+=("$dst")
        ;;
    esac
  elif [[ -e "$dst" ]]; then
    echo "  skip:   $dst (regular file, not a symlink)"
    kept_paths+=("$dst")
  else
    echo "  ok:     $dst (not present)"
  fi
done

# ---- 3. optionally remove config ----------------------------------------
echo
echo "config:"
if [[ -f "$CONFIG_PATH" ]]; then
  if (( REMOVE_CONFIG )) || ask "remove $CONFIG_PATH?"; then
    rm -f "$CONFIG_PATH"
    echo "  remove: $CONFIG_PATH"
    removed_config=1
    rmdir "$(dirname "$CONFIG_PATH")" 2>/dev/null || true
  else
    echo "  keep:   $CONFIG_PATH"
    kept_paths+=("$CONFIG_PATH")
  fi
else
  echo "  ok: $CONFIG_PATH not present."
fi

# ---- 4. optionally remove skill ----------------------------------------
echo
echo "skill:"
if [[ -f "$SKILL_FILE" ]]; then
  if (( REMOVE_SKILL )) || ask "remove $SKILL_FILE? (may contain your customizations; .bak files in the same dir remain)"; then
    rm -f "$SKILL_FILE"
    echo "  remove: $SKILL_FILE"
    removed_skill=1
    rmdir "$(dirname "$SKILL_FILE")" 2>/dev/null || true
  else
    echo "  keep:   $SKILL_FILE"
    kept_paths+=("$SKILL_FILE")
  fi
else
  echo "  ok: $SKILL_FILE not present."
fi

# ---- 5. optionally remove completions ----------------------------------
echo
echo "completions:"
bash_dst="${BASH_COMPLETION_USER_DIR:-$HOME/.local/share/bash-completion/completions}/wt-tools.bash"
zsh_dst="$HOME/.zsh/completions/_wt-tools"
any_present=0
[[ -f "$bash_dst" ]] && any_present=1
[[ -f "$zsh_dst" ]]  && any_present=1
if (( any_present )); then
  if (( REMOVE_COMPLETIONS )) || ask "remove shell completion files?"; then
    [[ -f "$bash_dst" ]] && { rm -f "$bash_dst"; echo "  remove: $bash_dst"; }
    [[ -f "$zsh_dst" ]]  && { rm -f "$zsh_dst";  echo "  remove: $zsh_dst"; }
    removed_completions=1
  else
    [[ -f "$bash_dst" ]] && { echo "  keep:   $bash_dst"; kept_paths+=("$bash_dst"); }
    [[ -f "$zsh_dst" ]]  && { echo "  keep:   $zsh_dst";  kept_paths+=("$zsh_dst"); }
  fi
else
  echo "  ok: no completion files present."
fi

# ---- summary ------------------------------------------------------------
echo
echo "summary:"
removed_anything=0
if (( removed_hook )); then
  echo "  - settings.json: wt-tools hook entries stripped"
  echo "    rollback: cp \"$new_settings_bak\" \"$CLAUDE_SETTINGS\""
  removed_anything=1
fi
if [[ ${#removed_links[@]} -gt 0 ]]; then
  echo "  - symlinks removed:"
  for l in "${removed_links[@]}"; do echo "      $l"; done
  removed_anything=1
fi
(( removed_config ))      && { echo "  - config removed";      removed_anything=1; }
(( removed_skill ))       && { echo "  - skill removed";       removed_anything=1; }
(( removed_completions )) && { echo "  - completions removed"; removed_anything=1; }
(( removed_anything ))    || echo "  - nothing to remove (already uninstalled)"

if [[ ${#kept_paths[@]} -gt 0 ]]; then
  echo "  kept:"
  for p in "${kept_paths[@]}"; do echo "    $p"; done
fi

echo
echo "wt-tools uninstall complete."
