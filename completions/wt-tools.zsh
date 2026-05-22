#compdef wt-audit wt-clean
# zsh completion for wt-audit and wt-clean.
# Source from your ~/.zshrc, or copy to a dir on $fpath:
#   source /path/to/wt-tools/completions/wt-tools.zsh

_wt_audit() {
    _arguments \
        '--repo[restrict to a single repo]:repo name:_path_files -/' \
        '--root[parent dir containing repos]:dir:_path_files -/' \
        '--stale-days[mark rows older than N days as stale]:days:' \
        '--json[machine-readable output]' \
        '--filter[restrict to candidate set]:filter:(removable)' \
        '(--help -h)'{--help,-h}'[show help]'
}

_wt_clean() {
    _arguments \
        '--apply[required to perform removals; dry-run by default]' \
        '--repo[restrict to a single repo]:repo name:_path_files -/' \
        '--root[parent dir containing repos]:dir:_path_files -/' \
        '--stale-days[stale threshold in days]:days:' \
        '--include-detached[include detached-HEAD worktrees]' \
        '--include-sibling-dirs[include worktrees outside .worktrees/]' \
        '--force[allow removal of dirty worktrees]' \
        '--also-delete-branch[delete the branch after removing the worktree]' \
        '--force-delete-branch[force-delete the branch (-D) after remove]' \
        '(--help -h)'{--help,-h}'[show help]'
}

compdef _wt_audit wt-audit
compdef _wt_clean wt-clean
