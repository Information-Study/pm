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

# 選單的「目前狀態」。這兩個值會被帶進每一次執行 ——
# 沒有它們的話，選單標題印著 [模式：dev] 但實際上每個子行程都用預設值，
# 使用者以為自己切了模式，其實沒有。
_TUI_MODE=${CX_MODE:-dev}
_TUI_RUNNER=${CX_RUNNER:-auto}

# 退出碼 → 人看得懂的意思。
# 這張表跟 bin/lib/common.sh 的 readonly EX_* 是同一組值；
# 失敗對話框只印數字的話，使用者還是不知道 3 跟 1 差在哪。
_tui_rc_meaning() {                 # _tui_rc_meaning <rc>
    case ${1:-} in
        1)  printf '一般失敗（EX_FAIL）—— 真的有問題' ;;
        2)  printf '用法錯誤（EX_USAGE）—— 參數或子指令給錯了' ;;
        3)  printf '前置條件不足（EX_PRECOND）—— 環境缺東西，不是程式有問題' ;;
        4)  printf '使用者取消（EX_ABORT）' ;;
        20) printf '① 品質防線有 finding（EX_SCAN_QUALITY）' ;;
        21) printf '② SAST 有 finding（EX_SCAN_SAST）' ;;
        22) printf '③ SCA 有 finding（EX_SCAN_SCA）' ;;
        23) printf '④ DAST 有 finding（EX_SCAN_DAST）' ;;
        130) printf '被 Ctrl-C 中斷' ;;
        *)  printf '未分類的退出碼' ;;
    esac
}

# 失敗時把結果**留在畫面上**。
#
# ⚠ 為什麼一定要用對話框，而不是只 printf：
#   whiptail 用的是終端機的 alternate screen buffer（實測：進場送
#   \033[?1049h、離場送 \033[?1049l）。_tui_run 把輸出印在**主畫面**，
#   然後回到選單時 whiptail 又切進 alternate buffer 把它蓋掉 ——
#   使用者的感受就是「執行失敗，但沒有任何錯誤訊息」。
#   把錯誤放進 msgbox，它就跟選單在同一個 buffer 裡，蓋不掉。
_tui_show_failure() {               # _tui_show_failure <指令> <rc> <log 檔>
    local what=$1 rc=$2 log=$3 tail_txt=''
    [[ -s $log ]] && tail_txt=$(tail -n 18 "$log" \
        | sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\r$//')
    local body
    body="指令：cx $what

結束於 exit $rc —— $(_tui_rc_meaning "$rc")
"
    if [[ -n $tail_txt ]]; then
        body+="
最後 18 行輸出：
------------------------------------------------------------
$tail_txt"
    else
        body+="
（這個指令沒有任何輸出）"
    fi
    if cx_interactive; then
        _cx_dlg --title "✘ 執行失敗（exit $rc）" --scrolltext \
            --msgbox "$body" 24 92 1>&8 2>&9 || true
    else
        printf '%s\n' "$body" >&9
    fi
}

# 以真正的子行程執行動詞 —— 這是本檔最重要的一行
_tui_run() {
    local -a argv=("$@")
    (( ${#argv[@]} )) || return 0
    printf '\n\033[34m▸ cx --mode %s --runner %s %s\033[0m\n\n' \
        "$_TUI_MODE" "$_TUI_RUNNER" "$(cx_q "${argv[@]}")" >&8
    # 同時**串流到終端機**與存進 log：串流是為了長指令看得到進度，
    # 存檔是為了失敗時還能把內容放進對話框（printf 到主畫面會被選單蓋掉）。
    #
    # ⚠ 不能用 `… 2>&1 | tee log`。管線會讓子行程的 stdout/stderr 都變成 pipe，
    #   而 bin/lib/common.sh 的顏色是看 `[[ -t 2 ]]` 決定的 —— 於是選單裡跑出來的
    #   每一個指令都會失去紅✘綠✔，反而更難看出哪裡失敗；composer / npm /
    #   docker compose 也會切到「非互動」分支，長指令的進度輸出跟著不見。
    #   （2026-09-05 實測：管線版拿到的是純文字，script 版仍帶 \033[34m。）
    #   script 給子行程一個真的 pty，兩件事同時成立，而且 -e 會把子行程的
    #   退出碼原樣帶回來（實測 rc=2 與 rc=0 都正確）。
    local log rc=0
    log=$(mktemp) || log=''
    local -a child=("$CX_ROOT/cx" --ui plain --mode "$_TUI_MODE"
                    --runner "$_TUI_RUNNER" "${argv[@]}")
    if [[ -n $log ]] && cx_have script; then
        script -qec "$(cx_q "${child[@]}")" "$log" </dev/tty >&8 2>&9 || rc=$?
    else
        # 沒有 script 就退回「直接接 tty」——顏色保住，失敗對話框少了輸出摘要。
        "${child[@]}" </dev/tty >&8 2>&9 || rc=$?
        log=''
    fi
    if (( rc )); then
        printf '\n\033[31m✘ cx %s 結束於 exit %d\033[0m\n' "${argv[0]}" "$rc" >&9
        _tui_show_failure "$(cx_q "${argv[@]}")" "$rc" "$log"
    else
        printf '\n\033[32m✔ 完成\033[0m\n' >&8
        printf '\n按任意鍵回到選單…' >&8
        read -rsn1 </dev/tty || true
        printf '\n' >&8
    fi
    [[ -n $log ]] && rm -f "$log"
    return 0
}

# ⚠ 回傳值有三種，呼叫端一律用 `|| return` 是不夠的：
#     0  使用者選了一項（值印到 stdout）
#     1  使用者選了離開／按了 ESC   ← 正常結束
#     2  **介面後端壞了**            ← 必須讓使用者知道，不能當成「離開」
#   把 2 併進 1 的後果，就是 2026-09-05 回報的那個症狀：
#   選單一片空白、exit 0、使用者以為功能不存在。
_tui_menu() {                       # _tui_menu <title> <back-label> <tag> <desc> ...
    local title=$1 back=$2; shift 2
    local f rc=0; f=$(mktemp)
    local -a items=("$@") ; items+=("<" "$back")
    _cx_dlg --title "$title" --cancel-button "離開" \
            --menu "\n選擇一項：" 22 76 12 "${items[@]}" 2>"$f" 1>&8 || rc=$?
    if (( rc == 0 )); then
        cat "$f"; rm -f "$f"; return 0
    fi
    rm -f "$f"
    if (( rc >= 2 )); then
        cx_error "選單畫不出來 —— 上面是原因。這不是「你按了離開」。"
        return 2
    fi
    return 1
}

# 取一行輸入。回傳 0 且把值印到 stdout；使用者取消則回傳 1。
_tui_ask() {                        # _tui_ask <title> <prompt> [預設值]
    local f; f=$(mktemp)
    if _cx_dlg --title "$1" --inputbox "\n$2" 12 76 "${3:-}" 2>"$f" 1>&8; then
        cat "$f"; rm -f "$f"; return 0
    fi
    rm -f "$f"; return 1
}

# 自由參數的動詞（art / php / composer / npm）：問一行參數再送出去。
# 這幾個原本完全進不了選單 —— 使用者在選單裡做完 migrate 想跑一個
# make:filament-resource，就只能離開選單改用命令列。
_tui_freeform() {                   # _tui_freeform <verb> <title> <說明> [範例]
    local verb=$1 title=$2 hint=$3 example=${4:-}
    local args
    args=$(_tui_ask "$title" "$hint" "$example") || return 0
    [[ -n ${args// /} ]] || { cx_msg "$title" "沒有輸入參數，已取消。"; return 0; }
    # shellcheck disable=SC2086  # 要讓使用者輸入的參數自然分詞
    _tui_run "$verb" $args
}

_tui_scan() {
    local c
    while c=$(_tui_menu "DevSecOps — 四道防線" "返回" \
        all     "全部依序執行" \
        code    "① Quality  Larastan + SonarQube" \
        sast    "② SAST     Semgrep" \
        sca     "③ SCA      Trivy + composer/npm audit" \
        dast    "④ DAST     OWASP ZAP" \
        secrets "祕密掃描  gitleaks（含 git 歷史）" \
        sonar   "SonarQube 常駐服務：起／停／狀態／權杖"); do
        case $c in
            '<')   return 0 ;;
            sonar) _tui_sonar ;;
            *)     _tui_run scan "$c" ;;
        esac
    done
}

# scan code 這條 lane 需要一個跑著的 SonarQube，但起停它原本只能從命令列。
_tui_sonar() {
    local c
    while c=$(_tui_menu "SonarQube（獨立 project）" "返回" \
        status "目前狀態與版本" \
        up     "啟動（首次要跑 Elasticsearch 初始化，約 2 分鐘）" \
        wait   "等到 status=UP" \
        url    "印出網址" \
        token  "產生／顯示 scanner 用的權杖" \
        logs   "看 log" \
        down   "停止（不刪 volume）"); do
        [[ $c == '<' ]] && return 0
        _tui_run sonar "$c"
    done
}

_tui_git() {
    local c
    while c=$(_tui_menu "Git" "返回" \
        status   "三個 repo 的狀態（含領先落後）" \
        fetch    "三個 repo 一起 fetch --prune（唯讀）" \
        pull     "三個 repo 一起更新（主庫先、子模組後）" \
        sync     "子模組 checkout 追蹤分支" \
        branch   "分支：列出／建立／切換／刪除" \
        feature  "gitflow：從 dev 開 feature／合回 dev" \
        commit   "提交（可指定單一 repo）" \
        config   "git 身分與編輯器（三個 repo 一起設）" \
        push     "⚠ 推送（白名單 + 祕密掃描 + 子模組順序）" \
        guard    "push guard：狀態／安裝／移除" \
        scan     "推送前祕密掃描"); do
        case $c in
            '<')    return 0 ;;
            guard)  _tui_git_guard ;;
            scan)   _tui_run git scan-secrets ;;
            branch) _tui_git_branch ;;
            feature) _tui_git_feature ;;
            config) _tui_git_config ;;
            commit) _tui_git_commit ;;
            push)   cx_confirm "推送" \
                        "會把三個 repo 推到遠端（子模組先、主庫後）。\n\n推送前會先跑祕密掃描與白名單檢查。" \
                        && _tui_run git push ;;
            *)      _tui_run git "$c" ;;
        esac
    done
}

# 主機設定：inventory 是 cx deploy 唯一沒有工具幫忙產生的必要檔案。
# 選單這一項存在的理由，就是讓「從全新 clone 走到部署」不需要離開 cx。
_tui_deploy_hosts() {
    local c
    while c=$(_tui_menu "主機設定（ansible/inventory/hosts.yml）" "返回" \
        show  "列出目前的主機與群組" \
        add   "新增一台主機" \
        rm    "移除一台主機" \
        init  "建立空的 hosts.yml" \
        check "驗證結構與 A15（db_primary 必須剛好一台且在 web 裡）" \
        edit  "用編輯器直接開（註解會保留）"); do
        case $c in
            '<') return 0 ;;
            add)
                local name ip user
                name=$(_tui_ask "新增主機" "inventory 裡的名稱（例：web-1）：") || continue
                [[ -n $name ]] || continue
                ip=$(_tui_ask "新增主機" "IP 或 DNS 名稱：") || continue
                [[ -n $ip ]] || continue
                user=$(_tui_ask "新增主機" "SSH 帳號（有 sudo；不是 deploy_user）：" "ubuntu") || user=''
                local -a a=(deploy hosts add "$name" --ip "$ip")
                [[ -n $user ]] && a+=(--user "$user")
                _tui_run "${a[@]}" ;;
            rm)
                local name
                name=$(_tui_ask "移除主機" "要移除哪一台？") || continue
                [[ -n $name ]] || continue
                _tui_run deploy hosts rm "$name" ;;
            check) _tui_run deploy hosts check --ansible ;;
            *)     _tui_run deploy hosts "$c" ;;
        esac
    done
}

# gitflow：feature 一律從 dev 開、合回 dev。
_tui_git_feature() {
    local c
    while c=$(_tui_menu "gitflow — feature" "返回" \
        list   "列出各 repo 的 feature/*" \
        start  "從 dev 開一個新的 feature" \
        finish "把目前的 feature 合回 dev（不推送、不刪分支）"); do
        case $c in
            '<') return 0 ;;
            start)
                local n; n=$(_tui_ask "新 feature" "名稱（會變成 feature/<名稱>）：") || continue
                [[ -n $n ]] || continue
                _tui_run git feature start "$n" ;;
            finish) _tui_run git feature finish ;;
            *)      _tui_run git feature "$c" ;;
        esac
    done
}

# git 身分與編輯器。沒有身分的話 commit 會失敗，
# 而 cx git commit 的前置檢查就是叫人來這裡。
_tui_git_config() {
    local c
    while c=$(_tui_menu "Git 設定" "返回" \
        show     "目前三個 repo 的 user / editor" \
        identity "設定 user.name 與 user.email" \
        editor   "設定 core.editor"); do
        case $c in
            '<') return 0 ;;
            identity)
                local n e g
                n=$(_tui_ask "git 身分" "user.name：" "$(git config --global user.name 2>/dev/null)") || continue
                e=$(_tui_ask "git 身分" "user.email：" "$(git config --global user.email 2>/dev/null)") || continue
                [[ -n $n && -n $e ]] || continue
                local -a a=(git config identity --name "$n" --email "$e")
                cx_confirm "寫進 ~/.gitconfig？" \
                    "選「是」寫成全域設定（--global）。\n選「否」只寫這三個 repo。" \
                    && a+=(--global)
                _tui_run "${a[@]}" ;;
            editor)
                local ed
                ed=$(_tui_ask "git 編輯器" "core.editor（例：code --wait、nano、vim）：") || continue
                [[ -n $ed ]] || continue
                _tui_run git config editor "$ed" ;;
            *) _tui_run git config "$c" ;;
        esac
    done
}

_tui_git_guard() {
    local c
    while c=$(_tui_menu "push guard（選用，預設未安裝）" "返回" \
        status  "目前狀態" \
        install "安裝 pre-push hook" \
        remove  "移除"); do
        [[ $c == '<' ]] && return 0
        _tui_run git guard "$c"
    done
}

_tui_git_branch() {
    local c
    while c=$(_tui_menu "分支" "返回" \
        list   "列出所有 repo 的分支" \
        new    "建立新分支（三個 repo 一起）" \
        switch "切換分支" \
        delete "⚠ 刪除分支（三個 repo 一起）"); do
        case $c in
            '<') return 0 ;;
            list) _tui_run git branch list ;;
            delete)
                local d
                d=$(_tui_ask "刪除分支" "要刪除的分支名稱（三個 repo 一起）：") || continue
                [[ -n ${d// /} ]] && _tui_run git branch delete "$d"
                ;;
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
    while c=$(_tui_menu "環境（模式：$_TUI_MODE・runner：$_TUI_RUNNER）" "返回" \
        doctor "檢查工具鏈、埠、子模組與阻擋項目" \
        setup  "整備環境：原生工具鏈 / 系統套件 / 專案相依" \
        runner "切換 runner：auto ／ docker ／ native" \
        verify "跑驗收清單並產出報告（可選範圍）" \
        lint   "靜態檢查：ansible / php / js / sh" \
        acl    "檔案權限（POSIX ACL）" \
        fresh  "⚠ 清理與重建專案" \
        rename "⚠ 把整個範本改成新的專案名" \
        init   "⚠ 把範本設定成新專案（改名 → 重建 → 接遠端）" \
        status "三個 repo 的狀態"); do
        case $c in
            '<')     return 0 ;;
            setup)   _tui_setup ;;
            runner)  _tui_switch_runner ;;
            status)  _tui_run git status ;;
            verify)  _tui_verify ;;
            lint)    _tui_lint ;;
            acl)     _tui_acl ;;
            fresh)   _tui_fresh ;;
            rename)  _tui_rename ;;
            init)    _tui_init ;;
            *)       _tui_run "$c" ;;
        esac
    done
}

_tui_verify() {
    local c
    while c=$(_tui_menu "驗收清單" "返回" \
        ''        "預設（static app ansible cli docs tui）" \
        static    "不需要容器：compose 合併結果、Dockerfile、版本鎖定" \
        app       "應用層端點（/up、/admin、/sanctum、前端）" \
        runtime   "需要容器在跑：supervisord、vendor、xdebug" \
        waf       "ModSecurity：攔截、誤擋、引擎狀態" \
        acl       "檔案權限" \
        cli       "cx 自己：動詞／旗標／補全／help 四方同步" \
        docs      "文件與實作是否一致" \
        tui       "選單每一項都指得到真的存在的指令" \
        ansible   "syntax-check + ansible-lint + yamllint" \
        all       "全部（會依序把三個模式都起起來，很慢）"); do
        case $c in
            '<') return 0 ;;
            '')  _tui_run verify ;;
            *)   _tui_run verify "$c" ;;
        esac
    done
}

_tui_lint() {
    local c
    while c=$(_tui_menu "靜態檢查（不改檔案）" "返回" \
        all     "全部" \
        ansible "Ansible（--syntax-check 的替代品）" \
        php     "Laravel Pint --test" \
        js      "Prettier --check" \
        sh      "shellcheck（cx 自己）" \
        style   "▸ 改成自動修正（cx style，會改檔案）"); do
        case $c in
            '<')    return 0 ;;
            style)  _tui_style ;;
            *)      _tui_run lint "$c" ;;
        esac
    done
}

_tui_style() {
    local c
    while c=$(_tui_menu "程式碼風格（⚠ 會改檔案）" "返回" \
        all "PHP + 前端" \
        php "Laravel Pint" \
        js  "Prettier"); do
        [[ $c == '<' ]] && return 0
        cx_confirm "格式化" "cx style $c 會**直接修改**原始碼。\n\n只想檢查的話用「靜態檢查」那一頁。" \
            && _tui_run style "$c"
    done
}

_tui_acl() {
    local c
    while c=$(_tui_menu "檔案權限（POSIX ACL）" "返回" \
        check     "唯讀驗證（doctor 也會看這一項）" \
        status    "顯示目前的 ACL" \
        apply     "套用權限模型（前後端都套）" \
        user      "讓另一個帳號能改原始碼" \
        fix-owner "把不屬於你的檔案要回來（需 sudo）" \
        drop      "⚠ 移除 ACL，回到純 chmod"); do
        case $c in
            '<')   return 0 ;;
            user)  _tui_acl_user ;;
            drop)  cx_confirm "移除 ACL" "會對 backend/ 與 frontend/ 整棵樹跑 setfacl -R -b。" \
                       && _tui_run acl drop ;;
            *)     _tui_run acl "$c" ;;
        esac
    done
}

_tui_acl_user() {
    local c who
    while c=$(_tui_menu "ACL — 其他開發者" "返回" \
        add    "加入（可寫）" \
        add-ro "加入（唯讀）" \
        rm     "移除"); do
        [[ $c == '<' ]] && return 0
        who=$(_tui_ask "ACL 帳號" "系統帳號名稱或 uid：") || continue
        [[ -n ${who// /} ]] || continue
        case $c in
            add)    _tui_run acl user add "$who" ;;
            add-ro) _tui_run acl user add "$who" --ro ;;
            rm)     _tui_run acl user rm "$who" ;;
        esac
    done
}

# init 是全專案破壞性最強的動作（改名 + 刪 .git + 重建骨架）。
# 與 _tui_rename 同樣的節奏：先跑 dry-run 把計畫攤開，再問要不要真的做，
# 而且**不加 --yes** —— cx init 自己的 typed gate（INIT <名字>）仍然會問。
_tui_init() {
    local c
    c=$(_tui_menu "把範本設定成新專案" "返回" \
        init    "改名 → 重建 → 接遠端（給全新的專案）" \
        re-init "不改名，只重建一次") || return 0
    [[ $c == '<' ]] && return 0
    local mode
    mode=$(_tui_menu "重建模式" "返回" \
        scaffold  "全新骨架（你自己寫的程式碼不會回來）" \
        carryover "全新骨架 + 把 app/ routes/ tests/ 疊回去") || return 0
    [[ $mode == '<' ]] && return 0
    local org
    org=$(_tui_ask "GitHub 組織" "CX_GH_ORG（可留空，之後再設）：" "${CX_GH_ORG:-}") || org=''
    # 兩個分支刻意各自把動詞寫成**字面**（而不是組進一個 args 陣列再展開）：
    # verify_meta.py 的 TUI-coverage 是靠字面參數判斷「這個動詞從選單到得了」，
    # 變數展開它看不見 —— 而那個檢查存在的理由，正是不讓動詞悄悄變成孤兒。
    local -a tail=(--mode "$mode")
    [[ -n $org ]] && tail+=(--org "$org")
    local body="上面是 dry-run 的計畫。

這會刪掉 .git 與前後端目前的內容，**不可逆**。
cx init 自己還會要求你打一次確認字串。

繼續嗎？"
    if [[ $c == init ]]; then
        local name
        name=$(_tui_ask "新專案名稱" "小寫開頭，只能有小寫英數與 - _：") || return 0
        [[ -n $name ]] || return 0
        _tui_run --dry-run init "$name" "${tail[@]}"
        cx_confirm --danger "真的要執行嗎？" "$body" || return 0
        _tui_run init "$name" "${tail[@]}"
    else
        _tui_run --dry-run re-init "${tail[@]}"
        cx_confirm --danger "真的要執行嗎？" "$body" || return 0
        _tui_run re-init "${tail[@]}"
    fi
}

# rename 會改寫專案身分（.cxroot / .env / group_vars…）。
# 一律先跑一次 dry-run 把變更點列給使用者看，再問要不要真的套用 ——
# 這裡不加 --yes，cx rename 自己的確認閘門仍然會問。
_tui_rename() {
    local new
    new=$(_tui_ask "改名" "新的專案名稱（小寫開頭，只能有小寫英數與 - _）：") || return 0
    [[ -n $new ]] || return 0
    _tui_run --dry-run rename "$new"
    cx_confirm --danger "套用改名？" \
"上面是 dry-run 列出的變更點。

要真的套用嗎？（cx rename 自己還會再問一次）" || return 0
    _tui_run rename "$new"
}

# fresh 是全專案唯一會刪掉前後端與 .git 的動詞。放進選單是為了「看得到」，
# 但每一項都保留 cx fresh 自己的確認閘門 —— 這裡不加 --yes，也不繞過任何 gate。
_tui_fresh() {
    local c
    while c=$(_tui_menu "清理與重建（⚠ 具破壞性）" "返回" \
        preflight "只跑前置檢查（完全不動任何東西）" \
        backup    "只做備份與封存驗證" \
        carryover "備份 → 確認 → 刪除 → 重建（保留既有內容）" \
        scaffold  "備份 → 確認 → 刪除 → 重建（全新骨架）" \
        rollback  "從封存還原"); do
        case $c in
            '<')                 return 0 ;;
            preflight|backup)    _tui_run fresh --phase "$c" ;;
            carryover|scaffold)  _tui_run fresh --mode "$c" ;;
            rollback)            _tui_run fresh --rollback ;;
        esac
    done
}

# 三個模式的容器操作。標題把目前模式帶出來，避免對著錯的模式下 down。
# 容器子選單是「明確對某個模式操作」，所以暫時把 session 模式切過去，
# 離開時還原 —— 否則 cx --mode dev prod up 會自相矛盾。
_tui_stack() {
    local mode=$1 c
    local _saved=$_TUI_MODE
    _TUI_MODE=$mode
    while c=$(_tui_menu "容器：$mode" "返回" \
        up      "建立並啟動（-d --build）" \
        ps      "列出容器與埠" \
        logs    "看 log（最後 200 行）" \
        sh      "進 app 容器的 shell" \
        restart "重啟" \
        down    "停止並移除容器"); do
        case $c in
            # break 而不是 return —— 迴圈後面還有 _TUI_MODE 的還原，
            # return 會直接跳過它，離開容器子選單之後 session 模式就被留在
            # 剛才操作的那個模式上，而主選單標題顯示的還是舊值。
            '<')     break ;;
            up)      _tui_run up -d --build ;;
            logs)    _tui_run logs ;;
            sh)      _tui_run sh app ;;
            *)       _tui_run "$c" ;;
        esac
    done
    _TUI_MODE=$_saved
}

_tui_docker() {
    local c
    while c=$(_tui_menu "Docker 三模式" "返回" \
        dev  "開發：bind mount / HMR / xdebug / phpMyAdmin" \
        test "測試：不可變映像 / ModSecurity WAF" \
        prod "正式：只發布 80、無管理工具" \
        db   "資料庫：狀態 / migrate / dump / fresh / 還原" \
        pma  "開啟 phpMyAdmin（dev 與 test 模式）"); do
        case $c in
            '<') return 0 ;;
            db)  _tui_db ;;
            pma) _tui_run pma ;;
            *)   _tui_stack "$c" ;;
        esac
    done
}

_tui_db() {
    local c
    # 標題要用 _TUI_MODE 而不是 CX_MODE —— 後者是 cx 啟動當下的值，
    # 在選單裡切過模式之後它不會變，於是標題顯示 dev、實際卻對 prod 下 db fresh。
    while c=$(_tui_menu "資料庫（模式：$_TUI_MODE）" "返回" \
        status  "連線資訊與資料表" \
        migrate "php artisan migrate --force" \
        dump    "備份到 reports/db/" \
        seed    "php artisan db:seed --force" \
        fresh   "⚠ migrate:fresh --seed（會清空資料）" \
        admin   "建立 Filament 管理員" \
        shell   "開 mysql shell" \
        wait    "等資料庫可連線" \
        restore "⚠ 從 dump 還原（會覆蓋現有資料）"); do
        case $c in
            '<')     return 0 ;;
            restore) _tui_db_restore ;;
            *)       _tui_run db "$c" ;;
        esac
    done
}

# restore 要選檔案。原本這一項完全進不了選單，而它正是最需要
#「先看清楚要還原哪一份」的操作。
_tui_db_restore() {
    local -a items=(); local f base
    while IFS= read -r f; do
        [[ -n $f ]] || continue
        base=$(basename "$f")
        items+=("$f" "$base（$(du -h "$f" 2>/dev/null | cut -f1)）")
    done < <(find "$CX_ROOT/reports/db" -maxdepth 1 -type f \( -name '*.sql' -o -name '*.sql.gz' \) \
             -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2- | head -20)
    (( ${#items[@]} )) || { cx_msg "還原" "reports/db/ 底下沒有 dump。先跑「備份」。"; return 0; }
    local sel g; g=$(mktemp)
    if _cx_dlg --title "還原（模式：$_TUI_MODE）" \
            --menu "\n⚠ 這會覆蓋 $_TUI_MODE 的資料庫。選一份 dump：" 20 90 10 \
            "${items[@]}" 2>"$g" 1>&8; then
        sel=$(<"$g"); rm -f "$g"
        _tui_run db restore "$sel"
    else rm -f "$g"; fi
}

_tui_deploy() {
    local c
    while c=$(_tui_menu "部署（Ansible）" "返回" \
        hosts  "主機設定（inventory）—— 沒有它，下面每一項都會撞牆" \
        syntax "ansible-playbook --syntax-check" \
        lint   "ansible-lint + yamllint" \
        galaxy   "安裝 requirements.yml 的 collections" \
        ping     "確認 SSH 與 become" \
        check    "--check --diff 乾跑（staging）" \
        vars     "印出合併後的變數（查『我設的值有沒有生效』）" \
        facts    "抓一台主機的 ansible facts" \
        apply    "⚠ 真的部署（會要求確認）" \
        app      "⚠ 只跑應用層（不碰系統層）" \
        rollback "⚠ 互動式回滾"); do
        case $c in
            '<')          return 0 ;;
            hosts)        _tui_deploy_hosts ;;
            facts)        _tui_deploy_limit facts "主機名稱（必填，來自 inventory）" ;;
            vars|check|apply|app|rollback)
                          _tui_deploy_limit "$c" "限制範圍（留空 = staging）" ;;
            *)            _tui_run deploy "$c" ;;
        esac
    done
}

# 這幾個子指令都吃一個「限制範圍」參數。原本選單一律不帶參數送出，
# 於是 check / apply 永遠只能對預設的 staging 跑，facts 更是直接壞的
#（它的參數是必填的主機名）。
_tui_deploy_limit() {
    local sub=$1 hint=$2 limit
    limit=$(_tui_ask "deploy $sub" "$hint") || return 0
    if [[ -z ${limit// /} ]]; then
        [[ $sub == facts ]] && { cx_msg "deploy facts" "主機名稱不可留空。"; return 0; }
        _tui_run deploy "$sub"
    else
        _tui_run deploy "$sub" "$limit"
    fi
}

# ── 切換模式與 runner ───────────────────────────────────────────────────────
# 這兩個原本只能從命令列給 --mode / --runner，選單裡完全沒有入口，
# 而主選單標題卻印著 [模式：dev] —— 看得到、改不了。
_tui_switch_mode() {
    local f; f=$(mktemp)
    if _cx_dlg --title "切換模式（目前：$_TUI_MODE）" \
            --menu "\n之後所有指令都會帶 --mode <選擇>：" 16 74 4 \
            dev  "開發：bind mount / HMR / xdebug / phpMyAdmin" \
            test "測試：不可變映像 / ModSecurity WAF" \
            prod "正式：只發布 80、無管理工具" 2>"$f" 1>&8; then
        _TUI_MODE=$(<"$f")
    fi
    rm -f "$f"
}

_tui_switch_runner() {
    local f; f=$(mktemp)
    if _cx_dlg --title "切換 runner（目前：$_TUI_RUNNER）" \
            --menu "\n決定 art / composer / npm / test 走哪一條路：" 17 74 4 \
            auto   "自動：有 Docker 就用容器，沒有就用原生" \
            docker "強制容器：不可用時硬失敗，不會偷偷退回原生" \
            native "強制原生：不可用時硬失敗，不會偷偷用容器" 2>"$f" 1>&8; then
        _TUI_RUNNER=$(<"$f")
    fi
    rm -f "$f"
}

# ── 整備環境 ───────────────────────────────────────────────────────────────
# 原本 _tui_env 只有一個裸的 setup，等於「只能全跑，不能分段」，
# 而 cx setup 其實有 native / system / tools / deps 四段可以單獨跑 ——
# 這正是「安裝執行環境、區分 docker 與原生」需要的粒度。
_tui_setup() {
    local c
    while c=$(_tui_menu "整備環境（runner：$_TUI_RUNNER）" "返回" \
        all    "基本初始化：.env + 目錄 + ansible collections" \
        native "★ 一次裝完原生工具鏈 = system + tools + deps" \
        system "需要 root 的系統套件（php/nginx/git/docker/mysql-client）" \
        tools  "免 root 的工具鏈到 ~/.local（composer/node/ansible/掃描器）" \
        deps   "專案相依：composer install + npm ci" \
        env    "只產生 .env（已存在則不覆蓋）" \
        dirs   "只建立 reports/ 與 .cx/ 的葉目錄" \
        guard  "安裝 push guard（選用，預設未安裝）" \
        galaxy "安裝 ansible collections"); do
        case $c in
            '<')   return 0 ;;
            all)   _tui_run setup ;;
            # galaxy 不是 setup 的子指令，是 deploy 的。這一行以前直接把
            # 「galaxy」接在 setup 後面，於是選單裡點下去只會得到
            # 「未知的子指令：galaxy」與 exit 2 —— 選單項目指向一個不存在的指令，
            # 而且沒有任何自我檢查會發現這件事（現在 cx verify tui 會）。
            galaxy) _tui_run deploy galaxy ;;
            *)     _tui_run setup "$c" ;;
        esac
    done
}

# ── 自訂選單 ───────────────────────────────────────────────────────────────
# 檔案格式：每行 `標籤|cx 的參數`，# 開頭是註解，空行忽略。
# 例：
#     重建 dev 並驗收|dev up -d --build
#     只掃祕密|scan secrets
_tui_menu_file() { printf '%s' "${CX_MENU_FILE:-$CX_ROOT/.cx/menu.conf}"; }

_tui_custom_seed() {
    local f; f=$(_tui_menu_file)
    [[ -f $f ]] && return 0
    cx_ensure_host_dirs "$(dirname "$f")" >/dev/null 2>&1
    cat > "$f" <<'SEED'
# cx 自訂選單
#
# 每行一項：  標籤|要傳給 cx 的參數
#   * # 開頭是註解，空行忽略
#   * 參數會原樣接在 cx 後面，並自動帶上目前的 --mode 與 --runner
#   * 改完存檔即可，不需要重開選單
#
# 範例（把前面的 # 拿掉就會出現在選單裡）：
# 重建 dev 並驗收|dev up -d --build
# 只掃祕密|scan secrets
# 後端測試（原生）|test back
# 看 app 的 log|logs app
SEED
}

_tui_custom() {
    local file c
    file=$(_tui_menu_file)
    while :; do
        _tui_custom_seed
        local -a items=(); local label args line
        while IFS= read -r line; do
            [[ -z ${line// /} || ${line:0:1} == '#' ]] && continue
            label=${line%%|*}; args=${line#*|}
            [[ $label == "$line" ]] && continue          # 沒有 | 的行跳過
            items+=("$args" "$label")
        done < "$file"
        items+=("::edit" "── 編輯這份選單 ──")
        local f; f=$(mktemp)
        if ! _cx_dlg --title "自訂選單" --cancel-button "返回" \
                --menu "\n來源：${file/#$CX_ROOT\//}" 20 76 12 \
                "${items[@]}" 2>"$f" 1>&8; then rm -f "$f"; return 0; fi
        c=$(<"$f"); rm -f "$f"
        if [[ $c == '::edit' ]]; then
            "$CX_ROOT/cx" --ui plain code "$file" >&8 2>&9 || \
                ${EDITOR:-vi} "$file" </dev/tty >&8 2>&9 || true
        else
            # shellcheck disable=SC2086
            _tui_run $c
        fi
    done
}

# art / php / composer / npm / code 原本完全進不了選單。
# 後果很具體：在選單裡做完 migrate，想跑一個 make:filament-resource，
# 就只能離開選單改用命令列 —— 而「統一入口」的意義就在這裡破功。
_tui_tools() {
    local c
    while c=$(_tui_menu "工具（runner：$_TUI_RUNNER・模式：$_TUI_MODE）" "返回" \
        art      "php artisan <參數>" \
        php      "php <參數>（-v / -m / -r）" \
        composer "composer <參數>（在 backend/）" \
        npm      "npm <參數>（在 frontend/）" \
        npmb     "npm <參數>（在 backend/，Laravel 端的 Vite 資產）" \
        style    "程式碼風格（⚠ 會改檔案）" \
        code     "用 VS Code 開啟專案" \
        runner   "切換 runner：auto ／ docker ／ native"); do
        case $c in
            '<')      return 0 ;;
            art)      _tui_freeform art "artisan" \
                        "要傳給 php artisan 的參數：" "route:list" ;;
            php)      _tui_freeform php "php" \
                        "要傳給 php 的參數：" "-v" ;;
            composer) _tui_freeform composer "composer（backend/）" \
                        "要傳給 composer 的參數：" "install" ;;
            npm)      _tui_freeform npm "npm（frontend/）" \
                        "要傳給 npm 的參數：" "ci" ;;
            npmb)     local a
                      a=$(_tui_ask "npm（backend/）" "要傳給 npm 的參數：" "ci") || continue
                      [[ -n ${a// /} ]] || continue
                      # shellcheck disable=SC2086
                      _tui_run npm --backend $a ;;
            style)    _tui_style ;;
            code)     _tui_run code ;;
            runner)   _tui_switch_runner ;;
        esac
    done
}

cmd_tui_main() {
    _tui_need_tty || return "$EX_PRECOND"
    local c
    # 標題把兩個狀態都帶出來。原本只印模式，而且那個模式還改不了。
    while c=$(_tui_menu "cx — $(cx_project) 專案管理  [模式：$_TUI_MODE・runner：$_TUI_RUNNER]" "離開" \
        mode   "▸ 切換模式（目前：$_TUI_MODE）" \
        env    "環境：doctor / 整備 / verify / lint / acl / fresh" \
        docker "容器：dev / test / prod / 資料庫 / phpMyAdmin" \
        tools  "工具：artisan / php / composer / npm / 風格 / VS Code" \
        test   "測試：後端 / 前端 / 覆蓋率" \
        scan   "DevSecOps：四道防線" \
        deploy "部署：Ansible" \
        git    "Git：狀態 / 分支 / 提交 / guard" \
        custom "自訂選單（.cx/menu.conf）" \
        help   "指令說明"); do
        case $c in
            '<')    break ;;
            mode)   _tui_switch_mode ;;
            env)    _tui_env ;;
            docker) _tui_docker ;;
            tools)  _tui_tools ;;
            test)   _tui_test ;;
            git)    _tui_git ;;
            scan)   _tui_scan ;;
            deploy) _tui_deploy ;;
            custom) _tui_custom ;;
            help)   _tui_run help ;;
        esac
    done
    printf '\n' >&8
    return 0
}

_tui_test() {
    local c
    while c=$(_tui_menu "測試" "返回" \
        back     "後端 PHPUnit（sqlite :memory:）" \
        front    "前端型別檢查" \
        all      "兩者都跑" \
        coverage "後端覆蓋率（臨時打開 xdebug）" \
        larastan "靜態分析"); do
        case $c in
            '<') return 0 ;;
            *)   _tui_run test "$c" ;;
        esac
    done
}