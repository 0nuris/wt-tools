#!/usr/bin/env bats
# Tests for tools/uninstall.sh — exercises the reverse-of-install paths
# against fixture artifacts in $BATS_TEST_TMPDIR. Tests never touch the
# real ~/.claude/settings.json or $HOME completions.

load fixtures/setup

# Lay down a complete set of install artifacts in $BATS_TEST_TMPDIR.
# After this call, uninstall.sh has something to actually undo.
wt_install_fixture() {
    wt_setup_fixture

    export FIX_PREFIX="$BATS_TEST_TMPDIR/prefix"
    export FIX_SETTINGS="$BATS_TEST_TMPDIR/settings.json"
    export FIX_CONFIG="$BATS_TEST_TMPDIR/wt-tools.conf"
    export FIX_SKILL="$BATS_TEST_TMPDIR/skills/multi-repo-dispatch/SKILL.md"
    export FIX_FAKE_HOME="$BATS_TEST_TMPDIR/fake-home"
    export FIX_BASH_COMP="$BATS_TEST_TMPDIR/bash-comp"

    mkdir -p "$FIX_PREFIX" "$FIX_FAKE_HOME/.zsh/completions" "$FIX_BASH_COMP" \
             "$(dirname "$FIX_CONFIG")" "$(dirname "$FIX_SKILL")"

    local wt_home; wt_home="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"

    # Symlinks pointing into the real wt-tools/bin — the /wt-tools/ substring
    # check in uninstall.sh's symlink section keys off that path component.
    ln -sf "$wt_home/bin/wt-audit" "$FIX_PREFIX/wt-audit"
    ln -sf "$wt_home/bin/wt-clean" "$FIX_PREFIX/wt-clean"

    # Settings.json with four wt-validate-bash entries. The rule names and the
    # `if` patterns are realistic but only the wt-validate-bash substring
    # actually matters to uninstall.sh's filter.
    cat > "$FIX_SETTINGS" <<EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {"type": "command", "command": "bash $wt_home/bin/wt-validate-bash draft-prs", "if": "Bash(gh pr create*)"},
          {"type": "command", "command": "bash $wt_home/bin/wt-validate-bash no-pr-ready", "if": "Bash(gh pr ready*)"},
          {"type": "command", "command": "bash $wt_home/bin/wt-validate-bash no-pr-merge", "if": "Bash(gh pr merge*)"},
          {"type": "command", "command": "bash $wt_home/bin/wt-validate-bash no-force-remove", "if": "Bash(git worktree remove*)"}
        ]
      }
    ]
  }
}
EOF

    cp "$wt_home/config/wt-tools.conf.example" "$FIX_CONFIG"
    cp "$wt_home/skills/multi-repo-dispatch/SKILL.md" "$FIX_SKILL"
    touch "$FIX_BASH_COMP/wt-tools.bash"
    touch "$FIX_FAKE_HOME/.zsh/completions/_wt-tools"
}

# Set up only the env paths (no artifacts) for "no-install" scenarios.
wt_empty_fixture() {
    wt_setup_fixture
    export FIX_PREFIX="$BATS_TEST_TMPDIR/prefix"
    export FIX_SETTINGS="$BATS_TEST_TMPDIR/settings.json"
    export FIX_CONFIG="$BATS_TEST_TMPDIR/wt-tools.conf"
    export FIX_SKILL="$BATS_TEST_TMPDIR/skills/multi-repo-dispatch/SKILL.md"
    export FIX_FAKE_HOME="$BATS_TEST_TMPDIR/fake-home"
    export FIX_BASH_COMP="$BATS_TEST_TMPDIR/bash-comp"
    mkdir -p "$FIX_PREFIX"
}

# Invoke uninstall.sh with the fixture env. Args forwarded.
run_uninstall() {
    local wt_home; wt_home="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
    HOME="$FIX_FAKE_HOME" \
    BASH_COMPLETION_USER_DIR="$FIX_BASH_COMP" \
    PREFIX="$FIX_PREFIX" \
    CLAUDE_SETTINGS="$FIX_SETTINGS" \
    CONFIG_PATH="$FIX_CONFIG" \
    SKILL_FILE="$FIX_SKILL" \
        bash "$wt_home/tools/uninstall.sh" "$@"
}

# Number of wt-validate-bash entries currently in the fixture settings.json.
hook_count() {
    jq '[.hooks.PreToolUse[]?.hooks[]?.command | select(. != null and contains("wt-validate-bash"))] | length' "$FIX_SETTINGS"
}

# ---- happy path ----------------------------------------------------------

@test "uninstall --yes: strips hook, removes symlinks, keeps config/skill/completions" {
    wt_install_fixture
    [ "$(hook_count)" -eq 4 ]

    run run_uninstall --yes
    [ "$status" -eq 0 ]

    [ "$(hook_count)" -eq 0 ]
    [ ! -L "$FIX_PREFIX/wt-audit" ]
    [ ! -L "$FIX_PREFIX/wt-clean" ]
    [ -f "$FIX_CONFIG" ]
    [ -f "$FIX_SKILL" ]
    [ -f "$FIX_BASH_COMP/wt-tools.bash" ]
    [ -f "$FIX_FAKE_HOME/.zsh/completions/_wt-tools" ]
    ls "$FIX_SETTINGS".bak.* >/dev/null
}

@test "uninstall --yes: idempotent on already-clean state" {
    wt_install_fixture
    run run_uninstall --yes
    [ "$status" -eq 0 ]

    run run_uninstall --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"no wt-tools entries to remove"* ]]
}

@test "uninstall --yes --remove-*: full wipe" {
    wt_install_fixture

    run run_uninstall --yes --remove-config --remove-skill --remove-completions
    [ "$status" -eq 0 ]

    [ ! -f "$FIX_CONFIG" ]
    [ ! -f "$FIX_SKILL" ]
    [ ! -f "$FIX_BASH_COMP/wt-tools.bash" ]
    [ ! -f "$FIX_FAKE_HOME/.zsh/completions/_wt-tools" ]
}

# ---- failure modes -------------------------------------------------------

@test "uninstall --yes: clean exit when no install artifacts exist" {
    wt_empty_fixture

    run run_uninstall --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing to remove"* ]]
}

@test "uninstall --yes: preserves symlink pointing at non-wt-tools binary" {
    wt_install_fixture
    rm "$FIX_PREFIX/wt-audit"
    ln -sf /usr/bin/true "$FIX_PREFIX/wt-audit"

    run run_uninstall --yes
    [ "$status" -eq 0 ]

    [ -L "$FIX_PREFIX/wt-audit" ]
    [ "$(readlink "$FIX_PREFIX/wt-audit")" = "/usr/bin/true" ]
    [[ "$output" == *"not a wt-tools binary"* ]]
}

@test "uninstall: unknown flag exits 2" {
    wt_install_fixture
    run run_uninstall --bogus
    [ "$status" -eq 2 ]
}

@test "uninstall --help: exits 0 and prints usage" {
    wt_install_fixture
    run run_uninstall --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"wt-tools uninstaller"* ]]
}
