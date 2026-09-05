#!/usr/bin/env bash
# cx git — Git 操作，含 push guard 與 GitHub 遠端管理。

_git_usage() {
    cat >&2 <<'TXT'
用法：cx git <子指令>

  status                各 repo 的分支 / 變更 / 領先落後（不連線，數字看上次 fetch）
  fetch                 三個 repo 一起 fetch --prune（唯讀，不動工作區）
  pull [--allow-merge]  三個 repo 一起更新（主庫先、子模組後；預設只允許快轉）
  sync                  子模組 checkout 追蹤分支（解決 clone 後 detached HEAD）
  commit [-m <訊息>] [--repo main|backend|frontend|all]
                        提交（子模組先、主庫 gitlink 後）；未給 -m 會引導產生
  save [-m <訊息>]      commit 的別名
  config identity|editor|show   git 身分與編輯器（三個 repo 一起設，或 --global）
  flow-init             補齊 gitflow 的分支拓撲（三個 repo 的 dev、submodule.recurse）
  feature start <名稱> --repo backend|frontend
                        在該子模組從 dev 開 feature/<名稱>（主庫不動）
  feature finish [名稱] --repo backend|frontend
                        合回該子模組的 dev，並讓主庫的 dev 跟上 gitlink
                        （不推送、不刪分支）
  feature list          列出兩個子模組的 feature/*
  hotfix start <名稱> --repo backend|frontend
                        同 feature，只是前綴不同 —— 用來把測試者回報的缺陷
                        與正在進行的功能分開追蹤。⚠ 從 dev 開、合回 dev，
                        **不碰 main**（與 gitflow 的 hotfix 不同）
  hotfix finish [名稱] --repo backend|frontend
  hotfix list           列出兩個子模組的 hotfix/*
  release [--skip-scan] dev → main（三個 repo 一起，並讓主庫的 gitlink 對齊
                        子模組的 main）。**唯一**會碰 main 的動詞。
                        不推送、不打 tag —— 那兩件事各有各的閘門與理由
  branch list           列出三個 repo 的分支與同步狀態
  branch new <名稱> [--repo …] [--from <ref>]
                        建立並切換到同名分支（預設從 dev 開）
  branch switch <名稱> [--repo …]  切換到指定分支
  branch delete <名稱> [--repo …]  刪除分支（需確認；拒絕當前分支與 main/dev）
  guard install|status|remove
  remote-set <URL...>       指到現成的 remote（不經過 gh）
  remote-init               用 gh 建立三個 public repo
                            （要乾跑用全域旗標： cx --dry-run git remote-init）
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
#
# 兩者都吃一個選用的過濾器（main|backend|frontend|all，預設 all）。
# 沒有它的話「只提交前端」這種再普通不過的需求就得離開 cx 用裸 git，
# 而裸 git 會繞過 push guard 與祕密掃描。
_git_repos_order() {                # _git_repos_order [main|backend|frontend|all]
    local f=${1:-all}
    case $f in
        all)      printf '%s\n' "$CX_ROOT/backend" "$CX_ROOT/frontend" "$CX_ROOT" ;;
        backend)  printf '%s\n' "$CX_ROOT/backend" ;;
        frontend) printf '%s\n' "$CX_ROOT/frontend" ;;
        main)     printf '%s\n' "$CX_ROOT" ;;
        *) cx_die "$EX_USAGE" "--repo 只能是 main|backend|frontend|all，收到：$f" ;;
    esac
}
_git_repos_super_first() {          # _git_repos_super_first [main|backend|frontend|all]
    local f=${1:-all}
    case $f in
        all)      printf '%s\n' "$CX_ROOT" "$CX_ROOT/backend" "$CX_ROOT/frontend" ;;
        backend)  printf '%s\n' "$CX_ROOT/backend" ;;
        frontend) printf '%s\n' "$CX_ROOT/frontend" ;;
        main)     printf '%s\n' "$CX_ROOT" ;;
        *) cx_die "$EX_USAGE" "--repo 只能是 main|backend|frontend|all，收到：$f" ;;
    esac
}

# 分支模型的單一來源（.cxroot）。給了預設值是為了讓舊的 .cxroot 也能跑。
_git_main_branch() { printf '%s' "${CX_GIT_MAIN_BRANCH:-main}"; }
_git_dev_branch()  { printf '%s' "${CX_GIT_DEV_BRANCH:-dev}"; }

# 受保護的分支：不可刪除、不可直接當作 feature 的目標
_git_is_protected_branch() {        # _git_is_protected_branch <名稱>
    [[ $1 == "$(_git_main_branch)" || $1 == "$(_git_dev_branch)" ]]
}

# 子模組此刻該站在哪一條分支上。
#
# ⚠ 不可以只讀 .gitmodules 的 branch。那個值只有**一個**分支名，而主庫有兩條線：
#   main（發布）與 dev（開發）。主庫站在 dev、gitlink 指向子模組的 dev commit，
#   而 .gitmodules 寫著 main —— 於是 cx git sync 會把子模組接到 main，跟 gitlink
#   對不起來。實測 2026-09-06：flow-init 之後跑 sync，兩個子模組都被接到 main，
#   即使當時工作正在 dev 線上。症狀是 git status 說子模組「有未提交的變更」，
#   而實際上只是它站錯了分支。
#
# 規則：主庫在 main 或 dev 上 → 子模組用同一條（兩條線各自自洽）；
#       其餘（主庫 detached、或未來有別的分支）→ 落回 .gitmodules 的宣告值，
#       再落回 main。.gitmodules 的 branch 從此只是 fallback 與 --remote 的目標。
_git_sub_target_branch() {          # _git_sub_target_branch <子模組名>
    local name=$1 super mainb devb
    mainb=$(_git_main_branch); devb=$(_git_dev_branch)
    super=$(git -C "$CX_ROOT" branch --show-current 2>/dev/null || echo '')
    if [[ $super == "$mainb" || $super == "$devb" ]]; then
        printf '%s' "$super"; return 0
    fi
    git config -f "$CX_ROOT/.gitmodules" --get "submodule.$name.branch" 2>/dev/null \
        || printf '%s' "$mainb"
}

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
        config)        _git_config "$@" ;;
        branch)        _git_branch "$@" ;;
        feature)       _git_feature "$@" ;;
        hotfix)        _git_hotfix "$@" ;;
        release)       _git_release "$@" ;;
        flow-init)     _git_flow_init ;;
        guard)         case ${1:-status} in
                           install) cx_guard_install ;;
                           status)  cx_guard_status ;;
                           remove)  cx_guard_remove ;;
                           *) cx_die "$EX_USAGE" "guard: 未知子指令 ${1:-}" ;;
                       esac ;;
        remote-init)   _git_remote_init "$@" ;;
        remote-set)    _git_remote_set "$@" ;;
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
# 移到 common.sh 成為 cx_is_repo_root —— archive.sh 與 fresh.sh 也需要同一個判準，
# 而它們載入不到 git.sh。這裡保留別名，避免動到既有的十幾個呼叫點。
_git_is_repo_root() { cx_is_repo_root "$@"; }

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
        b=$(_git_sub_target_branch "$c")

        if git -C "$CX_ROOT/$c" symbolic-ref -q HEAD >/dev/null 2>&1; then
            local cur; cur=$(git -C "$CX_ROOT/$c" branch --show-current)
            if [[ $cur == "$b" ]]; then
                cx_ok "$c 已在分支 $cur"
            elif _git_is_protected_branch "$cur"; then
                # 站在「另一條長期線」上 —— 例如主庫在 dev，子模組卻在 main。
                # 這種狀態不是有人正在上面工作，而是上一次 sync 讀 .gitmodules
                # 的單一 branch 值留下的（見 _git_sub_target_branch 的說明）。
                # 症狀：git status 說子模組有未提交變更，實際上只是站錯了線。
                # 這裡只在工作區乾淨時才切 —— 髒的話切過去會把改動帶走。
                if [[ -n $(git -C "$CX_ROOT/$c" status --porcelain) ]]; then
                    cx_warn "$c 在 $cur、應該在 $b，但工作區不乾淨 —— 沒有切換"
                    cx_dim "  先 cx git commit --repo $c，再跑一次 cx git sync"
                elif cx_run git -C "$CX_ROOT/$c" switch -q "$b" 2>/dev/null; then
                    cx_ok "$c：$cur → $b（跟上主庫目前的線）"
                else
                    cx_warn "$c 在 $cur、應該在 $b，但 $b 不存在 —— 先跑 cx git flow-init"
                fi
            else
                # feature/* 或 hotfix/*：有人正在上面工作，不要動它。
                cx_ok "$c 在工作分支 $cur（不動；主庫目前在 $b 線上）"
            fi
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
        # ⚠ 但 -B 有相反方向的危險：分支**領先** HEAD 時（gitlink 落後，
        #   例如你正站在別條線記錄的舊指標上），`checkout -B $b $head` 會把
        #   分支**倒退**到那個舊 commit，中間的 commit 只剩 reflog 找得到。
        #   實測 git 2.53：完全沒有警告，輸出還說 "Your branch is ahead of
        #   'origin/dev' by 2 commits" —— 那是它剛剛丟掉的那兩個。
        #
        #   所以要四向判斷，不是無條件 -B：
        #     相同        → 純接回（checkout）
        #     HEAD 領先   → -B 快轉（保住 detached 期間的 commit）
        #     分支領先    → **保持 detached**，請使用者自己決定
        #     分岔        → 保持 detached，報錯
        head=$(git -C "$CX_ROOT/$c" rev-parse HEAD)
        if ! git -C "$CX_ROOT/$c" rev-parse --verify --quiet "refs/heads/$b" >/dev/null; then
            # 分支還不存在：直接以目前的 HEAD 建出來，不可能丟東西
            if cx_run git -C "$CX_ROOT/$c" checkout -q -B "$b" "$head"; then
                cx_ok "$c → $b（新建，原本是 detached HEAD）"
            else
                cx_error "$c 建立 $b 失敗"; return "$EX_FAIL"
            fi
            continue
        fi
        local btip; btip=$(git -C "$CX_ROOT/$c" rev-parse "refs/heads/$b")
        if [[ $head == "$btip" ]]; then
            if cx_run git -C "$CX_ROOT/$c" checkout -q "$b"; then
                cx_ok "$c → $b（原本是 detached HEAD，內容相同）"
            else
                cx_error "$c 切換到 $b 失敗"; return "$EX_FAIL"
            fi
        elif git -C "$CX_ROOT/$c" merge-base --is-ancestor "$btip" "$head" 2>/dev/null; then
            cx_warn "$c 的 detached HEAD（${head:0:7}）領先 $b —— 用 -B 把分支帶過來，不丟 commit"
            if cx_run git -C "$CX_ROOT/$c" checkout -q -B "$b" "$head"; then
                cx_ok "$c → $b（快轉）"
            else
                cx_error "$c 切換到 $b 失敗"; return "$EX_FAIL"
            fi
        elif git -C "$CX_ROOT/$c" merge-base --is-ancestor "$head" "$btip" 2>/dev/null; then
            cx_warn "$c 保持 detached —— $b（${btip:0:7}）比目前的 gitlink（${head:0:7}）新"
            cx_dim "  硬切過去會**倒退** $b，中間的 commit 只剩 reflog 找得到。"
            cx_dim "  你大概是想要其中一個："
            cx_dim "    讓主庫跟上子模組： cx git commit --repo main -m \"chore($c): 更新 gitlink\""
            cx_dim "    讓子模組回到 gitlink： git -C $c checkout $b   （確定要放棄那些 commit 才做）"
        else
            cx_error "$c 的 detached HEAD 與 $b 已經分岔 —— 保持 detached，請自己決定怎麼合"
            cx_dim "  git -C $c log --oneline --graph HEAD $b"
            return "$EX_FAIL"
        fi
    done
}

# ── git 身分與編輯器 ────────────────────────────────────────────────────────
#
# 為什麼需要這一段：git 沒有 user.name/user.email 時 commit 會失敗，而本專案
# 有三個 repo，逐個 `git -C … config` 是很容易漏掉一個的那種事。
# fresh.sh 的 PF-08 只**檢查**、只看主庫，而且只印出建議指令；沒有任何動詞會設。

# 三個 repo 都要有身分才算數。回傳 0/1，訊息寫得可以直接照做。
_git_identity_ok() {
    local r slug missing=()
    while read -r r; do
        [[ -d $r/.git || -f $r/.git ]] || continue
        slug=$(_git_repo_slug "$r")
        git -C "$r" config user.name  >/dev/null 2>&1 \
            && git -C "$r" config user.email >/dev/null 2>&1 \
            || missing+=("$slug")
    done < <(_git_repos_order all)
    (( ${#missing[@]} == 0 )) && return 0
    cx_error "下列 repo 沒有 git 身分（user.name / user.email）：${missing[*]}"
    cx_dim "  設定： cx git config identity --name \"你的名字\" --email you@example.com"
    cx_dim "  （加 --global 寫進 ~/.gitconfig，不加就只寫這三個 repo）"
    return 1
}

_git_config_identity() {
    local name='' email='' global=0
    while (( $# )); do
        case $1 in
            --name)   [[ -n ${2:-} ]] || cx_die "$EX_USAGE" "--name 需要值"; name=$2; shift 2 ;;
            --email)  [[ -n ${2:-} ]] || cx_die "$EX_USAGE" "--email 需要值"; email=$2; shift 2 ;;
            --global) global=1; shift ;;
            *) cx_die "$EX_USAGE" "config identity: 未知參數 $1" ;;
        esac
    done
    # 沒給就互動問；非互動又沒給就報用法錯誤（不要猜）
    if [[ -z $name ]]; then
        if cx_interactive; then name=$(cx_ask_line "git 身分" "user.name（顯示在每一個 commit 上）：" \
            "$(git config --global user.name 2>/dev/null)") || return "$EX_ABORT"
        else cx_die "$EX_USAGE" "非互動環境請給 --name"; fi
    fi
    if [[ -z $email ]]; then
        if cx_interactive; then email=$(cx_ask_line "git 身分" "user.email：" \
            "$(git config --global user.email 2>/dev/null)") || return "$EX_ABORT"
        else cx_die "$EX_USAGE" "非互動環境請給 --email"; fi
    fi
    # git 自己不驗 email 格式，這裡只擋明顯打錯的（沒有 @、有空白）。
    # 原本要求 @ 之後一定有點，會擋掉 dev@localhost 這類內網位址 ——
    # 而 _git_identity_ok 是 cx git commit 的前置條件，擋掉的後果是
    # 使用者只好改用裸 git，繞過這個三 repo 一起設的工具。
    [[ $email == *@* && $email != *[[:space:]]* ]] \
        || cx_die "$EX_USAGE" "email 看起來不對（需要 @、不能有空白）：$email"

    if (( global )); then
        cx_run git config --global user.name  "$name" || return "$EX_FAIL"
        cx_run git config --global user.email "$email" || return "$EX_FAIL"
        cx_ok "已寫入 ~/.gitconfig：$name <$email>"
        return "$EX_OK"
    fi
    local r slug
    while read -r r; do
        [[ -d $r/.git || -f $r/.git ]] || { cx_dim "$(_git_repo_slug "$r") 還不是 git repo，略過"; continue; }
        slug=$(_git_repo_slug "$r")
        cx_run git -C "$r" config user.name  "$name"  || { cx_error "$slug 設定失敗"; return "$EX_FAIL"; }
        cx_run git -C "$r" config user.email "$email" || { cx_error "$slug 設定失敗"; return "$EX_FAIL"; }
        cx_ok "$slug → $name <$email>"
    done < <(_git_repos_order all)
}

# 預設編輯器候選：$GIT_EDITOR → $VISUAL → $EDITOR → code --wait → nano → vi
# vi 一定存在，所以這個函式不會回傳空字串。
#
# ⚠ 會跳過「不是編輯器的編輯器」。CI、容器映像與各種 harness 常把 EDITOR
#   設成 true / false / : / cat 之類的 no-op，讓需要編輯器的程式不要卡住。
#   把那種值寫進 core.editor 的後果是**commit 訊息永遠是空的**，
#   而 git 只會說 "Aborting commit due to empty commit message"，
#   完全指不到是 core.editor 的問題。（2026-09-05 在本機實測到 EDITOR=true。）
_git_editor_is_noop() {
    case ${1%% *} in
        true|false|:|cat|echo|/bin/true|/bin/false|/usr/bin/true|/usr/bin/false) return 0 ;;
        *) return 1 ;;
    esac
}

_git_editor_default() {
    local c
    for c in "${GIT_EDITOR:-}" "${VISUAL:-}" "${EDITOR:-}"; do
        [[ -n $c ]] || continue
        _git_editor_is_noop "$c" && continue
        printf '%s' "$c"; return 0
    done
    cx_have code && { printf 'code --wait'; return 0; }
    cx_have nano && { printf 'nano'; return 0; }
    printf 'vi'
}

_git_config_editor() {
    local ed='' global=0
    while (( $# )); do
        case $1 in
            --global) global=1; shift ;;
            -*) cx_die "$EX_USAGE" "config editor: 未知參數 $1" ;;
            *)  ed=$1; shift ;;
        esac
    done
    if [[ -z $ed ]]; then
        local sug; sug=$(_git_editor_default)
        if cx_interactive; then
            ed=$(cx_ask_line "git 編輯器" \
                "core.editor —— 寫 commit 訊息、互動式 rebase 時開的編輯器：" "$sug") \
                || return "$EX_ABORT"
        else
            ed=$sug
            cx_info "未指定編輯器，用推導出的預設值：$ed"
        fi
    fi
    [[ -n $ed ]] || cx_die "$EX_USAGE" "編輯器不能是空的"
    # 只驗第一個詞（"code --wait" 的第一個詞才是執行檔）
    local bin=${ed%% *}
    cx_have "$bin" || cx_warn "找不到 $bin —— 還是會寫進去，但用到時會失敗"
    if _git_editor_is_noop "$ed"; then
        cx_error "「$ed」不是編輯器 —— 用它當 core.editor 會讓 commit 訊息永遠是空的"
        cx_dim "  真的要這樣設就直接下： git config core.editor \"$ed\""
        return "$EX_USAGE"
    fi

    if (( global )); then
        cx_run git config --global core.editor "$ed" || return "$EX_FAIL"
        cx_ok "已寫入 ~/.gitconfig：core.editor = $ed"
        return "$EX_OK"
    fi
    local r slug
    while read -r r; do
        [[ -d $r/.git || -f $r/.git ]] || { cx_dim "$(_git_repo_slug "$r") 還不是 git repo，略過"; continue; }
        slug=$(_git_repo_slug "$r")
        cx_run git -C "$r" config core.editor "$ed" || { cx_error "$slug 設定失敗"; return "$EX_FAIL"; }
        cx_ok "$slug → core.editor = $ed"
    done < <(_git_repos_order all)
}

_git_config() {
    local sub=${1:-show}; shift || true
    case $sub in
        identity) _git_config_identity "$@" ;;
        editor)   _git_config_editor "$@" ;;
        show)     local r slug
                  while read -r r; do
                      [[ -d $r/.git || -f $r/.git ]] || continue
                      slug=$(_git_repo_slug "$r")
                      printf '\n%s%s%s\n' "$C_BLU" "$slug" "$C_RST"
                      printf '  user.name   %s\n' "$(git -C "$r" config user.name   2>/dev/null || echo '（未設定）')"
                      printf '  user.email  %s\n' "$(git -C "$r" config user.email  2>/dev/null || echo '（未設定）')"
                      printf '  core.editor %s\n' "$(git -C "$r" config core.editor 2>/dev/null || echo '（未設定，git 會用 $EDITOR 或 vi）')"
                  done < <(_git_repos_order all)
                  printf '\n' ;;
        -h|--help) _git_usage ;;
        *) cx_die "$EX_USAGE" "config: 未知子指令 $sub（identity|editor|show）" ;;
    esac
}

_git_commit() {
    local msg='' amend=0 no_verify_scan=0 repo=all
    while (( $# )); do
        case $1 in
            -m|--message) [[ -n ${2:-} ]] || cx_die "$EX_USAGE" "-m 需要訊息"
                          msg=$2; shift 2 ;;
            --repo)       [[ -n ${2:-} ]] || cx_die "$EX_USAGE" "--repo 需要值"
                          repo=$2; shift 2 ;;
            --amend)      amend=1; shift ;;
            --skip-scan)  no_verify_scan=1; shift ;;
            *)            cx_die "$EX_USAGE" "commit: 未知參數 $1" ;;
        esac
    done
    _git_repos_order "$repo" >/dev/null    # 提早驗證 --repo 的值

    # git 沒有身分就 commit 會失敗，而下面每一步原本都不檢查退出碼 ——
    # 於是「Please tell me who you are」會被印成「✔ 已提交」。先擋在這裡。
    _git_identity_ok || return "$EX_PRECOND"

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

    local _repo_note=''
    [[ $repo != all ]] && _repo_note="（僅 $repo）"
    cx_step "提交$_repo_note"
    local r slug changed=0 n super_n=0 saw_super=0
    # ⚠ 每一步都要檢查退出碼。
    #   2026-09-05 實測：pre-commit hook 失敗時，原本的程式碼照樣印
    #   「✔ 主庫已提交（4 項，含 gitlink）」並回傳 0，而 repo 裡一個 commit 都沒有。
    #   cx_run 會回傳指令的退出碼，但沒有人接 —— 而本專案整條呼叫鏈的 errexit
    #   都被 dispatcher 的 `|| rc=$?` 關掉了，所以「不接就等於吞掉」。
    #
    # 子模組必須先提交：主庫的 gitlink 指向子模組的 commit，
    # 反過來會讓 gitlink 指向一個尚不存在的 commit。
    while read -r r; do
        slug=$(_git_repo_slug "$r")
        [[ -d $r ]] || continue
        n=$(git -C "$r" status --porcelain | wc -l)
        if [[ $r == "$CX_ROOT" ]]; then saw_super=1; super_n=$n; fi
        if (( n > 0 )); then
            git -C "$r" status --short | sed 's/^/      /' >&2
            cx_run git -C "$r" add -A \
                || { cx_error "$slug：git add 失敗"; return "$EX_FAIL"; }
            if (( amend )); then
                cx_run git -C "$r" commit -q --amend --no-edit \
                    || { cx_error "$slug：git commit --amend 失敗（上面是 git 的訊息）"; return "$EX_FAIL"; }
            else
                cx_run git -C "$r" commit -q -m "$msg" \
                    || { cx_error "$slug：git commit 失敗（上面是 git 的訊息）"; return "$EX_FAIL"; }
            fi
            if [[ $r == "$CX_ROOT" ]]; then
                cx_ok "$slug 已提交（$n 項，含 gitlink）"
            else
                cx_ok "$slug 已提交（$n 項）"
            fi
            changed=1
        else
            cx_dim "$slug 無變更"
        fi
    done < <(_git_repos_order "$repo")

    if (( saw_super )) && (( super_n == 0 )) && (( changed )); then
        cx_warn "子模組已提交但主庫的 gitlink 沒有變化 —— 請確認 submodule 指標是否正確"
    fi
    if ! (( changed )); then
        cx_warn "沒有任何東西需要提交"
        return "$EX_OK"
    fi
    # 只提交單一子模組時，主庫的 gitlink 會停在舊的 commit —— 講清楚，不要讓人以為做完了
    if [[ $repo == backend || $repo == frontend ]]; then
        cx_warn "只提交了 $repo —— 主庫的 gitlink 仍指向舊的 commit"
        cx_dim "  要讓主庫跟上： cx git commit --repo main -m \"chore: 更新 $repo 指標\""
    fi
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
# --repo 與 --from 由這裡統一解析，再交給下面三個實作。
# 解析結果放進兩個 global：把它們當參數傳會讓每個實作的簽章都變長，
# 而這三個函式本來就只從這裡進得去。
_GIT_BRANCH_REPO=all
_GIT_BRANCH_FROM=''
_git_branch_parse_opts() {          # 回傳剩下的位置參數（用 _GIT_BRANCH_ARGS）
    _GIT_BRANCH_REPO=all; _GIT_BRANCH_FROM=''
    _GIT_BRANCH_ARGS=()
    while (( $# )); do
        case $1 in
            --repo) [[ -n ${2:-} ]] || cx_die "$EX_USAGE" "--repo 需要值"
                    _GIT_BRANCH_REPO=$2; shift 2 ;;
            --from) [[ -n ${2:-} ]] || cx_die "$EX_USAGE" "--from 需要 ref"
                    _GIT_BRANCH_FROM=$2; shift 2 ;;
            *)      _GIT_BRANCH_ARGS+=("$1"); shift ;;
        esac
    done
    _git_repos_order "$_GIT_BRANCH_REPO" >/dev/null
}

_git_branch() {
    local sub=${1:-list}; shift || true
    case $sub in
        list)   _git_branch_list ;;
        -h|--help) _git_usage; return 0 ;;
        new|switch|delete)
                _git_branch_parse_opts "$@"
                # --from 只對 new 有意義。switch/delete 原本「收得下然後丟掉」——
                # 被解析器接受卻毫無作用的旗標，比直接報錯更糟：
                # 使用者以為自己指定了起點，實際上什麼都沒發生。
                [[ $sub == new || -z ${_GIT_BRANCH_FROM:-} ]] \
                    || cx_die "$EX_USAGE" "branch $sub 不吃 --from（只有 branch new 有起點的概念）"
                [[ -n ${_GIT_BRANCH_ARGS[0]:-} ]] \
                    || cx_die "$EX_USAGE" "branch $sub 需要名稱"
                "_git_branch_$sub" "${_GIT_BRANCH_ARGS[0]}" ;;
        *)      cx_die "$EX_USAGE" "branch: 未知子指令 $sub（list|new|switch|delete）" ;;
    esac
}

# ── gitflow ─────────────────────────────────────────────────────────────────
#
# feature 與 hotfix 都是「從 dev 開、合回 dev」，拓撲完全相同，所以共用實作
# （見 _git_flow_line）。兩者都不動 main —— main 只由 cx git release 碰。
#
# ⚠ 本專案的 hotfix 不是 gitflow 的 hotfix（那個從 main 開、合回 main + dev、配 tag）。
#   這裡的 hotfix 只是「另一個前綴」，用途是把測試者回報的缺陷與正在進行的功能
#   分開追蹤。不打 tag —— 本專案沒有版本號策略。
# ── gitflow 的分支拓撲 ──────────────────────────────────────────────────────
#
# 冪等，只補缺的。cx git flow-init 與 _fresh_git_init 共用它，
# 免得「新專案長什麼樣」與「舊專案補成什麼樣」變成兩份會漂移的定義。
#
#   主庫       main ← dev
#   backend    main ← dev
#   frontend   main ← dev
#
# 主庫**不建** feature/* 或 hotfix/*，那只在子模組裡開（見 _git_flow_line 的說明）。
_git_flow_ensure_branches() {       # _git_flow_ensure_branches [--dry]
    local dry=0; [[ ${1:-} == --dry ]] && dry=1
    local main_br dev_br r slug made=0
    main_br=$(_git_main_branch); dev_br=$(_git_dev_branch)

    while read -r r; do
        [[ -e $r/.git ]] || continue
        slug=$(_git_repo_slug "$r")
        if git -C "$r" show-ref --verify --quiet "refs/heads/$dev_br"; then
            (( dry )) && cx_dim "  $slug：已有 $dev_br"
            continue
        fi
        # 起點該用哪一個，不能直接假設 main。
        #
        # 子模組被 gitlink 釘住時常常是 detached，而本地的 main 可能是**舊的**
        #（實測本專案：backend 的 HEAD 比本地 main 多 2 個 commit，origin/main
        #  才等於 gitlink）。從那個 main 開 dev，等於讓開發線一出生就落後兩步。
        #
        # 規則：main 不存在 → 用 HEAD；HEAD 是 main 的後代 → 用 HEAD（比較新）；
        #       其餘（HEAD 是 main 的祖先或兩者分岔）→ 用 main。
        local base=$main_br
        if ! git -C "$r" show-ref --verify --quiet "refs/heads/$main_br"; then
            base=''
        elif git -C "$r" rev-parse --verify --quiet HEAD >/dev/null \
             && git -C "$r" merge-base --is-ancestor "$main_br" HEAD 2>/dev/null \
             && [[ $(git -C "$r" rev-parse HEAD) != $(git -C "$r" rev-parse "$main_br") ]]; then
            base=HEAD
            cx_warn "$slug 的 $main_br 落後目前的 HEAD —— $dev_br 從 HEAD 開（gitlink 所在）"
        fi
        if (( dry )); then
            cx_dim "  $slug：建立 $dev_br${base:+（從 $base）}"
            made=1; continue
        fi
        # ⚠ 用 git branch 不是 switch -c：branch 只寫 ref、不動工作區，
        #   所以不會觸發 submodule.recurse 把子模組打成 detached（實測確認）。
        if [[ -n $base ]]; then
            cx_run git -C "$r" branch "$dev_br" "$base" || return 1
        else
            cx_run git -C "$r" branch "$dev_br" || return 1
        fi
        cx_ok "$slug：建立 $dev_br${base:+（從 $base）}"
        made=1
    done < <(_git_repos_super_first all)

    # submodule.recurse 不可以只靠環境。git.sh 有五處、文件有三處拿
    # 「本專案設了 submodule.recurse=true」當作排序理由，而實測
    # git config --show-origin --get-all submodule.recurse → rc=1（根本沒設）。
    # cx 自己一律明確帶 --recurse-submodules，這裡設定是為了讓**裸 git**
    # 的行為跟 cx 一致 —— 否則手動 git switch 會留下與 gitlink 不符的子模組。
    if [[ $(git -C "$CX_ROOT" config --get submodule.recurse 2>/dev/null || echo '') != true ]]; then
        if (( dry )); then
            cx_dim "  主庫：設定 submodule.recurse=true"
        else
            cx_run git -C "$CX_ROOT" config submodule.recurse true \
                && cx_ok "主庫：submodule.recurse=true"
        fi
        made=1
    fi
    (( made )) || cx_ok "分支拓撲已經是完整的，沒有要補的"
    return 0
}

_git_flow_init() {
    cx_step "gitflow 分支拓撲"
    cx_dim "  主庫      $(_git_main_branch) ← $(_git_dev_branch)                        （不開工作分支）"
    cx_dim "  backend   $(_git_main_branch) ← $(_git_dev_branch) ← feature/* | hotfix/*"
    cx_dim "  frontend  $(_git_main_branch) ← $(_git_dev_branch) ← feature/* | hotfix/*"
    cx_dim ""
    cx_dim "將補上下列缺的東西："
    _git_flow_ensure_branches --dry
    cx_confirm "建立缺少的分支與設定" \
"只會**新增**缺少的分支，不會刪除、不會合併、不會切換目前所在的分支。
可以重複執行。

繼續嗎？" || return "$EX_ABORT"
    _git_flow_ensure_branches || return "$EX_FAIL"
    cx_info "接著： cx git feature start <名稱> --repo backend|frontend"
    cx_dim  "        （緊急修正用 cx git hotfix start —— 拓撲相同，只是前綴不同）"
}

# 側別解析：工作分支只存在於子模組，所以一定要知道是哪一邊。
# 順序：明確 --repo > 呼叫時的 cwd 落在哪個子模組 > 要求指名。
# 不用「猜主庫目前在哪條分支」—— 主庫根本沒有工作分支可以猜。
_git_flow_side() {                  # _git_flow_side <明確指定或空> <kind>
    local want=$1 kind=${2:-feature}
    if [[ -n $want ]]; then
        case $want in
            backend|frontend) printf '%s' "$want"; return 0 ;;
            *) cx_die "$EX_USAGE" "--repo 只能是 backend 或 frontend（$kind 分支只開在子模組裡），收到：$want" ;;
        esac
    fi
    local pwd_real; pwd_real=$(cd "${CX_INVOKE_PWD:-$PWD}" 2>/dev/null && pwd -P || printf '%s' "$PWD")
    local c
    for c in backend frontend; do
        [[ $pwd_real == "$CX_ROOT/$c" || $pwd_real == "$CX_ROOT/$c"/* ]] && { printf '%s' "$c"; return 0; }
    done
    cx_die "$EX_USAGE" "$(printf '%s\n' \
        "要指定哪一邊： cx git $kind start <名稱> --repo backend|frontend" \
        "" \
        "  $kind 分支只開在子模組裡（backend / frontend）。" \
        "  主庫是基礎設施倉庫，只有 $(_git_main_branch) 與 $(_git_dev_branch) 兩條線，" \
        "  它的 $(_git_dev_branch) 會在 $kind finish 時同步跟上子模組的 gitlink。" \
        "" \
        "  或者 cd 進 backend/ 或 frontend/ 再下指令，就不用打 --repo。")"
}

# ── gitflow ─────────────────────────────────────────────────────────────────
#
# 分支模型（2026-09-05 定案，2026-09-06 加入 hotfix 與 release）：
#
#   主庫       main ← dev                            **沒有 feature/* 也沒有 hotfix/***
#   backend    main ← dev ← feature/* | hotfix/*
#   frontend   main ← dev ← feature/* | hotfix/*
#
# 為什麼主庫不開工作分支：實測過「前端與後端各自推進自己那一顆 gitlink，
# 再合回同一條 dev」—— 兩次合併都 rc=0，零衝突，因為那是**不同路徑**。
# 真正會衝突的是共用基礎設施（bin/ docker/ ansible/ docs/，實測 CONFLICT）。
# 在主庫也開 feature、或把 dev 拆成兩條長期線，都只會讓後者更難合，
# 卻對前者毫無幫助 —— 那本來就不會衝突。
#
# ⚠ 本專案的 hotfix **不是 gitflow 的 hotfix**。
#   gitflow：hotfix 從 main 開、合回 main + dev，配版本號與 tag。
#   本專案：hotfix 從 dev 開、合回 dev —— 拓撲與 feature **完全相同**，
#           差別只有前綴。用途是把「測試者回報的缺陷」與「正在進行的功能」
#           分開追蹤，不是發布機制。
#   為什麼不做 gitflow 版本：本專案沒有版本號策略，做一半的 release 流程
#   比沒有更糟。dev → main 由 cx git release 負責，它也不打 tag。
#
# feature 與 hotfix 共用同一組實作。泛化刻意**只做在這一層**（前綴、訊息文字），
# 底下的 _git_flow_start / _git_flow_finish 一個字都沒改 —— 那兩支裡面的合併
# 順序是實測換來的，任何「順手重構一下」都是回歸的入口。
_git_flow_line() {                  # _git_flow_line <feature|hotfix> [子指令...]
    local kind=$1; shift
    local pfx="$kind/"
    local sub=${1:-}; shift || true
    local dev; dev=$(_git_dev_branch)

    # 先把 --repo 從參數裡撈出來（這一族的旗標只有這一個）
    local want=''
    local -a rest=()
    while (( $# )); do
        case $1 in
            --repo) [[ -n ${2:-} ]] || cx_die "$EX_USAGE" "--repo 需要值"
                    want=$2; shift 2 ;;
            *)      rest+=("$1"); shift ;;
        esac
    done
    set -- "${rest[@]+"${rest[@]}"}"

    case $sub in
        start)
            [[ -n ${1:-} ]] || cx_die "$EX_USAGE" \
                "$kind start 需要名稱（例：cx git $kind start login --repo backend）"
            local n=$1
            [[ $n == "$pfx"* ]] || n="$pfx$n"
            local side; side=$(_git_flow_side "$want" "$kind") || return "$EX_USAGE"
            _git_flow_start "$n" "$side" "$dev" ;;
        finish)
            local side; side=$(_git_flow_side "$want" "$kind") || return "$EX_USAGE"
            # 沒給名稱就用該子模組目前所在的分支（不是主庫的 —— 主庫沒有工作分支）
            local cur; cur=$(git -C "$CX_ROOT/$side" branch --show-current 2>/dev/null || echo '')
            local n=${1:-$cur}
            [[ -n $n ]] || cx_die "$EX_USAGE" "$kind finish 需要名稱，或先把 $side 切到那個分支上"
            [[ $n == "$pfx"* ]] || n="$pfx$n"
            _git_flow_finish "$n" "$side" "$dev" ;;
        list)
            local c
            for c in backend frontend; do
                [[ -e $CX_ROOT/$c/.git ]] || continue
                printf '\n%s%s%s\n' "$C_BLU" "$(_git_repo_slug "$CX_ROOT/$c")" "$C_RST"
                git -C "$CX_ROOT/$c" for-each-ref \
                    --format='  %(refname:short)  %(committerdate:relative)' \
                    "refs/heads/$pfx*" 2>/dev/null || true
            done
            printf '\n' ;;
        -h|--help|'')
            cx_dim "cx git $kind start <名稱> --repo backend|frontend"
            cx_dim "cx git $kind finish [名稱] --repo backend|frontend"
            cx_dim "cx git $kind list"
            cx_dim ""
            cx_dim "$kind 分支只開在子模組裡；主庫的 $(_git_dev_branch) 會在 finish 時同步 gitlink。"
            [[ $kind == hotfix ]] && cx_dim \
                "⚠ 本專案的 hotfix 從 $(_git_dev_branch) 開、合回 $(_git_dev_branch)，**不碰 $(_git_main_branch)** —— 與 gitflow 的 hotfix 不同。"
            : ;;
        *) cx_die "$EX_USAGE" "$kind: 未知子指令 $sub（start|finish|list）" ;;
    esac
}

_git_feature() { _git_flow_line feature "$@"; }
_git_hotfix()  { _git_flow_line hotfix  "$@"; }

_git_flow_start() {                 # _git_flow_start <分支> <側別> <dev>
    local n=$1 side=$2 dev=$3
    local d="$CX_ROOT/$side" slug; slug=$(_git_repo_slug "$d")
    [[ -e $d/.git ]] || cx_die "$EX_PRECOND" "$side 還不是 git repo"
    git -C "$d" show-ref --verify --quiet "refs/heads/$n" \
        && cx_die "$EX_PRECOND" "$slug 已經有分支 $n"
    [[ -z $(git -C "$d" status --porcelain) ]] \
        || cx_die "$EX_PRECOND" "$slug 有未提交變更 —— 先 cx git commit --repo $side"

    local base=$dev
    if ! git -C "$d" show-ref --verify --quiet "refs/heads/$dev"; then
        cx_warn "$slug 沒有 $dev 分支 —— 從目前的 HEAD 開"
        cx_dim "  要走完整的 gitflow： cx git flow-init"
        base=''
    fi
    cx_step "在 $slug 建立 $n${base:+（從 $base）}"
    if [[ -n $base ]]; then
        cx_run git -C "$d" switch -c "$n" "$base" || return "$EX_FAIL"
    else
        cx_run git -C "$d" switch -c "$n" || return "$EX_FAIL"
    fi
    cx_ok "$slug → $n"
    # 種類從分支名推導（feature/x → feature），不要寫死 —— hotfix 走的是同一支。
    cx_info "主庫沒有動 —— 它的 $dev 會在 cx git ${n%%/*} finish 時跟上 gitlink"
}

# 合回該子模組的 dev，然後讓主庫的 dev 同步指向新的 commit。
# **不推送**、也不刪分支 —— 那兩件事各自有自己的閘門，
# 混進來會讓 finish 變成一個「做了三件不可逆的事」的動詞。
_git_flow_finish() {                # _git_flow_finish <分支> <側別> <dev>
    local n=$1 side=$2 dev=$3
    local d="$CX_ROOT/$side" slug; slug=$(_git_repo_slug "$d")

    git -C "$d" show-ref --verify --quiet "refs/heads/$n" \
        || cx_die "$EX_PRECOND" "$slug 沒有分支 $n"
    git -C "$d" show-ref --verify --quiet "refs/heads/$dev" \
        || cx_die "$EX_PRECOND" "$slug 沒有 $dev 分支（先 cx git flow-init）"
    [[ -z $(git -C "$d" status --porcelain) ]] \
        || cx_die "$EX_PRECOND" "$slug 有未提交變更 —— 先 cx git commit --repo $side"
    # ⚠ 主庫**本來就會**有髒的 gitlink —— 子模組剛剛提交了 feature 的工作，
    #   那正是這個動詞要記錄的東西。所以只能要求「除了兩顆 gitlink 以外都乾淨」，
    #   不能要求整個主庫乾淨（第一版寫成後者，於是 finish 永遠過不了自己的前置檢查）。
    [[ -z $(git -C "$CX_ROOT" status --porcelain -- . ':(exclude)backend' ':(exclude)frontend') ]] \
        || { cx_error "主庫有 gitlink 以外的未提交變更 —— 先處理掉，finish 之後要提交 gitlink"
             git -C "$CX_ROOT" status --short -- . ':(exclude)backend' ':(exclude)frontend' \
                 | sed 's/^/      /' >&2
             return "$EX_PRECOND"; }
    git -C "$CX_ROOT" show-ref --verify --quiet "refs/heads/$dev" \
        || cx_die "$EX_PRECOND" "主庫沒有 $dev 分支（先 cx git flow-init）"

    cx_confirm "把 $n 合併回 $side 的 $dev" \
"$slug：切到 $dev → merge --no-ff $n
主庫：切到 $dev → 只更新 $side 這一顆 gitlink 並提交

**不會**推送，也**不會**刪掉 $n。
推送請用 cx git push；刪分支請用 cx git branch delete $n --repo $side。

繼續嗎？" || return "$EX_ABORT"

    # ⚠ 順序：主庫要**先**站到 dev 上，再去動子模組。
    # 反過來的話，主庫帶 --recurse-submodules 切分支時會把剛合併好的子模組
    # 重設回 dev 記錄的舊 gitlink（實測：只有 gitlink 真的不同的那個會被 detach），
    # 於是後面 git add 記進去的是**舊的** sha。
    cx_step "合併 $n → $dev"
    local cur_super; cur_super=$(git -C "$CX_ROOT" branch --show-current 2>/dev/null || echo '')
    if [[ $cur_super != "$dev" ]]; then
        # ⚠ 只有在主庫還沒站在 dev 上時才切，而且**不帶** --recurse-submodules。
        # 帶了的話會把子模組重設回 dev 記錄的舊 gitlink —— 而此刻子模組上正是
        # 我們要保住的 feature 工作。這裡只需要主庫的 HEAD 移動，工作區不必動。
        cx_run git -C "$CX_ROOT" switch "$dev" \
            || { cx_error "主庫切到 $dev 失敗（有 gitlink 以外的變更？）"; return "$EX_FAIL"; }
    fi

    cx_run git -C "$d" switch "$dev" || { cx_error "$slug 切到 $dev 失敗"; return "$EX_FAIL"; }
    cx_run git -C "$d" merge --no-ff -m "Merge $n into $dev" "$n" \
        || { cx_error "$slug 合併失敗 —— 解完衝突後自己 git commit，不要再跑一次 finish"
             return "$EX_FAIL"; }
    cx_ok "$slug：$n → $dev"

    # 主庫只記這一顆 gitlink。用明確的 pathspec 而不是 add -A ——
    # 另一邊的 gitlink 可能是髒的（例如同事正在推進），不該被順手掃進這個 commit。
    cx_step "主庫同步 $side 的 gitlink"
    if [[ -z $(git -C "$CX_ROOT" status --porcelain -- "$side") ]]; then
        cx_ok "主庫的 $side gitlink 已經是最新的，不需要提交"
    else
        cx_run git -C "$CX_ROOT" add -- "$side" || return "$EX_FAIL"
        cx_run git -C "$CX_ROOT" commit -q -m "chore($side): 更新 gitlink 至 $dev（$n）" \
            || { cx_error "主庫提交 gitlink 失敗"; return "$EX_FAIL"; }
        cx_ok "主庫：$side → $(git -C "$d" rev-parse --short HEAD)"
    fi

    local other; other=$([[ $side == backend ]] && printf frontend || printf backend)
    [[ -n $(git -C "$CX_ROOT" status --porcelain -- "$other") ]] \
        && cx_warn "$other 的 gitlink 也有變化，但不屬於這次 finish —— 已排除，沒有進這個 commit"

    _git_assert_no_detached main || return "$EX_FAIL"
    cx_info "已合併。推送： cx git push；刪掉 feature： cx git branch delete $n --repo $side"
}

# ── release：dev → main ─────────────────────────────────────────────────────
#
# 這是**唯一**會碰 main 的動詞。在它出現之前（2026-09-06），cx git 的 15 個
# 子指令裡沒有任何一個把 dev 合進 main —— main 上的 merge commit 是手動做的，
# 而部署流程說「切換至 main 線」。也就是說部署的人切過去拿到的永遠是舊的，
# 除非有人記得手動合。
#
# ⚠ 順序與 gitlink 語意（兩者都不是可以憑直覺改的）：
#
#   1. 主庫先切到 main，**不帶 --recurse-submodules**。
#      帶了的話會把子模組拉到 main 記錄的舊 gitlink，而下一步正要在子模組上
#      合併 —— 合的就會是舊的東西。理由與 _git_flow_finish 完全相同。
#   2. 子模組各自 switch main → merge --no-ff dev。
#   3. 主庫 merge --no-ff dev。此刻主庫 main 的 gitlink 是**從 dev 帶過來的**，
#      也就是指向子模組 dev 的 tip。
#   4. 把 gitlink 改指到子模組 **main 的 tip**，再 commit。
#      為什麼必須有這一步：--no-ff 讓子模組的 main 多一個 merge commit，
#      所以 main tip ≠ dev tip。而 .gitmodules 的追蹤分支是 main、
#      _git_sub_target_branch() 在主庫站在 main 時也回 main ——
#      gitlink 若停在 dev 線的 commit，cx git sync 就會偵測到工作區與
#      gitlink 不一致，而那個不一致沒有任何人做錯事。
#
# **不推送、不打 tag。** 推送有自己的閘門（cx git push 的三道）；
# tag 牽涉版本號策略，而本專案沒有 —— 做一半的版本機制比沒有更糟。
_git_release() {
    local skip_scan=0
    while (( $# )); do
        case $1 in
            --skip-scan) skip_scan=1; shift ;;
            -h|--help)
                cx_dim "cx git release [--skip-scan]"
                cx_dim ""
                cx_dim "把 $(_git_dev_branch) 發布到 $(_git_main_branch)（三個 repo 一起），"
                cx_dim "並讓主庫的 gitlink 對齊子模組的 $(_git_main_branch)。"
                cx_dim "不推送、不打 tag。"
                return 0 ;;
            *) cx_die "$EX_USAGE" "release: 未知參數 $1（只接受 --skip-scan）" ;;
        esac
    done
    local main_br dev_br
    main_br=$(_git_main_branch); dev_br=$(_git_dev_branch)
    _git_require_repos || return $?
    _git_identity_ok   || return "$EX_PRECOND"

    # ── 前置：三個 repo 都要有兩條線，而且都乾淨 ──────────────────────
    local r slug
    while read -r r; do
        slug=$(_git_repo_slug "$r")
        git -C "$r" show-ref --verify --quiet "refs/heads/$main_br"             || cx_die "$EX_PRECOND" "$slug 沒有 $main_br 分支（先 cx git flow-init）"
        git -C "$r" show-ref --verify --quiet "refs/heads/$dev_br"             || cx_die "$EX_PRECOND" "$slug 沒有 $dev_br 分支（先 cx git flow-init）"
    done < <(_git_repos_order all)

    # 子模組要完全乾淨；主庫可以有髒的 gitlink（那正是這個動詞要記錄的東西），
    # 但除此之外必須乾淨 —— 理由與 _git_flow_finish 的前置檢查相同。
    local c
    for c in backend frontend; do
        [[ -z $(git -C "$CX_ROOT/$c" status --porcelain) ]]             || cx_die "$EX_PRECOND" "$c 有未提交變更 —— 先 cx git commit --repo $c"
    done
    [[ -z $(git -C "$CX_ROOT" status --porcelain -- . ':(exclude)backend' ':(exclude)frontend') ]]         || { cx_error "主庫有 gitlink 以外的未提交變更 —— 先處理掉再發布"
             git -C "$CX_ROOT" status --short -- . ':(exclude)backend' ':(exclude)frontend'                  | sed 's/^/      /' >&2
             return "$EX_PRECOND"; }

    # ── 有什麼要發布？沒有的話就不要建空的 merge commit ────────────────
    cx_step "$dev_br → $main_br 的差異"
    local total=0 n
    local -A ahead=()
    while read -r r; do
        slug=$(_git_repo_slug "$r")
        n=$(git -C "$r" rev-list --count "$main_br..$dev_br" 2>/dev/null || echo 0)
        ahead[$r]=$n; total=$((total + n))
        printf '  %-16s %s 個 commit\n' "$slug" "$n"
    done < <(_git_repos_order all)
    if (( total == 0 )); then
        cx_ok "$main_br 已經包含 $dev_br 的全部內容 —— 沒有要發布的東西"
        return 0
    fi

    # ── 祕密掃描先跑。三個 repo 都是 public，而 release 是「準備要推」的訊號 ──
    #
    # 這道**不是**最後防線 —— cx git push 自己也會掃，而 release 不推送。
    # 它存在的理由是「早點發現」：發現得越晚，要重寫的歷史越長。
    # --skip-scan 因此是可以接受的（比照 cx git commit），但它只該用在
    # 離線環境與測試 fixture 上 —— 推送那一道沒有對應的旗標。
    if (( skip_scan )); then
        cx_warn "已跳過祕密掃描（--skip-scan）—— cx git push 仍然會掃"
    else
        _git_scan_secrets || return $?
    fi

    cx_confirm --danger "把 $dev_br 發布到 $main_br" \
"三個 repo 各自 $main_br ← merge --no-ff $dev_br，然後主庫的 gitlink
改指到子模組 $main_br 的 tip。

  $(for r in "${!ahead[@]}"; do printf '%s：%s 個 commit\n  ' "$(_git_repo_slug "$r")" "${ahead[$r]}"; done)

**不會**推送，也**不會**打 tag。
推送請用 cx git push。

繼續嗎？" || return "$EX_ABORT"

    # ── 1. 主庫先站到 main（不帶 --recurse-submodules）────────────────
    cx_step "主庫切到 $main_br"
    local cur_super; cur_super=$(git -C "$CX_ROOT" branch --show-current 2>/dev/null || echo '')
    if [[ $cur_super != "$main_br" ]]; then
        cx_run git -C "$CX_ROOT" switch "$main_br"             || { cx_error "主庫切到 $main_br 失敗"; return "$EX_FAIL"; }
    fi

    # ── 2. 子模組各自合併 ─────────────────────────────────────────────
    for c in backend frontend; do
        local d="$CX_ROOT/$c"; slug=$(_git_repo_slug "$d")
        (( ${ahead[$d]:-0} )) || { cx_ok "$slug：$main_br 已是最新"; continue; }
        cx_step "$slug：$dev_br → $main_br"
        cx_run git -C "$d" switch "$main_br"             || { cx_error "$slug 切到 $main_br 失敗"; return "$EX_FAIL"; }
        cx_run git -C "$d" merge --no-ff -m "Release $dev_br into $main_br" "$dev_br"             || { cx_error "$slug 合併失敗 —— 解完衝突後自己 git commit，不要再跑一次 release"
                 return "$EX_FAIL"; }
        cx_ok "$slug：$main_br → $(git -C "$d" rev-parse --short HEAD)"
    done

    # ── 3. 主庫合併 ───────────────────────────────────────────────────
    if (( ${ahead[$CX_ROOT]:-0} )); then
        cx_step "主庫：$dev_br → $main_br"
        cx_run git -C "$CX_ROOT" merge --no-ff -m "Release $dev_br into $main_br" "$dev_br"             || { cx_error "主庫合併失敗 —— 解完衝突後自己 git commit，不要再跑一次 release"
                 return "$EX_FAIL"; }
    fi

    # ── 4. gitlink 改指到子模組 main 的 tip ───────────────────────────
    # 這一步不能省。--no-ff 讓子模組的 main 多一個 merge commit，
    # 所以 main tip ≠ dev tip，而步驟 3 帶過來的 gitlink 指的是後者。
    cx_step "主庫：gitlink 對齊 $main_br"
    local changed=0
    for c in backend frontend; do
        [[ -e $CX_ROOT/$c/.git ]] || continue
        local head; head=$(git -C "$CX_ROOT/$c" rev-parse HEAD)
        local idx;  idx=$(git -C "$CX_ROOT" ls-files --stage -- "$c" | awk '{print $2}')
        [[ $idx == "$head" ]] && { cx_ok "$c gitlink 已對齊 ${head:0:7}"; continue; }
        cx_run git -C "$CX_ROOT" add -- "$c" || return "$EX_FAIL"
        cx_ok "$c gitlink：${idx:0:7} → ${head:0:7}"
        changed=1
    done
    if (( changed )); then
        cx_run git -C "$CX_ROOT" commit -q -m "chore(release): gitlink 對齊 $main_br"             || { cx_error "主庫提交 gitlink 失敗"; return "$EX_FAIL"; }
    fi

    _git_assert_no_detached all || return "$EX_FAIL"
    cx_ok "已發布到 $main_br。推送： cx git push"
    cx_dim "  回到開發線： cx git branch switch $dev_br"
    cx_dim "  沒有打 tag —— 本專案沒有版本號策略（見 .cxroot 的分支模型註解）"
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
    local repo=${_GIT_BRANCH_REPO:-all}
    # 主庫沒有 feature/* —— 那是子模組的東西（見 _git_feature 的說明）。
    # 從 branch new 繞過去會建出一條沒有任何動詞認得的分支：
    # feature finish 只看子模組，於是它永遠合不回去，也不會有人發現。
    # hotfix/* 與 feature/* 一樣：finish 只看子模組，在主庫開等於永遠合不回去。
    if [[ ( $n == feature/* || $n == hotfix/* ) && ( $repo == all || $repo == main ) ]]; then
        cx_die "$EX_USAGE" "$(printf '%s\n' \
            "主庫不開 feature 分支（$n）" \
            "" \
            "  功能分支只開在子模組裡：" \
            "    cx git feature start ${n#feature/} --repo backend|frontend" \
            "" \
            "  主庫只有 $(_git_main_branch) 與 $(_git_dev_branch)，它的 $(_git_dev_branch)" \
            "  會在 feature finish 時自動跟上子模組的 gitlink。")"
    fi
    # 起點：--from > dev > 目前所在的 commit。
    # 原本是 `switch -c "$n"`（沒有起點），也就是「從你現在剛好在的地方開」——
    # gitflow 之下 feature 必須從 dev 開，而「現在剛好在哪」不是可重現的東西。
    #
    # ⚠ 這裡曾經只寫 `local base=${_GIT_BRANCH_FROM:-}` —— 也就是沒給 --from
    #   就退回裸的 switch -c，從 HEAD 開。而 usage 與 cx-reference 都寫著
    #   「預設從 dev 開」。文件與實作相反，正是本專案最常見的那類缺陷。
    #   2026-09-05 實測：main 比 dev 多一個 commit 時，branch new 開出來的
    #   分支指向 main 而不是 dev。
    #
    #   dev 不存在時（例如剛 cx init 出來的新專案）不能硬失敗 ——
    #   退回 HEAD 並明說，讓使用者知道起點是什麼。
    #   ⚠ 起點必須**逐個 repo** 解析，不能用主庫的答案代表三個 repo。
    #     2026-09-05 實測：主庫有 dev、兩個子模組只有 main（clone 之後的常態），
    #     用主庫的答案就會選中 dev，然後在子模組的存在性檢查死掉：
    #       ✘ pm-backend 沒有起點 dev
    #     於是 `cx git branch new` 與 `cx git feature start` 在預設情況下**完全不能用**。
    local explicit_base=${_GIT_BRANCH_FROM:-}
    local dev_branch; dev_branch=$(_git_dev_branch)

    local r slug dirty=0 fellback=()
    while read -r r; do
        slug=$(_git_repo_slug "$r")
        [[ -n $(git -C "$r" status --porcelain) ]] && { cx_warn "$slug 有未提交變更"; dirty=1; }
        git -C "$r" show-ref --verify --quiet "refs/heads/$n" \
            && cx_die "$EX_PRECOND" "$slug 已經有分支 $n"
        if [[ -n $explicit_base ]]; then
            # 明確指定的 --from 缺席就是硬錯誤 —— 使用者要的就是那個 ref
            git -C "$r" rev-parse --verify --quiet "$explicit_base^{commit}" >/dev/null \
                || cx_die "$EX_PRECOND" "$slug 沒有起點 $explicit_base"
        elif ! git -C "$r" show-ref --verify --quiet "refs/heads/$dev_branch"; then
            fellback+=("$slug")
        fi
    done < <(_git_repos_order "$repo")
    if (( ${#fellback[@]} )); then
        cx_warn "${fellback[*]} 沒有 $dev_branch 分支 —— 這幾個從各自目前的 HEAD 開"
        cx_dim "  要讓它們也走 gitflow： cx git branch new $dev_branch --from $(_git_main_branch)"
    fi
    (( dirty )) && { cx_confirm "有未提交變更" \
        "上列 repo 有未提交變更。\n\ngit 會把它們一起帶到新分支 $n。\n\n繼續嗎？" \
        || return "$EX_ABORT"; }

    cx_step "建立分支 $n"
    # 主庫先：submodule.recurse=true 會讓主庫的 switch 順便動子模組，
    # 所以子模組的 switch 必須排在後面才不會被覆蓋成 detached。
    local base
    while read -r r; do
        slug=$(_git_repo_slug "$r")
        # 每個 repo 各自決定起點：--from > 該 repo 的 dev > 該 repo 目前的 HEAD
        base=$explicit_base
        if [[ -z $base ]] \
           && git -C "$r" show-ref --verify --quiet "refs/heads/$dev_branch"; then
            base=$dev_branch
        fi
        if [[ -n $base ]]; then
            cx_run git -C "$r" switch -c "$n" "$base" \
                || { cx_error "$slug 建立分支失敗"; return "$EX_FAIL"; }
        else
            cx_run git -C "$r" switch -c "$n" \
                || { cx_error "$slug 建立分支失敗"; return "$EX_FAIL"; }
        fi
        cx_ok "$slug → $n${base:+（從 $base）}"
    done < <(_git_repos_super_first "$repo")
    _git_assert_no_detached "$repo" || return "$EX_FAIL"
    cx_info "已在 $n。提交請用： cx git commit"
}

_git_branch_switch() {
    local n=$1; _git_branch_check_name "$n"
    # --repo 原本被解析、驗證，然後**丟掉** —— 三個 repo 一律一起切。
    # 於是「只有子模組有這個分支」的情況（gitflow 之下的常態）根本切不動。
    local repo=${_GIT_BRANCH_REPO:-all}
    local r slug missing=()
    while read -r r; do
        slug=$(_git_repo_slug "$r")
        git -C "$r" show-ref --verify --quiet "refs/heads/$n" || missing+=("$slug")
    done < <(_git_repos_order "$repo")
    if (( ${#missing[@]} )); then
        cx_error "下列 repo 沒有分支 $n：${missing[*]}"
        cx_dim "  只切某一個： cx git branch switch $n --repo backend|frontend|main"
        cx_dim "  一起建立：   cx git branch new $n"
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
    done < <(_git_repos_order "$repo")
    while read -r r; do
        slug=$(_git_repo_slug "$r")
        if [[ $r == "$CX_ROOT" ]]; then
            # ⚠ 明確帶 --recurse-submodules，不要依賴環境。
            # git.sh 有五處註解寫著「本專案設了 submodule.recurse=true」，
            # 而實測 git config --show-origin --get-all submodule.recurse → rc=1
            #（全域與本地都沒有設）。整個排序的立論建立在一個不成立的前提上。
            # 帶了旗標之後行為才是確定的：實測它**只** detach gitlink 真的有變的
            # 那個子模組，另一個仍然留在自己的分支上。
            cx_run git -C "$r" switch --recurse-submodules "$n"
        else
            cx_run git -C "$r" switch "$n"
        fi
        cx_ok "$slug → $n"
    done < <(_git_repos_super_first "$repo")
    _git_assert_no_detached "$repo" || return "$EX_FAIL"
}

# 切換之後一定要驗：submodule.recurse 的副作用是靜默的，
# 只看 switch 的 exit code 看不出子模組被打成 detached。
# ⚠ 一定要吃過濾器。原本無條件走三個 repo，於是
#   cx git branch new x --repo main 會**先把分支建好**、然後回 EX_FAIL ——
#   因為兩個子模組本來就是 detached（那是它們被 gitlink 釘住的正常狀態）。
#   操作成功了卻回報失敗，是最難查的那一種。
_git_assert_no_detached() {         # _git_assert_no_detached [過濾器]
    local f=${1:-all} r slug bad=0
    while read -r r; do
        slug=$(_git_repo_slug "$r")
        if ! git -C "$r" symbolic-ref -q HEAD >/dev/null 2>&1; then
            cx_error "$slug 處於 detached HEAD"
            cx_dim "  修復： git -C $r switch <分支>   或   cx git sync"
            bad=1
        fi
    done < <(_git_repos_order "$f")
    (( bad == 0 ))
}

_git_branch_delete() {
    local n=$1; _git_branch_check_name "$n"
    [[ $n == master ]] && cx_die "$EX_USAGE" "拒絕刪除 $n"
    _git_is_protected_branch "$n" \
        && cx_die "$EX_USAGE" "拒絕刪除受保護的分支 $n（gitflow 的 $(_git_main_branch) / $(_git_dev_branch)）"
    # --repo 原本同樣被丟掉。feature 分支只存在於單一子模組，
    # 「三個 repo 都沒有分支 x」對它來說是常態而不是錯誤。
    local repo=${_GIT_BRANCH_REPO:-all}
    local r slug cur
    while read -r r; do
        slug=$(_git_repo_slug "$r")
        cur=$(git -C "$r" branch --show-current 2>/dev/null || echo '')
        [[ $cur == "$n" ]] && cx_die "$EX_PRECOND" "$slug 目前就在 $n 上，請先切走"
    done < <(_git_repos_order "$repo")

    # 先確認至少有一個 repo 真的有這個分支，否則不該拿確認閘門去煩人
    local found=0 have=()
    while read -r r; do
        if git -C "$r" show-ref --verify --quiet "refs/heads/$n"; then
            found=1; have+=("$(_git_repo_slug "$r")")
        fi
    done < <(_git_repos_order "$repo")
    (( found )) || cx_die "$EX_PRECOND" "$repo 範圍內沒有任何 repo 有分支 $n"

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
    done < <(_git_repos_order "$repo")
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
# 指定現成的 remote（不經過 gh）。
#
# 與 remote-init 分開而不是加旗標：那一支的職責是「建立 repo」，這一支是
# 「指到已經存在的 repo」。混在一起的話，`--url` 到底要不要建 repo 會變成
# 一個需要讀原始碼才知道的問題。
#
# ⚠ guard.sh 的推送白名單是從 .cxroot 的 CX_GH_ORG/CX_REPO_* 推導的。
#   指到白名單以外的位址時，cx git push 會擋 —— 這裡先講清楚，
#   不要等到推的時候才發現。
_git_remote_set() {
    local main_url=${1:-} be_url=${2:-} fe_url=${3:-}
    [[ -n $main_url ]] || cx_die "$EX_USAGE" \
        "用法：cx git remote-set <主庫URL> [backend URL] [frontend URL]
  只給主庫 URL 時，backend/frontend 會用同一個目錄推導：
    https://host/org/proj.git → https://host/org/proj-backend.git / -frontend.git"
    # 由主庫 URL 推導另外兩個
    if [[ -z $be_url || -z $fe_url ]]; then
        local base=${main_url%.git}
        be_url=${be_url:-"${base%/*}/$CX_REPO_BACKEND.git"}
        fe_url=${fe_url:-"${base%/*}/$CX_REPO_FRONTEND.git"}
    fi
    cx_step "設定 remote"
    local r slug url
    while read -r r; do
        slug=$(_git_repo_slug "$r")
        case $slug in
            "$CX_REPO_BACKEND")  url=$be_url ;;
            "$CX_REPO_FRONTEND") url=$fe_url ;;
            *)                   url=$main_url ;;
        esac
        [[ -d $r/.git || -f $r/.git ]] || { cx_warn "$slug 還不是 git repo，略過"; continue; }
        if git -C "$r" remote get-url origin >/dev/null 2>&1; then
            cx_run git -C "$r" remote set-url origin "$url" || return "$EX_FAIL"
        else
            cx_run git -C "$r" remote add origin "$url" || return "$EX_FAIL"
        fi
        # 與 remote-init 同一個坑：submodule add 建的 origin 沒有 fetch refspec，
        # 少了它 push -u 建不出 refs/remotes/origin/*，status 看不到 ahead/behind。
        if [[ -z $(git -C "$r" config --get remote.origin.fetch || true) ]]; then
            cx_run git -C "$r" config --add remote.origin.fetch \
                '+refs/heads/*:refs/remotes/origin/*'
        fi
        cx_ok "$slug → $url"
    done < <(_git_repos_order all)

    if ! printf '%s' "$main_url" | grep -qE "$(cx_guard_allow_re 2>/dev/null || echo 'github\.com')"; then
        cx_warn "這個位址不在推送白名單內 —— cx git push 會擋下"
        cx_dim "  白名單由 .cxroot 的 CX_GH_ORG / CX_REPO_* 推導（見 bin/lib/guard.sh）"
        cx_dim "  要推到這裡：改 .cxroot 的 CX_GH_ORG，或用原生 git push"
    fi
}

_git_remote_init() {
    cx_have gh || cx_die "$EX_PRECOND" "找不到 gh CLI"
    gh auth status >/dev/null 2>&1 || cx_die "$EX_PRECOND" "gh 未登入（gh auth login）"

    # ⚠ 這個動詞會在**真的 GitHub 上**建立三個 public repo，而且原本一道確認都沒有。
    # 建錯了刪不掉：gh 的 token 通常沒有 delete_repo，得自己去網頁刪三次。
    # 對外可見的動作要先問 —— 這是本專案對 cx git push 的既有標準，這裡缺了。
    local _who _r _slug
    _who=$(gh api user --jq .login 2>/dev/null || echo '<未知>')
    local _list=''
    while read -r _r; do
        _slug=$(_git_repo_slug "$_r")
        if gh repo view "$CX_GH_ORG/$_slug" >/dev/null 2>&1; then
            _list+="  $CX_GH_ORG/$_slug（已存在，只會設定 origin）
"
        else
            _list+="  $CX_GH_ORG/$_slug   ← 新建，PUBLIC
"
        fi
    done < <(_git_repos_order)
    cx_confirm --danger "在 GitHub 建立遠端（PUBLIC）" \
"以 $_who 的身分，在組織 $CX_GH_ORG 底下處理這三個 repo：

$_list
新建的一律是 **public**。建錯的話 cx 刪不掉它們 ——
gh 的 token 多半沒有 delete_repo 權限，要自己上網頁刪。

專案身分來自 .cxroot（CX_GH_ORG / CX_REPO_*）。名字不對就先跑 cx rename。" \
        || { cx_warn "已取消"; return "$EX_ABORT"; }

    cx_step "建立 GitHub 遠端（組織：$CX_GH_ORG）"
    local r slug url
    while read -r r; do
        slug=$(_git_repo_slug "$r")
        url="https://github.com/$CX_GH_ORG/$slug.git"

        if gh repo view "$CX_GH_ORG/$slug" >/dev/null 2>&1; then
            cx_warn "$CX_GH_ORG/$slug 已存在，略過建立"
        else
            # 專案名一律從 .cxroot 推導 —— 這段字串會被寫進**真的 GitHub repo**
            # 的描述欄，寫死「pm」的話，任何從這個範本開出來的新專案都會頂著
            # 上一個專案的名字，而且要到 repo 建好之後才看得出來。
            local desc proj
            proj=$(cx_project)
            case $slug in
                "$CX_REPO_BACKEND")  desc="$proj 後端 — PHP 8.5 + Laravel 13 + Filament v5" ;;
                "$CX_REPO_FRONTEND") desc="$proj 前端 — Vue 3 + Nuxt 4" ;;
                *)                   desc="$proj — 統籌大庫（Docker / Ansible / cx）" ;;
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
            tracked=$(_git_sub_target_branch "$(basename "$r")")
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
