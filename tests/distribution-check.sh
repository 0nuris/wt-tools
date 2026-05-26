#!/usr/bin/env bash
# distribution-check.sh — verify wt-tools installs cleanly from a fresh
# extraction with no path leaks from the build/dev environment.
#
# Procedure:
#   1. tar the repo (current dir).
#   2. Extract to /tmp/wt-tools-distcheck-<pid>/.
#   3. Run install.sh with overridden PREFIX, CLAUDE_SETTINGS, CONFIG_PATH so
#      the test does not touch the real install.
#   4. Assert symlinks resolve into the extraction dir (not the source dir).
#   5. Assert settings.json's hook commands reference the extraction dir.
#   6. Assert nothing in the install output mentions the original source path.
#
# Exits 0 on pass, non-zero on any failure.

set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
WORKDIR_RAW="$(mktemp -d -t wt-tools-distcheck-XXXXXX)"
WORKDIR="$(cd "$WORKDIR_RAW" && pwd -P)"   # canonicalize: macOS /var -> /private/var
trap 'rm -rf "$WORKDIR"' EXIT

EXTRACT="$WORKDIR/extracted"
PREFIX="$WORKDIR/prefix"
SETTINGS="$WORKDIR/settings.json"
CONFIG="$WORKDIR/wt-tools.conf"

mkdir -p "$EXTRACT" "$PREFIX"

echo "wt-tools distribution-check"
echo "  source:  $SOURCE_DIR"
echo "  workdir: $WORKDIR"
echo

# --- 1. tar + extract -----------------------------------------------------
echo "[1/7] tar + extract"
( cd "$SOURCE_DIR" && tar -cf "$WORKDIR/wt-tools.tar" \
    --exclude='.git' --exclude='.worktrees' \
    bin hooks config tests completions tools skills install.sh README.md LICENSE )
tar -xf "$WORKDIR/wt-tools.tar" -C "$EXTRACT"
echo "    ok: extracted to $EXTRACT"

# --- 2. run install.sh with overrides ------------------------------------
echo "[2/7] run install.sh"
install_log="$(
  PREFIX="$PREFIX" \
  CLAUDE_SETTINGS="$SETTINGS" \
  CONFIG_PATH="$CONFIG" \
  WT_ROOT="$WORKDIR/repos" \
  bash "$EXTRACT/install.sh" --yes 2>&1
)"
echo "    ok: install completed"

# --- 3. symlinks resolve to extraction dir -------------------------------
echo "[3/7] symlinks resolve to extraction dir"
for s in wt-audit wt-clean; do
  target="$(readlink "$PREFIX/$s")"
  if [[ "$target" != "$EXTRACT/bin/$s" ]]; then
    echo "    FAIL: $PREFIX/$s -> $target (expected $EXTRACT/bin/$s)" >&2
    exit 1
  fi
done
echo "    ok: both symlinks point into $EXTRACT"

# --- 4. settings.json hook commands reference extraction dir -------------
echo "[4/7] settings.json hook commands reference extraction dir"
if ! jq -e --arg ex "$EXTRACT" '
  [.hooks.PreToolUse[].hooks[].command]
  | all(. | contains($ex))
' "$SETTINGS" >/dev/null; then
  echo "    FAIL: at least one hook command does not reference $EXTRACT" >&2
  echo "    Settings hook commands:" >&2
  jq '.hooks.PreToolUse[].hooks[].command' "$SETTINGS" >&2
  exit 1
fi
echo "    ok: all hook commands reference $EXTRACT"

# --- 5. no path leaks from SOURCE_DIR ------------------------------------
echo "[5/7] no SOURCE_DIR path leaks in install artifacts"
leak_found=0
for f in "$SETTINGS" "$CONFIG" "$PREFIX/wt-audit" "$PREFIX/wt-clean"; do
  if [[ -f "$f" || -L "$f" ]]; then
    if grep -F "$SOURCE_DIR" "$f" 2>/dev/null; then
      echo "    FAIL: $f contains SOURCE_DIR" >&2
      leak_found=1
    fi
  fi
done
if echo "$install_log" | grep -F "$SOURCE_DIR" >/dev/null; then
  # Install log mentioning the source dir is OK when the source dir
  # equals the extracted dir (which it doesn't here, by construction).
  echo "    FAIL: install output contains SOURCE_DIR" >&2
  leak_found=1
fi
(( leak_found )) && exit 1
echo "    ok: no SOURCE_DIR references found"

# --- 6. scripts execute from new prefix ---------------------------------
echo "[6/7] symlinked scripts execute and source the test config"
WT_TOOLS_CONFIG="$CONFIG" \
WT_ROOT="$WORKDIR" \
bash "$PREFIX/wt-audit" >/dev/null 2>&1 || {
  echo "    FAIL: wt-audit failed to run from prefix" >&2
  exit 1
}
echo "    ok: wt-audit runs from $PREFIX"

# --- 7. tools/ and skills/ landed in the tar -----------------------------
echo "[7/7] tar includes tools/ and skills/"
missing=0
for path in tools/uninstall.sh tools/doctor.sh tools/configure-tracker.sh tools/publish.sh skills/multi-repo-dispatch/SKILL.md; do
  if [[ ! -e "$EXTRACT/$path" ]]; then
    echo "    FAIL: $path missing from extracted tar" >&2
    missing=$((missing + 1))
  fi
done
(( missing )) && exit 1
echo "    ok: tools/ and skills/ both present"

echo
echo "distribution check PASSED"
