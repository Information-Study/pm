#!/usr/bin/env bash
# cx tui — 無參數執行 cx 時的圖形化選單。
#
# ⚠ 關鍵設計（對抗驗證的實測結果）：
#   選單執行動詞時**必須開真正的子行程**，不能用 `cx_dispatch ... || true`。
#   實測 bash 5.3.9：把函式放在 || 左邊會讓「整個函式本體」的 errexit 失效，
#   包 subshell 也救不回來。後果是從選單執行 cx db restore 時，
#   解壓失敗後仍會繼續匯入並印出成功橫幅。
#
#   另外 whiptail 無法串流長指令的輸出，所以執行動詞時要「退出對話框」，
#   讓輸出直接走終端機，跑完再按鍵回選單。

_tui_need_tty() {
    cx_interactive && return 0
    cx_error "cx 的選單需要終端機（TTY）"
    cx_dim "  目前偵測到：CX_UI=$CX_UI、fd8 $( [[ -t 8 ]] && echo 是 || echo 否 ) TTY"
    cx_dim "  非互動環境請直接給動詞，例如： cx doctor / cx scan all / cx git status"
    cx_dim "  可用動詞： cx help"
    return 1
}

# 以真正的子行程執行動詞 —— 這是本檔最重要的一行
_tui_run() {
    local -a argv=("$@")
    (( ${#argv[@]} )) || return 0
    printf '\n\033[34m▸ cx %s\033[0m\n\n' "$(cx_q "${argv[@]}")" >&8
    local rc=0
    "$CX_ROOT/cx" --ui plain "${argv[@]}" </dev/tty >&8 2>&9 || rc=$?
    if (( rc )); then
        printf '\n\033[31m✘ cx %s 結束於 exit %d\033[0m\n' "${argv[0]}" "$rc" >&9
    else
        printf '\n\033[32m✔ 完成\033[0m\n' >&8
    fi
    printf '\n按任意鍵回到選單…' >&8
    read -rsn1 </dev/tty || true
    printf '\n' >&8
    return 0
}

_tui_menu() {                       # _tui_menu <title> <back-label> <tag> <desc> ...
    local title=$1 back=$2; shift 2
    local f; f=$(mktemp)
    local -a items=("$@") ; items+=("<" "$back")
    if _cx_dlg --title "$title" --cancel-button "離開" \
            --menu "\n選擇一項：" 22 76 12 "${items[@]}" 2>"$f" 1>&8; then
        cat "$f"; rm -f "$f"; return 0
    fi
    rm -f "$f"; return 1
}

_tui_scan() {
    local c
    while c=$(_tui_menu "DevSecOps — 四道防線" "返回" \
        all     "全部依序執行" \
        code    "① Quality  Larastan + SonarQube" \
        sast    "② SAST     Semgrep" \
        sca     "③ SCA      Trivy + composer/npm audit" \
        dast    "④ DAST     OWASP ZAP" \
        secrets "祕密掃描  gitleaks（含 git 歷史）"); do
        [[ $c == '<' ]] && return 0
        _tui_run scan "$c"
    done
}

_tui_git() {
    local c
    while c=$(_tui_menu "Git" "返回" \
        status   "三個 repo 的狀態" \
        sync     "子模組 checkout 追蹤分支" \
        branch   "分支：列出／建立／切換" \
        commit   "提交（子模組先、主庫後）" \
        guard    "push guard 狀態" \
        scan     "推送前祕密掃描"); do
        case $c in
            '<')    return 0 ;;
            guard)  _tui_run git guard status ;;
            scan)   _tui_run git scan-secrets ;;
            branch) _tui_git_branch ;;
            commit) _tui_git_commit ;;
            *)      _tui_run git "$c" ;;
        esac
    done
}

_tui_git_branch() {
    local c
    while c=$(_tui_menu "分支" "返回" \
        list   "列出所有 repo 的分支" \
        new    "建立新分支（三個 repo 一起）" \
        switch "切換分支"); do
        case $c in
            '<') return 0 ;;
            list) _tui_run git branch list ;;
            new)
                local f n; f=$(mktemp)
                _cx_dlg --title "建立新分支" --inputbox \
                    "\n分支名稱（會在三個 repo 同時建立）：\n\n慣例：feat/xxx、fix/xxx、chore/xxx" \
                    14 70 "" 2>"$f" 1>&8 || { rm -f "$f"; continue; }
                n=$(<"$f"); rm -f "$f"
                [[ -n $n ]] && _tui_run git branch new "$n"
                ;;
            switch)
                local -a br=(); local b f
                # 只列「三個 repo 都有」的分支 —— _git_branch_switch 要求三者皆存在，
                # 只列主庫的話使用者會選到一個註定失敗的分支。
                # 結尾的 || true 是必要的：<(...) 子 shell 裡 errexit 仍有效。
                while read -r b; do
                    [[ -n $b ]] || continue
                    git -C "$CX_ROOT/backend"  show-ref --verify --quiet "refs/heads/$b" || continue
                    git -C "$CX_ROOT/frontend" show-ref --verify --quiet "refs/heads/$b" || continue
                    br+=("$b" "三個 repo 皆有")
                done < <(git -C "$CX_ROOT" for-each-ref --format='%(refname:short)' refs/heads/ \
                         2>/dev/null || true)
                (( ${#br[@]} )) || { cx_msg "切換分支" "主庫沒有任何分支。"; continue; }
                f=$(mktemp)
                if _cx_dlg --title "切換分支" --menu "\n選擇要切換到的分支：" 20 70 10 \
                        "${br[@]}" 2>"$f" 1>&8; then
                    b=$(<"$f"); rm -f "$f"; _tui_run git branch switch "$b"
                else rm -f "$f"; fi
                ;;
        esac
    done
}

_tui_git_commit() {
    local f type scope subject
    f=$(mktemp)
    if ! _cx_dlg --title "提交 — 類型" --menu "\n選擇變更類型（Conventional Commits）：" 20 72 10 \
        feat     "新功能" \
        fix      "修正缺陷" \
        docs     "文件" \
        refactor "重構（不改行為）" \
        perf     "效能" \
        test     "測試" \
        build    "建置／相依" \
        ci       "CI 設定" \
        chore    "雜項" 2>"$f" 1>&8; then rm -f "$f"; return 0; fi
    type=$(<"$f")
    _cx_dlg --title "提交 — 範圍" --inputbox \
        "\n影響範圍（可留空）：\n\n例如 backend / frontend / docker / ansible / cx" \
        13 70 "" 2>"$f" 1>&8 || { rm -f "$f"; return 0; }
    scope=$(<"$f")
    _cx_dlg --title "提交 — 摘要" --inputbox \
        "\n一行摘要（祈使句，不加句號）：" 12 76 "" 2>"$f" 1>&8 || { rm -f "$f"; return 0; }
    subject=$(<"$f"); rm -f "$f"
    [[ -n $subject ]] || { cx_msg "提交" "摘要不可為空，已取消。"; return 0; }

    local msg="$type"
    [[ -n $scope ]] && msg="$msg($scope)"
    msg="$msg: $subject"
    cx_confirm "確認提交" "訊息：\n\n  $msg\n\n會依序提交子模組，最後提交主庫的 gitlink。" \
        && _tui_run git commit -m "$msg"
}

_tui_env() {
    local c
    while c=$(_tui_menu "環境" "返回" \
        doctor "檢查工具鏈與阻擋項目" \
        lint   "Ansible 靜態檢查" \
        status "三個 repo 的狀態"); do
        case $c in
            '<')    return 0 ;;
            status) _tui_run git status ;;
            *)      _tui_run "$c" ;;
        esac
    done
}

cmd_tui_main() {
    _tui_need_tty || return "$EX_PRECOND"
    local c
    while c=$(_tui_menu "cx — pm 專案管理  [模式：${CX_MODE}]" "離開" \
        env   "環境：doctor / lint / 狀態" \
        git   "Git：狀態 / 分支 / 提交 / guard" \
        scan  "DevSecOps：四道防線" \
        help  "指令說明"); do
        case $c in
            '<')  break ;;
            env)  _tui_env ;;
            git)  _tui_git ;;
            scan) _tui_scan ;;
            help) _tui_run help ;;
        esac
    done
    printf '\n' >&8
    return 0
}
