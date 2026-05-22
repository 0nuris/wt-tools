# Bash completion for wt-audit and wt-clean.
# Source from your ~/.bashrc:
#   source /path/to/wt-tools/completions/wt-tools.bash

_wt_audit() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    opts="--repo --root --stale-days --json --filter --help -h"

    case "$prev" in
        --filter)
            COMPREPLY=( $(compgen -W "removable" -- "$cur") )
            return 0
            ;;
        --root|--repo)
            COMPREPLY=( $(compgen -d -- "$cur") )
            return 0
            ;;
        --stale-days)
            return 0
            ;;
    esac

    if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
    fi
}

_wt_clean() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    opts="--apply --repo --root --stale-days --include-detached --include-sibling-dirs --force --also-delete-branch --force-delete-branch --help -h"

    case "$prev" in
        --root|--repo)
            COMPREPLY=( $(compgen -d -- "$cur") )
            return 0
            ;;
        --stale-days)
            return 0
            ;;
    esac

    if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "$opts" -- "$cur") )
    fi
}

complete -F _wt_audit wt-audit
complete -F _wt_clean wt-clean
