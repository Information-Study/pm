# cx 的 bash 補全。
# 安裝：cx install（會在 ~/.local/share/bash-completion/completions/ 建 symlink）
# 手動：source /path/to/pm/bin/completion/cx.bash

_cx_completion() {
    local cur prev words cword
    if declare -F _init_completion >/dev/null 2>&1; then
        _init_completion -n : || return
    else
        cur=${COMP_WORDS[COMP_CWORD]}
        prev=${COMP_WORDS[COMP_CWORD-1]}
        words=("${COMP_WORDS[@]}")
        cword=$COMP_CWORD
    fi

    local global_flags='--root --mode --ui --dry-run --yes -y -h --help'
    local verbs='help doctor lint scan git fresh tui install uninstall art composer npm'

    # 先找出動詞的位置（跳過全域旗標與其參數）
    local i=1 verb='' sub='' argn=0
    while (( i < cword )); do
        case ${words[i]} in
            --root|--mode|--ui) ((i+=2)); continue ;;
            --root=*|--mode=*|--ui=*|--dry-run|--yes|-y) ((i++)); continue ;;
            -*) ((i++)); continue ;;
            *)  if [[ -z $verb ]]; then verb=${words[i]}
                elif [[ -z $sub ]]; then sub=${words[i]}; ((argn++))
                else ((argn++)); fi
                ((i++)) ;;
        esac
    done

    # 旗標值
    case $prev in
        # --mode 在 fresh 底下的意義完全不同（備份策略，不是 compose 模式）
        --mode)
            if [[ $verb == fresh ]]; then
                COMPREPLY=($(compgen -W 'backup-only carryover scaffold' -- "$cur"))
            else
                COMPREPLY=($(compgen -W 'dev test prod' -- "$cur"))
            fi
            return ;;
        --ui)   COMPREPLY=($(compgen -W 'whiptail dialog plain' -- "$cur")); return ;;
        --root) COMPREPLY=($(compgen -d -- "$cur")); return ;;
        --runner) COMPREPLY=($(compgen -W 'docker native auto' -- "$cur")); return ;;
        --phase)  COMPREPLY=($(compgen -W 'preflight backup migrate delete all' -- "$cur")); return ;;
        -m|--message) return ;;
    esac

    # 還沒打動詞
    if [[ -z $verb ]]; then
        if [[ $cur == -* ]]; then
            COMPREPLY=($(compgen -W "$global_flags" -- "$cur"))
        else
            COMPREPLY=($(compgen -W "$verbs" -- "$cur"))
        fi
        return
    fi

    # 動詞的子指令與旗標
    case $verb in
        scan)
            if [[ $cur == -* ]]; then
                COMPREPLY=($(compgen -W '--runner --help -h' -- "$cur"))
            elif [[ -z $sub ]]; then
                COMPREPLY=($(compgen -W 'code sast sca dast secrets all' -- "$cur"))
            fi
            ;;
        git)
            if [[ -z $sub ]]; then
                COMPREPLY=($(compgen -W 'status sync commit save branch guard remote-init scan-secrets push' -- "$cur"))
                return
            fi
            case $sub in
                branch)
                    if (( argn == 1 )); then
                        COMPREPLY=($(compgen -W 'list new switch delete' -- "$cur"))
                    elif (( argn == 2 )) && [[ ${words[*]} == *' switch '* || ${words[*]} == *' delete '* ]]; then
                        local root; root=$(_cx_find_root)
                        [[ -n $root ]] && COMPREPLY=($(compgen -W \
                            "$(git -C "$root" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)" \
                            -- "$cur"))
                    fi
                    ;;
                guard)  (( argn == 1 )) && COMPREPLY=($(compgen -W 'install status remove' -- "$cur")) ;;
                commit|save)
                    COMPREPLY=($(compgen -W '-m --message --amend --skip-scan' -- "$cur")) ;;
            esac
            ;;
        fresh)
            COMPREPLY=($(compgen -W '--phase --mode --rollback --from --help -h' -- "$cur"))
            ;;
        lint)
            [[ $cur != -* ]] && COMPREPLY=($(compgen -d -- "$cur")) ;;
        install|uninstall)
            COMPREPLY=($(compgen -W '--rc --help -h' -- "$cur")) ;;
        doctor|help|tui)
            COMPREPLY=($(compgen -W '--help -h' -- "$cur")) ;;
    esac
}

# 向上找 .cxroot（補全時用，不能依賴 cx 已載入）
_cx_find_root() {
    local d=$PWD
    while [[ $d != / ]]; do
        [[ -f $d/.cxroot ]] && { printf '%s\n' "$d"; return 0; }
        d=$(dirname "$d")
    done
    return 1
}

complete -F _cx_completion cx
complete -F _cx_completion ./cx
