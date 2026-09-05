# cx 的 bash 補全。
# 安裝：cx install（會在 ~/.local/share/bash-completion/completions/ 建 symlink）
# 手動：source /path/to/pm/bin/completion/cx.bash


# shellcheck disable=SC2207
#   COMPREPLY=($(compgen -W …)) 是 bash-completion 的標準寫法，全檔 34 處。
#   SC2207 建議改用 mapfile，但那在補全腳本裡沒有好處（compgen 的輸出本來就
#   是要按 IFS 分詞的），而且會讓這個檔案與所有參考資料長得不一樣。
#   關掉這一條，其餘的 shellcheck 檢查仍然生效 —— 這個檔案是
#   cx lint sh 的檢查範圍（2026-09-05 起）。
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

    local global_flags='--root --mode --ui --runner --dry-run --yes -y -h --help'
    # 這份清單就是「cx 到底做得到什麼」的權威來源之一 ——
    # 新增動詞時六個地方要一起改：bin/cmd/<verb>.sh、cx 的 CX_CMD_FILE_OF
    #（只有檔名與動詞不同名時才需要）、這裡、以及 bin/cmd/help.sh。
    local verbs='help doctor setup acl lint style scan verify git fresh rename init re-init tui install uninstall code pma open status php
                 art composer npm db test sonar deploy
                 dev prod up down restart ps logs sh build config dc'

    # 先找出動詞的位置（跳過全域旗標與其參數）
    local i=1 verb='' sub='' argn=0
    while (( i < cword )); do
        case ${words[i]} in
            --root|--mode|--ui|--runner) ((i+=2)); continue ;;
            --root=*|--mode=*|--ui=*|--runner=*|--dry-run|--yes|-y) ((i++)); continue ;;
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
                COMPREPLY=($(compgen -W 'backup-only git-only carryover scaffold' -- "$cur"))
            else
                COMPREPLY=($(compgen -W 'dev test prod' -- "$cur"))
            fi
            return ;;
        --ui)   COMPREPLY=($(compgen -W 'whiptail dialog plain' -- "$cur")); return ;;
        --root) COMPREPLY=($(compgen -d -- "$cur")); return ;;
        --runner) COMPREPLY=($(compgen -W 'docker native auto' -- "$cur")); return ;;
        --phase)  COMPREPLY=($(compgen -W 'preflight backup migrate delete rebuild verify git-init all' -- "$cur")); return ;;
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
        setup)
            # 第一層是子指令；第二層起是工具名，而工具名分屬 tools / system 兩份清單。
            # 舊版寫成 case $verb in setup_tools_names) / system) —— 那兩個分支永遠
            # 匹配不到（$verb 是頂層動詞，不可能等於這些字串），等於沒有補全。
            if [[ -z $sub ]]; then
                COMPREPLY=($(compgen -W "all native env dirs guard tools system deps --help -h" -- "$cur"))
            else
                case $sub in
                    tools)  COMPREPLY=($(compgen -W "composer node ansible trivy gitleaks semgrep shellcheck bats" -- "$cur")) ;;
                    system) COMPREPLY=($(compgen -W "php nginx git docker mysql-client php-sqlite acl jq" -- "$cur")) ;;
                    native) COMPREPLY=($(compgen -W "php nginx git docker mysql-client php-sqlite acl jq" -- "$cur")) ;;
                esac
            fi
            ;;
        acl)
            # acl 早就在上面的 $verbs 裡（所以 `cx a<TAB>` 補得出 acl），
            # 但這裡一直沒有分支，於是 `cx acl <TAB>` 什麼都不給。
            if [[ $sub == user ]]; then
                COMPREPLY=($(compgen -W "add rm remove" -- "$cur"))
            else
                COMPREPLY=($(compgen -W "status apply check user fix-owner drop --web-user --dev-user --help -h" -- "$cur"))
            fi
            ;;
        style)
            COMPREPLY=($(compgen -W "php js all --check --help -h" -- "$cur")) ;;
        open)
            COMPREPLY=($(compgen -W "front back api pma sonar list --url --no-open --help -h" -- "$cur")) ;;
        status)
            COMPREPLY=($(compgen -W "--short --json --help -h" -- "$cur")) ;;
        db)
            COMPREPLY=($(compgen -W "status shell wait migrate fresh seed dump restore admin --help -h" -- "$cur")) ;;
        sonar)
            COMPREPLY=($(compgen -W "up down status logs token url wait --help -h" -- "$cur")) ;;
        deploy)
            COMPREPLY=($(compgen -W "syntax lint check ping facts vars apply app rollback galaxy hosts --help -h" -- "$cur")) ;;
        verify)
            COMPREPLY=($(compgen -W "static runtime app ansible cli docs tui waf acl all --report --quiet --help -h" -- "$cur")) ;;
        test)
            COMPREPLY=($(compgen -W "cli back front all coverage larastan up down restart ps logs sh build config dc --help -h" -- "$cur")) ;;
        dev|prod|up|down|restart|ps|logs|sh|build|config|dc)
            COMPREPLY=($(compgen -W "up down restart ps logs sh build config dc -d --build --no-cache -f -v --help -h" -- "$cur")) ;;
        scan)
            if [[ $cur == -* ]]; then
                COMPREPLY=($(compgen -W '--runner --help -h' -- "$cur"))
            elif [[ -z $sub ]]; then
                COMPREPLY=($(compgen -W 'code sast sca dast secrets all' -- "$cur"))
            fi
            ;;
        git)
            if [[ -z $sub ]]; then
                COMPREPLY=($(compgen -W 'status fetch pull sync commit save branch feature hotfix release flow-init config guard remote-init remote-set scan-secrets push' -- "$cur"))
                return
            fi
            case $sub in
                branch)
                    if (( argn == 1 )); then
                        COMPREPLY=($(compgen -W 'list new switch delete --repo --from' -- "$cur"))
                    elif (( argn == 2 )) && [[ ${words[*]} == *' switch '* || ${words[*]} == *' delete '* ]]; then
                        local root; root=$(_cx_find_root)
                        [[ -n $root ]] && COMPREPLY=($(compgen -W \
                            "$(git -C "$root" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)" \
                            -- "$cur"))
                    fi
                    ;;
                feature|hotfix)
                    # 兩者共用同一組子指令與旗標 —— 它們是同一支實作
                    #（_git_flow_line），差別只有分支前綴。
                    if (( argn == 1 )); then
                        COMPREPLY=($(compgen -W 'start finish list' -- "$cur"))
                    else
                        COMPREPLY=($(compgen -W '--repo' -- "$cur"))
                    fi
                    ;;
                release) COMPREPLY=($(compgen -W '--skip-scan' -- "$cur")) ;;
                guard)  (( argn == 1 )) && COMPREPLY=($(compgen -W 'install status remove' -- "$cur")) ;;
                commit|save)
                    COMPREPLY=($(compgen -W '-m --message --amend --skip-scan --repo' -- "$cur")) ;;
                pull)
                    COMPREPLY=($(compgen -W '--ff-only --allow-merge' -- "$cur")) ;;
                push)
                    COMPREPLY=($(compgen -W '--force' -- "$cur")) ;;
            esac
            ;;
        fresh)
            COMPREPLY=($(compgen -W '--phase --mode --rollback --resume-from --from --help -h' -- "$cur"))
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
