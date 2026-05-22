#!/usr/bin/env bash
# configure-tracker.sh — substitute the multi-repo-dispatch skill's tracker
# placeholders with names of skills you have. Safe to run multiple times.
#
# Usage:
#   bash tools/configure-tracker.sh                # interactive
#   WT_TRACKER_IDENTIFY=foo WT_TRACKER_COMMENT=bar WT_TRACKER_LINK_PRS=baz \
#     bash tools/configure-tracker.sh --yes        # non-interactive
#
# Each placeholder is independent: leave any prompt empty (or omit the env
# var) to skip that substitution.

set -euo pipefail

YES=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y) YES=1 ;;
    --help|-h) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "configure-tracker.sh: unknown arg: $arg" >&2; exit 2 ;;
  esac
done

SKILL_FILE="${SKILL_FILE:-$HOME/.claude/skills/multi-repo-dispatch/SKILL.md}"

if [[ ! -f "$SKILL_FILE" ]]; then
  echo "configure-tracker.sh: skill file not found at $SKILL_FILE" >&2
  echo "  Run install.sh first, or set SKILL_FILE to point at your installed copy." >&2
  exit 1
fi

# Inspect remaining placeholders.
remaining=$(grep -oE '<tracker-[a-z-]+>' "$SKILL_FILE" | sort -u | tr '\n' ' ')
if [[ -z "$remaining" ]]; then
  echo "configure-tracker.sh: no <tracker-*> placeholders remain in $SKILL_FILE — nothing to do."
  exit 0
fi
echo "Found placeholders in $SKILL_FILE: $remaining"

TRACKER_IDENTIFY="${WT_TRACKER_IDENTIFY:-}"
TRACKER_COMMENT="${WT_TRACKER_COMMENT:-}"
TRACKER_LINK_PRS="${WT_TRACKER_LINK_PRS:-}"

if (( ! YES )); then
  [[ -z "$TRACKER_IDENTIFY" ]] && read -r -p "Skill name for repo identification (Enter to skip): " TRACKER_IDENTIFY
  [[ -z "$TRACKER_COMMENT" ]]  && read -r -p "Skill name for issue commenting     (Enter to skip): " TRACKER_COMMENT
  [[ -z "$TRACKER_LINK_PRS" ]] && read -r -p "Skill name for PR linking           (Enter to skip): " TRACKER_LINK_PRS
fi

if [[ -z "$TRACKER_IDENTIFY$TRACKER_COMMENT$TRACKER_LINK_PRS" ]]; then
  echo "Nothing to substitute (all values empty). Exiting."
  exit 0
fi

cp "$SKILL_FILE" "$SKILL_FILE.bak.$(date +%Y%m%d-%H%M%S)"
[[ -n "$TRACKER_IDENTIFY" ]] && sed -i.tmp "s|<tracker-identify-repos>|$TRACKER_IDENTIFY|g" "$SKILL_FILE"
[[ -n "$TRACKER_COMMENT" ]]  && sed -i.tmp "s|<tracker-comment>|$TRACKER_COMMENT|g"           "$SKILL_FILE"
[[ -n "$TRACKER_LINK_PRS" ]] && sed -i.tmp "s|<tracker-link-prs>|$TRACKER_LINK_PRS|g"         "$SKILL_FILE"
rm -f "$SKILL_FILE.tmp"

echo "Done. Remaining placeholders:"
grep -oE '<tracker-[a-z-]+>' "$SKILL_FILE" | sort -u | sed 's/^/  /' || echo "  (none)"
