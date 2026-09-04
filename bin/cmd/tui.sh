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

# 以真正的子行程執行動詞 —— 這是本檔最重要的一行
_tui_run() {
    local -a argv=("$@")
    (( ${#argv[@]} )) || return 0
    printf '\n\033[34m▸ cx --mode %s --runner %s %s\033[0m\n\n' \
        "$_TUI_MODE" "$_TUI_RUNNER" "$(cx_q "${argv[@]}")" >&8
    local rc=0
    "$CX_ROOT/cx" --ui plain --mode "$_TUI_MODE" --runner "$_TUI_RUNNER" \
        "${argv[@]}" </dev/tty >&8 2>&9 || rc=$?
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
    while c=$(_tui_menu "環境（模式：$_TUI_MODE・runner：$_TUI_RUNNER）" "返回" \
        doctor "檢查工具鏈與阻擋項目" \
        setup  "整備環境：原生工具鏈 / 系統套件 / 專案相依" \
        runner "切換 runner：auto ／ docker ／ native" \
        verify "跑驗收清單並產出報告" \
        lint   "Ansible 靜態檢查" \
        status "三個 repo 的狀態"); do
        case $c in
            '<')     return 0 ;;
            setup)   _tui_setup ;;
            runner)  _tui_switch_runner ;;
            status)  _tui_run git status ;;
            *)       _tui_run "$c" ;;
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
        db   "資料庫：狀態 / migrate / dump / fresh"); do
        case $c in
            '<') return 0 ;;
            db)  _tui_db ;;
            *)   _tui_stack "$c" ;;
        esac
    done
}

_tui_db() {
    local c
    while c=$(_tui_menu "資料庫（模式：${CX_MODE}）" "返回" \
        status  "連線資訊與資料表" \
        migrate "php artisan migrate --force" \
        dump    "備份到 reports/db/" \
        fresh   "⚠ migrate:fresh --seed（會清空資料）" \
        admin   "建立 Filament 管理員"); do
        case $c in
            '<') return 0 ;;
            *)   _tui_run db "$c" ;;
        esac
    done
}

_tui_deploy() {
    local c
    while c=$(_tui_menu "部署（Ansible）" "返回" \
        syntax "ansible-playbook --syntax-check" \
        lint   "ansible-lint + yamllint" \
        check  "--check --diff 乾跑（staging）" \
        ping   "確認 SSH 與 become" \
        apply  "⚠ 真的部署（會要求確認）"); do
        case $c in
            '<') return 0 ;;
            *)   _tui_run deploy "$c" ;;
        esac
    done
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

cmd_tui_main() {
    _tui_need_tty || return "$EX_PRECOND"
    local c
    # 標題把兩個狀態都帶出來。原本只印模式，而且那個模式還改不了。
    while c=$(_tui_menu "cx — $(cx_project) 專案管理  [模式：$_TUI_MODE・runner：$_TUI_RUNNER]" "離開" \
        mode   "▸ 切換模式（目前：$_TUI_MODE）" \
        env    "環境：doctor / 整備工具鏈 / verify / lint" \
        docker "容器：dev / test / prod / 資料庫" \
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