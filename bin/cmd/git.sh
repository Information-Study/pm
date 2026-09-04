#!/usr/bin/env bash
# cx git — Git 操作，含 push guard 與 GitHub 遠端管理。

_git_usage() {
    cat >&2 <<'TXT'
用法：cx git <子指令>

  status                各 repo 的分支 / 變更 / 領先落後（不連線，數字看上次 fetch）
  fetch                 三個 repo 一起 fetch --prune（唯讀，不動工作區）
  pull [--allow-merge]  三個 repo 一起更新（主庫先、子模組後；預設只允許快轉）
  sync                  子模組 checkout 追蹤分支（解決 clone 後 detached HEAD）
  commit [-m <訊息>]    提交（子模組先、主庫 gitlink 後）；未給 -m 會引導產生
  save [-m <訊息>]      commit 的別名
  branch list           列出三個 repo 的分支與同步狀態
  branch new <名稱>     在三個 repo 建立並切換到同名分支
  branch switch <名稱>  切換三個 repo 到指定分支
  branch delete <名稱>  刪除分支（需確認；拒絕刪除當前分支與 main）
  guard install|status|remove
  remote-init [--dry-run]   用 gh 建立 Information-Study 的三個 public repo
  scan-secrets          祕密掃描（推送前自動執行）
  push                  推送（白名單 + 祕密掃描 + 子模組先於主庫）
TXT
}

# ⚠ 兩種順序，用途相反，不可混用：
#
# _git_repos_order（子模組先、主庫後）—— 用於 commit / push
#   主庫的 gitlink 指向子模組的 commit，子模組必須先有那個 commit。
#
# _git_repos_super_first（主庫先、子模組後）—— 用於 branch switch / new
#   本專案設了 submodule.recurse=true。主庫切換分支時會「順便」把子模組
#   拉到 gitlink 所指的 commit，因而讓子模組進入 detached HEAD。
#   實測：子模組先切到 feat/x、主庫再切到 feat/x → 子模組變成 DETACHED，分支丟失。
#   所以子模組的 checkout 必須是最後一步才會生效。
_git_repos_order()      { printf '%s\n' "$CX_ROOT/backend" "$CX_ROOT/frontend" "$CX_ROOT"; }
_git_repos_super_first() { printf '%s\n' "$CX_ROOT" "$CX_ROOT/backend" "$CX_ROOT/frontend"; }

_git_repo_slug() {
    case $1 in
        "$CX_ROOT/backend")  printf '%s\n' "$CX_REPO_BACKEND"  ;;
        "$CX_ROOT/frontend") printf '%s\n' "$CX_REPO_FRONTEND" ;;
        "$CX_ROOT")          printf '%s\n' "$CX_REPO_MAIN"     ;;
    esac
}

cmd_git_main() {
    . "$CX_ROOT/bin/lib/guard.sh"
    local sub=${1:-status}; shift || true
    case $sub in
        status)        _git_status ;;
        fetch)         _git_fetch "$@" ;;
        pull)          _git_pull "$@" ;;
        sync)          _git_sync ;;
        commit|save)   _git_commit "$@" ;;
        branch)        _git_branch "$@" ;;
        guard)         case ${1:-status} in
                           install) cx_guard_install ;;
                           status)  cx_guard_status ;;
                           remove)  cx_guard_remove ;;
                           *) cx_die "$EX_USAGE" "guard: 未知子指令 ${1:-}" ;;
                       esac ;;
        remote-init)   _git_remote_init "$@" ;;
        scan-secrets)  _git_scan_secrets ;;
        push)          _git_push "$@" ;;
        -h|--help)     _git_usage ;;
        *)             cx_die "$EX_USAGE" "未知子指令：$sub" ;;
    esac
}

_git_status() {
    local r
    while read -r r; do
        printf '\n%s%s%s\n' "$C_BLU" "$(_git_repo_slug "$r")" "$C_RST"
        if ! _git_is_repo_root "$r"; then
            printf '  %s✘ 不是 git repo 的根%s（子模組未初始化？ git submodule update --init）\n' \
                "$C_RED" "$C_RST"
            continue
        fi
        printf '  branch : %s\n' "$(git -C "$r" branch --show-current 2>/dev/null || echo '<detached>')"
        printf '  head   : %s\n' "$(git -C "$r" rev-parse --short HEAD 2>/dev/null || echo '<unborn>')"
        printf '  dirty  : %s 項\n' "$(git -C "$r" status --porcelain 2>/dev/null | wc -l)"
        printf '  origin : %s\n' "$(git -C "$r" remote get-url origin 2>/dev/null || echo '(未設定)')"
        _git_print_ahead_behind "$r"
    done < <(_git_repos_order)
}

# usage 一直宣稱 status 會顯示「領先落後」，但實作從來沒印過 ——
# 而那正是決定「該 pull 還是該 push」的唯一資訊。
#
# 讀的是 remote-tracking ref（refs/remotes/origin/<br>），不是遠端本身：
# 這個函式**不連線**，所以數字的新鮮度取決於上一次 fetch。
# 沒有 remote-tracking ref 時要說清楚，不要印 0/0 讓人以為已經同步。
_git_print_ahead_behind() {
    local r=$1 br ab a b
    br=$(git -C "$r" branch --show-current 2>/dev/null || true)
    if [[ -z $br ]]; then
        printf '  vs origin: （detached HEAD，無分支可比對）\n'
        return 0
    fi
    if ! git -C "$r" rev-parse --verify --quiet "refs/remotes/origin/$br" >/dev/null; then
        printf '  vs origin: （沒有 refs/remotes/origin/%s —— 先跑 cx git fetch）\n' "$br"
        return 0
    fi
    ab=$(git -C "$r" rev-list --left-right --count \
            "refs/heads/$br...refs/remotes/origin/$br" 2>/dev/null || printf '0\t0')
    a=${ab%%[[:space:]]*}; b=${ab##*[[:space:]]}
    if [[ $a == 0 && $b == 0 ]]; then
        printf '  vs origin: 同步（上次 fetch：%s）\n' "$(_git_last_fetch "$r")"
    else
        printf '  vs origin: 領先 %s ・ 落後 %s（上次 fetch：%s）\n' \
            "$a" "$b" "$(_git_last_fetch "$r")"
    fi
}

# FETCH_HEAD 的 mtime 就是上一次 fetch 的時間。
# 沒有它代表從來沒 fetch 過 —— 這時 ahead/behind 的數字完全不能信，
# 所以一定要把時間印出來，不要讓「領先 0 落後 0」被當成「已經同步」。
_git_last_fetch() {
    local gd f
    # 子模組的 .git 是檔案不是目錄，不能直接拼 "$1/.git/FETCH_HEAD"
    gd=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || { printf '未知'; return; }
    f="$gd/FETCH_HEAD"
    [[ -f $f ]] || { printf '從未'; return; }
    date -r "$f" '+%m-%d %H:%M' 2>/dev/null || printf '未知'
}

# 這個路徑本身是不是一個 git repo 的根？
# 不能只用 `git -C "$r" rev-parse --git-dir` —— 那會沿著父目錄往上找，
# 所以「$CX_ROOT/backend 是空目錄、但 $CX_ROOT 是 repo」時它會回傳成功。
_git_is_repo_root() {
    local r=$1 top
    top=$(git -C "$r" rev-parse --show-toplevel 2>/dev/null) || return 1
    [[ $(cd "$r" && pwd -P) == "$(cd "$top" && pwd -P)" ]]
}

# 三 repo 操作的共同前置檢查：子模組沒初始化時，
# 後面每一個 git 指令都會失敗，但因為 dispatcher 關掉了 errexit，
# cx_ok 仍會無條件印出「✔」。
_git_require_repos() {
    local r slug bad=0
    while read -r r; do
        slug=$(_git_repo_slug "$r")
        _git_is_repo_root "$r" \
            || { cx_error "$slug（$r）不是 git repo 的根"; bad=1; }
    done < <(_git_repos_order)
    (( bad == 0 )) || {
        cx_dim "  子模組尚未初始化？ git submodule update --init --recursive"
        return "$EX_PRECOND"
    }
}

_git_sync() {
    _git_require_repos || return $?
    cx_step "同步子模組到追蹤分支"
    local c b head
    for c in backend frontend; do
        b=$(git config -f "$CX_ROOT/.gitmodules" --get "submodule.$c.branch" 2>/dev/null || echo main)

        if git -C "$CX_ROOT/$c" symbolic-ref -q HEAD >/dev/null 2>&1; then
            cx_ok "$c 已在分支 $(git -C "$CX_ROOT/$c" branch --show-current)"
            continue
        fi

        # ── detached HEAD ────────────────────────────────────────────────
        # 原本這裡直接 `git checkout -q "$b"`。那在「detached HEAD 就是
        # 追蹤分支的內容」時沒問題，但只要 detached HEAD **領先**該分支
        #（例如剛在 detached 狀態下 commit 過），checkout 就會把 HEAD 移回
        # 舊的分支尖端，剛才那些 commit 立刻變成孤兒 —— 沒有任何警告，
        # git status 之後看起來還很乾淨。
        #
        # 而主庫的 gitlink 已經指向那個 commit，於是 `git status` 會顯示
        # 子模組「有未提交的變更」，實際上是內容被退回去了。
        #
        # 正確做法是 -B：把分支移到目前的 HEAD（等於 fast-forward），
        # 這樣「切回分支」與「保住 commit」兩件事同時成立。
        head=$(git -C "$CX_ROOT/$c" rev-parse HEAD)
        if git -C "$CX_ROOT/$c" rev-parse --verify --quiet "$b" >/dev/null \
           && ! git -C "$CX_ROOT/$c" merge-base --is-ancestor "$head" "$b" 2>/dev/null; then
            cx_warn "$c 的 detached HEAD（${head:0:7}）領先 $b —— 用 -B 把分支帶過來，不丟 commit"
        fi
        if cx_run git -C "$CX_ROOT/$c" checkout -q -B "$b" "$head"; then
            cx_ok "$c → $b（原本是 detached HEAD）"
        else
            cx_error "$c 切換到 $b 失敗"
            return "$EX_FAIL"
        fi
    done
}

_git_commit() {
    local msg='' amend=0 no_verify_scan=0
    while (( $# )); do
        case $1 in
            -m|--message) [[ -n ${2:-} ]] || cx_die "$EX_USAGE" "-m 需要訊息"
                          msg=$2; shift 2 ;;
            --amend)      amend=1; shift ;;
            --skip-scan)  no_verify_scan=1; shift ;;
            *)            cx_die "$EX_USAGE" "commit: 未知參數 $1" ;;
        esac
    done

    # 沒給訊息就引導產生（Conventional Commits）
    if [[ -z $msg && $amend -eq 0 ]]; then
        local _mrc=0
        msg=$(_git_compose_message) || _mrc=$?
        (( _mrc == 0 )) || return "$_mrc"
    fi

    # 提交前掃一次祕密 —— 三個 repo 都是 public
    if (( no_verify_scan )); then
        cx_warn "[--skip-scan] 已略過祕密掃描 —— cx git push 仍會擋"
    else
        _git_scan_secrets
    fi

    cx_step "提交"
    local c changed=0 n
    # 子模組必須先提交：主庫的 gitlink 指向子模組的 commit，
    # 反過來會讓 gitlink 指向一個尚不存在的 commit。
    for c in backend frontend; do
        [[ -d $CX_ROOT/$c ]] || continue
        n=$(git -C "$CX_ROOT/$c" status --porcelain | wc -l)
        if (( n > 0 )); then
            git -C "$CX_ROOT/$c" status --short | sed 's/^/      /' >&2
            cx_run git -C "$CX_ROOT/$c" add -A
            if (( amend )); then
                cx_run git -C "$CX_ROOT/$c" commit -q --amend --no-edit
            else
                cx_run git -C "$CX_ROOT/$c" commit -q -m "$msg"
            fi
            cx_ok "$c 已提交（$n 項）"
            changed=1
        else
            cx_dim "$c 無變更"
        fi
    done

    # 主庫：自身變更 + 子模組 gitlink 更新
    n=$(git -C "$CX_ROOT" status --porcelain | wc -l)
    if (( n > 0 )); then
        git -C "$CX_ROOT" status --short | sed 's/^/      /' >&2
        cx_run git -C "$CX_ROOT" add -A
        if (( amend )); then
            cx_run git -C "$CX_ROOT" commit -q --amend --no-edit
        else
            cx_run git -C "$CX_ROOT" commit -q -m "$msg"
        fi
        cx_ok "主庫已提交（$n 項，含 gitlink）"
    elif (( changed )); then
        cx_warn "子模組已提交但主庫的 gitlink 沒有變化 —— 請確認 submodule 指標是否正確"
    else
        cx_dim "主庫無變更"
    fi
    (( changed )) || [[ $n -gt 0 ]] || cx_warn "沒有任何東西需要提交"
}

# 引導式產生 Conventional Commits 訊息（無 TTY 時退回純文字提問）
_git_compose_message() {
    local -a types=(feat fix docs refactor perf test build ci chore)
    local type scope subject

    if cx_interactive; then
        local f; f=$(mktemp)
        local -a items=()
        local t d
        for t in "${types[@]}"; do
            case $t in
                feat) d="新功能" ;; fix) d="修正缺陷" ;; docs) d="文件" ;;
                refactor) d="重構（不改行為）" ;; perf) d="效能" ;; test) d="測試" ;;
                build) d="建置／相依" ;; ci) d="CI 設定" ;; chore) d="雜項" ;;
            esac
            items+=("$t" "$d")
        done
        _cx_dlg --title "提交類型" --menu "\n選擇變更類型：" 20 72 10 "${items[@]}" 2>"$f" 1>&8 \
            || { rm -f "$f"; return 1; }
        type=$(<"$f")
        _cx_dlg --title "影響範圍" --inputbox "\n可留空。例如 backend / frontend / docker / ansible / cx" \
            12 70 "" 2>"$f" 1>&8 || { rm -f "$f"; return 1; }
        scope=$(<"$f")
        _cx_dlg --title "摘要" --inputbox "\n一行摘要（祈使句，不加句號）：" 12 76 "" 2>"$f" 1>&8 \
            || { rm -f "$f"; return 1; }
        subject=$(<"$f"); rm -f "$f"
    else
        if ! _cx_can_ask; then
            cx_error "非互動環境無法引導產生提交訊息"
            cx_dim "  請改用： cx git commit -m 'feat(scope): 摘要'"
            return "$EX_USAGE"
        fi
        printf '提交類型 (%s): ' "${types[*]}" >&2
        read -r type </dev/tty || return 1
        printf '影響範圍（可留空）: ' >&2; read -r scope </dev/tty || return 1
        printf '一行摘要: ' >&2;           read -r subject </dev/tty || return 1
    fi

    local ok=0 t
    for t in "${types[@]}"; do [[ $type == "$t" ]] && ok=1; done
    (( ok )) || { cx_error "無效的類型：$type"; return 1; }
    [[ -n $subject ]] || { cx_error "摘要不可為空"; return 1; }

    local m="$type"
    [[ -n $scope ]] && m="$m($scope)"
    printf '%s: %s\n' "$m" "$subject"
}

# ---------------------------------------------------------------------------
# 分支：三個 repo 同進同出
# ---------------------------------------------------------------------------
_git_branch() {
    local sub=${1:-list}; shift || true
    case $sub in
        list)   _git_branch_list ;;
        -h|--help) _git_usage; return 0 ;;
        new)    [[ -n ${1:-} ]] || cx_die "$EX_USAGE" "branch new 需要名稱"
                _git_branch_new "$1" ;;
        switch) [[ -n ${1:-} ]] || cx_die "$EX_USAGE" "branch switch 需要名稱"
                _git_branch_switch "$1" ;;
        delete) [[ -n ${1:-} ]] || cx_die "$EX_USAGE" "branch delete 需要名稱"
                _git_branch_delete "$1" ;;
        *)      cx_die "$EX_USAGE" "branch: 未知子指令 $sub（list|new|switch|delete）" ;;
    esac
}

_git_branch_list() {
    local r slug cur
    while read -r r; do
        slug=$(_git_repo_slug "$r")
        cur=$(git -C "$r" branch --show-current 2>/dev/null || echo '<detached>')
        printf '\n%s%s%s  目前：%s\n' "$C_BLU" "$slug" "$C_RST" "$cur"
        local b date up track mark
        while IFS='|' read -r b date up track; do
            mark='  '; [[ $b == "$cur" ]] && mark=' *'
            printf '%s %-24s %-16s %-18s %s\n' "$mark" "$b" "$date" "${up:-（無上游）}" "$track"
        # <(...) 開的是子 shell，errexit 與 ERR trap 在裡面仍然有效
        # （dispatcher 的 || _rc=$? 只關掉主 shell 的）。
        # 子模組尚未初始化時 git 會 exit 128 並吐出整串 stack dump。
        done < <(git -C "$r" for-each-ref --sort=-committerdate refs/heads/ \
            --format='%(refname:short)|%(committerdate:relative)|%(upstream:short)|%(upstream:track)' \
            2>/dev/null || true)
    done < <(_git_repos_order)
    printf '\n'
}

_git_branch_check_name() {
    local n=$1
    [[ $n =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] \
        || cx_die "$EX_USAGE" "分支名稱只能含英數與 . _ / -，且不可以符號開頭：$n"
    [[ $n == *..* || $n == */ || $n == *.lock ]] \
        && cx_die "$EX_USAGE" "git 不接受的分支名稱：$n"
    return 0
}

_git_branch_new() {
    local n=$1; _git_branch_check_name "$n"
    local r slug dirty=0
    while read -r r; do
        slug=$(_git_repo_slug "$r")
        [[ -n $(git -C "$r" status --porcelain) ]] && { cx_warn "$slug 有未提交變更"; dirty=1; }
        git -C "$r" show-ref --verify --quiet "refs/heads/$n" \
            && cx_die "$EX_PRECOND" "$slug 已經有分支 $n"
    done < <(_git_repos_order)
    (( dirty )) && { cx_confirm "有未提交變更" \
        "上列 repo 有未提交變更。\n\ngit 會把它們一起帶到新分支 $n。\n\n繼續嗎？" \
        || return "$EX_ABORT"; }

    cx_step "建立分支 $n"
    # 主庫先：submodule.recurse=true 會讓主庫的 switch 順便動子模組，
    # 所以子模組的 switch 必須排在後面才不會被覆蓋成 detached。
    while read -r r; do
        slug=$(_git_repo_slug "$r")
        cx_run git -C "$r" switch -c "$n"
        cx_ok "$slug → $n"
    done < <(_git_repos_super_first)
    _git_assert_no_detached || return "$EX_FAIL"
    cx_info "三個 repo 都在 $n。提交請用： cx git commit"
}

_git_branch_switch() {
    local n=$1; _git_branch_check_name "$n"
    local r slug missing=()
    while read -r r; do
        slug=$(_git_repo_slug "$r")
        git -C "$r" show-ref --verify --quiet "refs/heads/$n" || missing+=("$slug")
    done < <(_git_repos_order)
    if (( ${#missing[@]} )); then
        cx_error "下列 repo 沒有分支 $n：${missing[*]}"
        cx_dim "  要一起建立請用： cx git branch new $n"
        return "$EX_PRECOND"
    fi

    cx_step "切換到 $n"
    while read -r r; do
        slug=$(_git_repo_slug "$r")
        if [[ -n $(git -C "$r" status --porcelain) ]]; then
            cx_error "$slug 有未提交變更，拒絕切換（避免變更被帶走或衝突）"
            git -C "$r" status --short | sed 's/^/      /' >&2
            return "$EX_PRECOND"
        fi
    done < <(_git_repos_order)
    while read -r r; do
        slug=$(_git_repo_slug "$r")
        cx_run git -C "$r" switch "$n"
        cx_ok "$slug → $n"
    done < <(_git_repos_super_first)
    _git_assert_no_detached || return "$EX_FAIL"
}

# 切換之後一定要驗：submodule.recurse 的副作用是靜默的，
# 只看 switch 的 exit code 看不出子模組被打成 detached。
_git_assert_no_detached() {
    local r slug bad=0
    while read -r r; do
        slug=$(_git_repo_slug "$r")
        if ! git -C "$r" symbolic-ref -q HEAD >/dev/null 2>&1; then
            cx_error "$slug 處於 detached HEAD（submodule.recurse 的副作用）"
            cx_dim "  修復： git -C $r switch <分支>"
            bad=1
        fi
    done < <(_git_repos_order)
    (( bad == 0 ))
}

_git_branch_delete() {
    local n=$1; _git_branch_check_name "$n"
    [[ $n == main || $n == master ]] && cx_die "$EX_USAGE" "拒絕刪除 $n"
    local r slug cur
    while read -r r; do
        slug=$(_git_repo_slug "$r")
        cur=$(git -C "$r" branch --show-current 2>/dev/null || echo '')
        [[ $cur == "$n" ]] && cx_die "$EX_PRECOND" "$slug 目前就在 $n 上，請先切走"
    done < <(_git_repos_order)

    # 先確認至少有一個 repo 真的有這個分支，否則不該拿確認閘門去煩人
    local found=0 have=()
    while read -r r; do
        if git -C "$r" show-ref --verify --quiet "refs/heads/$n"; then
            found=1; have+=("$(_git_repo_slug "$r")")
        fi
    done < <(_git_repos_order)
    (( found )) || cx_die "$EX_PRECOND" "三個 repo 都沒有分支 $n"

    cx_confirm --danger "刪除分支 $n" \
        "將在下列 repo 刪除分支 $n：\n\n  ${have[*]}\n\n未合併的 commit 不會被刪除（git 會擋下）。\n\n確定嗎？" \
        || return "$EX_ABORT"
    while read -r r; do
        slug=$(_git_repo_slug "$r")
        if ! git -C "$r" show-ref --verify --quiet "refs/heads/$n"; then
            cx_dim "$slug 沒有分支 $n，略過"
            continue
        fi
        local out
        if out=$(git -C "$r" branch -d "$n" 2>&1); then
            cx_ok "$slug 已刪除 $n"
        elif printf '%s' "$out" | grep -q 'not fully merged'; then
            cx_warn "$slug 的 $n 尚未合併，保留（確定要丟棄請自行 git -C $r branch -D $n）"
        else
            cx_error "$slug 刪除 $n 失敗：$out"
        fi
    done < <(_git_repos_order)
}

# ---------------------------------------------------------------------------
# 祕密掃描：三個 repo 都是 public，這是最後一道防線
# ---------------------------------------------------------------------------
_git_scan_secrets() {
    cx_step "祕密掃描（三個 repo 皆為 PUBLIC）"
    local r slug bad=0 repo_bad files hits

    while read -r r; do
        slug=$(_git_repo_slug "$r")
        repo_bad=0        # per-repo 重置：否則第一個 repo 髒之後，
                          # 後面每個 repo 的「✔ 乾淨」都會被吞掉
        files=$(git -C "$r" ls-files)
        [[ -n $files ]] || continue

        # 1) 檔名層級
        hits=$(printf '%s\n' "$files" | grep -iE '(^|/)\.env$|\.key$|\.pem$|\.p12$|\.pfx$|(^|/)auth\.json$|(^|/)id_rsa|\.sqlite$' || true)
        if [[ -n $hits ]]; then
            cx_error "$slug 有不該進版控的檔案："; printf '%s\n' "$hits" | sed 's/^/      /' >&2; repo_bad=1
        fi

        # 2) 內容層級（排除 .example / lock 檔）
        #
        # ⚠ 必須 cd 進那個 repo。
        #
        # `git -C "$r" ls-files` 輸出的是**相對於該 repo 根目錄**的路徑。
        # 原本直接把它交給在 CX_ROOT 執行的 grep，於是對 backend / frontend
        # 這兩個子模組來說，每一個路徑都指向 CX_ROOT 底下不存在的位置：
        #   grep: .editorconfig: No such file or directory
        # 而那些錯誤又被 2>/dev/null 吞掉，結果是「掃了 0 個檔案然後回報乾淨」。
        #
        # 2026-09-04 實測：在 backend/config/ 放一個
        #   APP_KEY=base64:AAAA…
        # 並 git add，`cx git scan-secrets` 仍然回報「pm-backend 乾淨」。
        # 也就是說推送前的內容層級防線對兩個子模組完全沒有作用過。
        # （gitleaks 那一層掃的是 git 歷史，抓不到只在工作區/暫存區的東西。）
        hits=$( cd "$r" && printf '%s\n' "$files" \
                | grep -vE '\.example$|lock$|\.lock$' \
                | tr '\n' '\0' \
                | xargs -0 -r grep -lIE \
                  'APP_KEY=base64:[A-Za-z0-9+/=]{20,}|BEGIN [A-Z ]*PRIVATE KEY|gh[pousr]_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}|xox[baprs]-[0-9A-Za-z-]{10,}' \
                  2>/dev/null || true )
        if [[ -n $hits ]]; then
            cx_error "$slug 疑似含憑證："; printf '%s\n' "$hits" | sed 's/^/      /' >&2; repo_bad=1
        fi

        # 3) 絕對路徑洩漏（symlink 指向 $HOME）
        hits=$(git -C "$r" ls-files -s | awk '$1=="120000"{print $4}' || true)
        while IFS= read -r l; do
            [[ -n $l ]] || continue
            local tgt; tgt=$(git -C "$r" show ":$l" 2>/dev/null || true)
            [[ $tgt == /* ]] && { cx_error "$slug symlink 指向絕對路徑：$l → $tgt"; repo_bad=1; }
        done <<< "$hits"

        # 4) gitleaks 掃「整個歷史」——祕密一旦進過 commit，改掉當前檔案是不夠的
        if cx_have gitleaks; then
            if ! gitleaks git "$r" --no-banner --redact \
                    --config "$CX_ROOT/docker/security/trivy/gitleaks.toml" \
                    >/dev/null 2>&1; then
                cx_error "$slug gitleaks 在 git 歷史中發現祕密"
                # 必須加 -v：gitleaks 8.30 不加 -v 只印 INF/WRN 摘要，
                # 沒有 -v 的話下面的 grep 永遠抓不到東西，使用者只看到
                # 「發現祕密」卻不知道是哪一筆。
                gitleaks git "$r" --no-banner --redact -v \
                    --config "$CX_ROOT/docker/security/trivy/gitleaks.toml" 2>&1 \
                    | grep -E 'RuleID|File:|Line:|Commit:' | sed 's/^/      /' >&2 || true
                repo_bad=1
            fi
        else
            cx_warn "gitleaks 未安裝 —— 略過歷史掃描（建議安裝）"
        fi

        (( repo_bad )) && bad=1
        (( repo_bad )) || cx_ok "$slug 乾淨（$(printf '%s\n' "$files" | wc -l) 個檔案，含歷史）"
    done < <(_git_repos_order)

    (( bad == 0 )) || cx_die "$EX_FAIL" "祕密掃描未通過，已中止"
}

# ---------------------------------------------------------------------------
# fetch / pull
# ---------------------------------------------------------------------------
#
# 為什麼 pull 的順序與 push **相反**：
#
#   push：子模組先、主庫後 —— 主庫的 gitlink 指向子模組的 commit，
#         那個 commit 必須先存在於子模組的遠端。
#
#   pull：主庫先、子模組後 —— 主庫的 gitlink 才是「這一版該用哪個子模組 commit」
#         的唯一真相。先把主庫拉到最新，才知道子模組要移到哪裡。
#         反過來做的話，子模組會被拉到它自己分支的尖端，
#         而那個 commit 不一定是主庫這一版記錄的那個 —— 於是 pull 完
#         `git status` 立刻顯示子模組「有未提交的變更」，
#         而實際上你只是把子模組拉到了別的版本。

# 遠端安全性：黑名單一律硬擋（拉下來就等於把舊專案的內容帶進工作區），
# 不在白名單的則警告但放行（可能是刻意加的 upstream / fork）。
_git_assert_remote_safe() {
    local slug=$1 url=$2
    printf '%s' "$url" | grep -qE "$CX_DENIED_REMOTE_RE" \
        && cx_die "$EX_PRECOND" "$slug 的 origin 在永久黑名單，拒絕連線：$url"
    printf '%s' "$url" | grep -qE "$CX_ALLOWED_REMOTE_RE" \
        || cx_warn "$slug 的 origin 不在白名單（唯讀操作，仍繼續）：$url"
    return 0
}

_git_fetch() {
    (( $# == 0 )) || cx_die "$EX_USAGE" "fetch 不接受參數（收到 $1）"
    _git_require_repos || return $?

    cx_step "fetch（三個 repo，唯讀）"
    local r slug url rc=0
    while read -r r; do
        slug=$(_git_repo_slug "$r")
        url=$(git -C "$r" remote get-url origin 2>/dev/null || true)
        if [[ -z $url ]]; then
            cx_warn "$slug 沒有 origin，略過（先跑 cx git remote-init）"
            continue
        fi
        _git_assert_remote_safe "$slug" "$url"

        # --prune：遠端刪掉的分支，本地的 remote-tracking ref 也要跟著消失，
        # 否則 cx git branch list 會一直列出早就不存在的上游。
        if cx_run git -C "$r" fetch --prune origin; then
            cx_ok "$slug 已 fetch"
        else
            cx_error "$slug fetch 失敗"
            rc=1
        fi
    done < <(_git_repos_order)

    cx_step "fetch 之後的狀態"
    while read -r r; do
        printf '\n%s%s%s\n' "$C_BLU" "$(_git_repo_slug "$r")" "$C_RST"
        _git_print_ahead_behind "$r"
    done < <(_git_repos_order)
    printf '\n'

    (( rc == 0 )) || return "$EX_FAIL"
    cx_dim "要真的更新工作區： cx git pull"
}

_git_pull() {
    local allow_merge=0
    while (( $# )); do
        case $1 in
            --ff-only) shift ;;                 # 預設就是，保留以示明確
            --allow-merge) allow_merge=1; shift ;;
            *) cx_die "$EX_USAGE" "pull: 未知參數 $1（只支援 --ff-only / --allow-merge）" ;;
        esac
    done
    _git_require_repos || return $?

    # ── 1) 髒工作區一律先擋 ────────────────────────────────────────────
    # 不是保守，是因為失敗會發生在「一半」的位置：主庫已經快轉、
    # 子模組還沒動，而 merge 又因為 local changes 被拒絕。
    # 那個狀態很難描述、更難復原，不如一開始就不要進去。
    local r slug dirty=0
    while read -r r; do
        slug=$(_git_repo_slug "$r")
        if [[ -n $(git -C "$r" status --porcelain) ]]; then
            cx_error "$slug 有未提交變更"
            git -C "$r" status --short | sed 's/^/      /' >&2
            dirty=1
        fi
    done < <(_git_repos_order)
    if (( dirty )); then
        cx_dim "  先提交（cx git commit）或自行 git stash，再跑 cx git pull"
        return "$EX_PRECOND"
    fi

    # ── 2) fetch ───────────────────────────────────────────────────────
    cx_step "fetch"
    while read -r r; do
        slug=$(_git_repo_slug "$r")
        local url; url=$(git -C "$r" remote get-url origin 2>/dev/null || true)
        [[ -n $url ]] || { cx_warn "$slug 沒有 origin，略過"; continue; }
        _git_assert_remote_safe "$slug" "$url"
        cx_run git -C "$r" fetch --prune origin || cx_die "$EX_FAIL" "$slug fetch 失敗"
    done < <(_git_repos_order)

    # ── 3) 主庫先快轉 ──────────────────────────────────────────────────
    cx_step "更新主庫（$CX_REPO_MAIN）"
    local br ab a b
    br=$(git -C "$CX_ROOT" branch --show-current)
    [[ -n $br ]] || cx_die "$EX_PRECOND" "主庫是 detached HEAD，請先 git switch <分支>"
    if ! git -C "$CX_ROOT" rev-parse --verify --quiet "refs/remotes/origin/$br" >/dev/null; then
        cx_die "$EX_PRECOND" "遠端沒有分支 $br（refs/remotes/origin/$br 不存在）"
    fi
    ab=$(git -C "$CX_ROOT" rev-list --left-right --count \
            "refs/heads/$br...refs/remotes/origin/$br")
    a=${ab%%[[:space:]]*}; b=${ab##*[[:space:]]}

    if [[ $b == 0 ]]; then
        cx_ok "主庫已是最新（領先 $a）"
    elif [[ $a != 0 ]] && (( ! allow_merge )); then
        # 分岔：預設不自動處理。合併或 rebase 都會產生一個「誰也沒審過」的結果，
        # 而主庫的每個 commit 都帶著子模組 gitlink —— 自動合併很可能把
        # gitlink 合成一個從來不存在的組合。
        cx_error "主庫已分岔：本地領先 $a、落後 $b"
        cx_dim "  想看差異： git -C $CX_ROOT log --oneline --left-right $br...origin/$br"
        cx_dim "  確定要合併： cx git pull --allow-merge"
        cx_dim "  想丟掉本地： git -C $CX_ROOT reset --hard origin/$br（不可逆）"
        return "$EX_PRECOND"
    else
        local -a margs=(merge --ff-only "origin/$br")
        (( allow_merge )) && margs=(merge --no-edit "origin/$br")
        if cx_run git -C "$CX_ROOT" "${margs[@]}"; then
            cx_ok "主庫已更新（+$b）"
        else
            cx_die "$EX_FAIL" "主庫更新失敗"
        fi
    fi

    # ── 4) 子模組移到主庫記錄的 gitlink ────────────────────────────────
    # 這一步是 pull 的重點：gitlink 是「這一版該用哪個子模組 commit」的唯一真相。
    cx_step "把子模組移到主庫記錄的 gitlink"
    if cx_run git -C "$CX_ROOT" submodule update --init --recursive; then
        cx_ok "子模組已對齊 gitlink"
    else
        cx_die "$EX_FAIL" "submodule update 失敗"
    fi

    # ── 5) 子模組接回追蹤分支 ──────────────────────────────────────────
    # submodule update 之後子模組一定是 detached HEAD。
    # _git_sync 用 checkout -B 把分支帶到目前的 HEAD，兩件事同時成立：
    # 回到分支上，而且不丟任何 commit。
    _git_sync || return $?

    # ── 6) 子模組遠端比 gitlink 新的話要講出來 ─────────────────────────
    # 這不是錯誤，是資訊：有人推了子模組但還沒更新主庫的 gitlink。
    # 不講的話，使用者會以為自己拿到的是最新的前端／後端。
    local c cb cab ca cbh
    for c in backend frontend; do
        [[ -d $CX_ROOT/$c ]] || continue
        cb=$(git -C "$CX_ROOT/$c" branch --show-current 2>/dev/null || true)
        [[ -n $cb ]] || continue
        git -C "$CX_ROOT/$c" rev-parse --verify --quiet "refs/remotes/origin/$cb" >/dev/null || continue
        cab=$(git -C "$CX_ROOT/$c" rev-list --left-right --count \
                "refs/heads/$cb...refs/remotes/origin/$cb")
        ca=${cab%%[[:space:]]*}; cbh=${cab##*[[:space:]]}
        if [[ $cbh != 0 ]]; then
            cx_warn "$(_git_repo_slug "$CX_ROOT/$c") 的 origin/$cb 比主庫的 gitlink 新 $cbh 個 commit"
            cx_dim "  主庫的 gitlink 才是這一版的定義 —— 要採用新的請在子模組內"
            cx_dim "  git -C $CX_ROOT/$c merge --ff-only origin/$cb 之後 cx git commit"
        fi
    done

    cx_step "結果"
    local rr
    while read -r rr; do
        printf '\n%s%s%s\n' "$C_BLU" "$(_git_repo_slug "$rr")" "$C_RST"
        printf '  head   : %s\n' "$(git -C "$rr" rev-parse --short HEAD)"
        _git_print_ahead_behind "$rr"
    done < <(_git_repos_order)
    printf '\n'
    cx_ok "pull 完成"
}

# ---------------------------------------------------------------------------
# 建立 GitHub 遠端
# ---------------------------------------------------------------------------
_git_remote_init() {
    cx_have gh || cx_die "$EX_PRECOND" "找不到 gh CLI"
    gh auth status >/dev/null 2>&1 || cx_die "$EX_PRECOND" "gh 未登入（gh auth login）"

    cx_step "建立 GitHub 遠端（組織：$CX_GH_ORG）"
    local r slug url
    while read -r r; do
        slug=$(_git_repo_slug "$r")
        url="https://github.com/$CX_GH_ORG/$slug.git"

        if gh repo view "$CX_GH_ORG/$slug" >/dev/null 2>&1; then
            cx_warn "$CX_GH_ORG/$slug 已存在，略過建立"
        else
            local desc
            case $slug in
                "$CX_REPO_BACKEND")  desc="pm 後端 — PHP 8.5 + Laravel 13 + Filament v5" ;;
                "$CX_REPO_FRONTEND") desc="pm 前端 — Vue 3 + Nuxt 4" ;;
                *)                   desc="pm — 統籌大庫（Docker / Ansible / cx）" ;;
            esac
            cx_run gh repo create "$CX_GH_ORG/$slug" --public --disable-wiki --description "$desc"
            cx_ok "已建立 $CX_GH_ORG/$slug"
        fi

        if git -C "$r" remote get-url origin >/dev/null 2>&1; then
            cx_run git -C "$r" remote set-url origin "$url"
        else
            cx_run git -C "$r" remote add origin "$url"
        fi
        # git submodule add 建立的 origin **沒有 fetch refspec**。
        # 少了它，push -u 只會寫 branch.<b>.remote/merge，卻建不出
        # refs/remotes/origin/*，於是 %(upstream) 永遠是空的、
        # git status 也看不到 ahead/behind。set-url 修不了這件事。
        if [[ -z $(git -C "$r" config --get remote.origin.fetch || true) ]]; then
            cx_run git -C "$r" config --add remote.origin.fetch \
                '+refs/heads/*:refs/remotes/origin/*'
            cx_warn "$slug 的 origin 缺少 fetch refspec，已補上"
        fi
        cx_ok "$slug origin → $url"
    done < <(_git_repos_order)

    cx_info "接著執行：cx git push"
}

# ---------------------------------------------------------------------------
# 推送：子模組先，主庫最後
# ---------------------------------------------------------------------------
_git_push() {
    local force=0
    while (( $# )); do
        case $1 in
            --force) force=1; shift ;;
            *) cx_die "$EX_USAGE" "push: 未知參數 $1（只支援 --force）" ;;
        esac
    done

    _git_scan_secrets

    cx_step "推送前檢查"
    local r slug url
    while read -r r; do
        slug=$(_git_repo_slug "$r")
        url=$(git -C "$r" remote get-url origin 2>/dev/null || true)
        [[ -n $url ]] || cx_die "$EX_PRECOND" "$slug 沒有 origin（先跑 cx git remote-init）"
        printf '%s' "$url" | grep -qE "$CX_DENIED_REMOTE_RE" \
            && cx_die "$EX_PRECOND" "$slug 的 origin 在永久黑名單：$url"
        # cx git push 自己的白名單，與 pre-push hook 是兩回事
        #（hook 已於 2026-09-04 移除，這道還在）。
        # 保留的理由：cx git push 是「安全路徑」—— 它會掃祕密、排子模組順序、
        # 驗 gitlink，把它的目標限制在已知的三個 repo 是這條路徑的價值所在。
        # 但不能只是死掉，要告訴使用者原生路徑現在是通的。
        if ! printf '%s' "$url" | grep -qE "$CX_ALLOWED_REMOTE_RE"; then
            cx_error "$slug 的 origin 不在 cx git push 的白名單：$url"
            cx_dim "  允許的目標："
            cx_dim "$(cx_guard_allow_list)"
            cx_dim "  要推到其他遠端請用原生 git（pre-push hook 已移除，不會被攔）："
            cx_dim "      cx git scan-secrets && git -C $r push <遠端> <分支>"
            cx_dim "  先掃祕密不是形式 —— 三個 repo 都是 PUBLIC。"
            return "$EX_PRECOND"
        fi
        cx_ok "$slug → $url"
    done < <(_git_repos_order)

    cx_confirm --danger "推送到 GitHub（PUBLIC）" \
"即將推送三個 repo 到 $CX_GH_ORG：

  1. $CX_REPO_BACKEND    （子模組，先推）
  2. $CX_REPO_FRONTEND   （子模組，先推）
  3. $CX_REPO_MAIN       （主庫，最後推 —— gitlink 需要子模組的 commit 已存在於遠端）

三個 repo 都是 PUBLIC。祕密掃描已通過。

確定要推送嗎？" || return "$EX_ABORT"

    # ── --force 的額外閘門 ────────────────────────────────────────────────
    # 強制推送會**改寫遠端的歷史**。任何已經 clone 或 fork 的人，
    # 下一次 pull 會得到 non-fast-forward，必須自己 reset --hard 才能繼續；
    # 已經基於舊 commit 開的 PR 也會斷掉。
    # 唯一合理的使用時機是「歷史裡有東西必須消失」（祕密外洩、命名清理）。
    if (( force )); then
        cx_ask_typed "強制推送會改寫遠端歷史" \
"你正要對三個 **PUBLIC** repo 執行強制推送。

這會改寫遠端的 commit 歷史：
  • 已經 clone 的人下次 pull 會 non-fast-forward，必須 reset --hard
  • 基於舊 commit 的 PR / 分支會斷開
  • 舊的 commit SHA 永久失效（連結、issue 引用都會壞）

做這件事之前應該已經有完整備份（git bundle --all）。

確定的話，請輸入 REWRITE HISTORY。" "REWRITE HISTORY" || return "$EX_ABORT"
        cx_warn "強制推送模式：會用 --force-with-lease"
    fi

    local rc_all=0
    while read -r r; do
        slug=$(_git_repo_slug "$r")

        # ── detached HEAD 的處理 ─────────────────────────────────────────
        # clone --recurse-submodules 之後子模組一定是 detached HEAD，
        # 而 `git branch --show-current` 在 detached 時回**空字串**。
        # 原本直接把它丟給 `git push -u origin "$br"`，結果是
        #   fatal: invalid refspec ''
        # 而下面的驗證只檢查 refs/remotes/origin/<空>，當然也找不到，
        # 於是印出「已推送，但 remote-tracking ref 仍缺失」——
        # 聽起來像小問題，實際上那個 repo **根本沒推上去**。
        #
        # 這個組合特別危險：主庫最後推的時候會成功，於是遠端的 gitlink
        # 指向一個遠端不存在的子模組 commit。別人 clone 下來會是
        #   fatal: remote error: upload-pack: not our ref
        # 而且看不出是誰造成的。
        local br
        br=$(git -C "$r" branch --show-current)
        if [[ -z $br ]]; then
            local tracked
            tracked=$(git config -f "$CX_ROOT/.gitmodules" \
                        --get "submodule.$(basename "$r").branch" 2>/dev/null || echo main)
            cx_warn "$slug 是 detached HEAD —— 先 checkout 追蹤分支 $tracked"
            cx_run git -C "$r" checkout -q -B "$tracked" HEAD \
                || { cx_error "$slug 無法 checkout $tracked"; rc_all=1; continue; }
            br=$tracked
        fi

        local -a pushargs=(push -u origin "$br")
        # --force-with-lease 而不是 --force：遠端在我們 fetch 之後又被別人推過的話
        # 會被擋下來，而不是把別人的 commit 直接蓋掉。
        (( force )) && pushargs=(push -u --force-with-lease origin "$br")

        # ⚠ 不能用 ${force:+…}——那是「字串非空就展開」，而 force=0 是非空字串，
        # 所以普通推送也會印出「強制」。在整個工具最危險的操作上印錯訊息，
        # 會讓人以為自己剛剛改寫了遠端歷史（或反過來，對真正的強制推送麻木）。
        # 實際參數是由 (( force )) 決定的，這裡要用同一個判斷。
        local _fmark=''; (( force )) && _fmark='，強制'
        cx_info "推送 $slug（$br$_fmark）…"
        if ! CX_ALLOW_PUSH=1 cx_run git -C "$r" "${pushargs[@]}"; then
            # 推送失敗就要停下來，不能繼續推主庫 ——
            # 否則 gitlink 會指向遠端不存在的 commit。
            cx_error "$slug 推送失敗"
            [[ $r == "$CX_ROOT" ]] || cx_die "$EX_FAIL" \
                "子模組推送失敗，已中止 —— 主庫沒有推，gitlink 不會指向不存在的 commit"
            rc_all=1
            continue
        fi

        # 驗證 remote-tracking ref 真的建立了 —— 只看 push 的退出碼是不夠的
        if ! git -C "$r" rev-parse --verify --quiet "refs/remotes/origin/$br" >/dev/null; then
            cx_warn "$slug 沒有 refs/remotes/origin/$br，補一次 fetch"
            cx_run git -C "$r" fetch -q origin
        fi
        if git -C "$r" rev-parse --verify --quiet "refs/remotes/origin/$br" >/dev/null; then
            cx_ok "$slug 已推送（upstream: origin/$br）"
        else
            cx_error "$slug 的 remote-tracking ref 仍缺失 —— 推送可能沒有真的成功"
            rc_all=1
        fi
    done < <(_git_repos_order)

    # 最後驗證：主庫 gitlink 指到的 commit 必須真的存在於子模組的遠端。
    # 這是「推送順序」這條規則的實際檢查點，不是只靠順序正確就假設沒事。
    local c gl
    for c in backend frontend; do
        [[ -d $CX_ROOT/$c/.git || -f $CX_ROOT/$c/.git ]] || continue
        gl=$(git -C "$CX_ROOT" ls-tree HEAD "$c" | awk '{print $3}')
        [[ -n $gl ]] || continue
        if git -C "$CX_ROOT/$c" branch -r --contains "$gl" 2>/dev/null | grep -q origin/; then
            cx_ok "gitlink $c → ${gl:0:7} 已存在於遠端"
        else
            cx_error "gitlink $c → ${gl:0:7} **不存在於遠端**"
            cx_dim "  別人 clone 會得到 fatal: remote error: upload-pack: not our ref"
            cx_dim "  修法：cd $c && git push origin HEAD:main"
            rc_all=1
        fi
    done

    (( rc_all )) && { cx_error "推送未完全成功，見上列訊息"; return "$EX_FAIL"; }
    cx_ok "全部完成"
}
