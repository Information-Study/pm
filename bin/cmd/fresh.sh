#!/usr/bin/env bash
# cx fresh — 清理與重建。
#
# 強制順序（不可調換）：
#   preflight → backup → verify → [確認閘門] → migrate → delete → rebuild → git-init
#   驗證排在確認之前，這樣壞掉的封存會在樹還完整時就中止。
#   在確認閘門通過之前，不刪除任何東西。

# ── 保留：不動 ────────────────────────────────────────────────
#
# ⚠ docker-compose.yml 與 .dockerignore 在 2026-09-05 之前是列在 FRESH_MIGRATE
#   裡的，而 _fresh_delete 會把 FRESH_DELETE **加上** FRESH_MIGRATE 一起刪掉。
#   當時的註解寫「Phase 2 會重寫根目錄那兩份」—— 那句話在遷移進行中是對的，
#   遷移完成之後就過期了：**根目錄的 docker-compose.yml 現在就是 Phase 2 的那一份**。
#   後果是 cx fresh 跑完之後 docker/legacy/ 有一份 .orig 副本，而根目錄什麼都沒有，
#   於是每一個 compose 動詞都死在「缺少 base compose」——
#   一個「重建成可以直接跑的新專案」的動詞，交出來的樹是不能跑的。
#   2026-09-05 實測確認（cx fresh --phase delete 之後 cx dev config → EX_PRECOND）。
FRESH_PRESERVE=(
    bin cx .cxroot templates docs claude.md
    .vscode reports ansible .env .env.example .gitignore
    docker sonar-project.properties .semgrepignore
    docker-compose.yml .dockerignore
)
# ── 遷移：搬到 docker/ 之後才刪除原處（使用者要求保留 docker 自定義設定）──
#
# 只剩下真正屬於**舊版面**的那兩個目錄。它們在現在的樹上早就不存在了
# （遷移在 Phase 2 就做完），保留這一段是為了讓還停在舊版面的 checkout
# 也能一次升上來 —— 不存在時整段是 no-op。
FRESH_MIGRATE=( php nuxt )
# ── carryover 要疊回去的「應用層」目錄 ────────────────────────
# 一行一個，不用空白分隔的字串 —— 後者只能靠字詞分割展開，目錄名含空白就裂開。
# 骨架檔（config/、bootstrap/、package.json、nuxt.config）刻意**不在**這裡：
# 框架升級真正會變的就是那些，而反過來做需要一份「這一版新增了哪些骨架檔」
# 的清單，那份清單不存在。
_fresh_keep_dirs() {                # _fresh_keep_dirs <backend|frontend>
    case $1 in
        backend)  printf '%s\n' app database/migrations database/seeders \
                      database/factories routes resources tests ;;
        frontend) printf '%s\n' app components pages layouts composables \
                      stores assets public server middleware plugins ;;
    esac
}

# ── 刪除：確認後移除 ──────────────────────────────────────────
FRESH_DELETE=( .git .gitmodules backend frontend init.sh refresh.sh README.md )

# ── git-only：只抹 git 紀錄，程式碼原封不動 ──────────────────────────────
#
# 使用者要的「crash」有兩種語意，而它們的差別很大：
#   * 完整重建（fresh 的 scaffold / carryover）—— 連前後端一起重生成骨架
#   * 只抹 git —— 「這份程式碼要變成一個新專案的起點，但我不要它的歷史」
#
# 後者刻意**不新增動詞**。init.sh:4-12 記過這個教訓：再寫一份「其實差不多」
# 的流程，等於讓封存、驗證封存、確認閘門、rollback 那四道保護各自演化然後分岔。
# 所以它是 fresh 的一個 mode，走同一條 phase machine，只是 delete 那一格
# 換一份清單、並跳過 migrate / rebuild / verify 三格。
FRESH_DELETE_GIT_ONLY=( .git .gitmodules )

# ── 本機暫存：分類為「已知」，但**不屬於範本** ────────────────────
#
# .gitignore 已經忽略 /.cx-*.sh|py|txt，所以它們不會進版控。但 cx fresh 是
# 檔案系統層的操作，看不到 .gitignore —— PF-07 把未分類的頂層項目歸為
# 「保留不動」，於是 14 個開發過程的驗證腳本會原封不動出現在新專案裡，
# 而開新專案的人完全不知道那是什麼。
#
# 這裡只做**分類**，不刪任何東西（紅線 2：刪除要有互動確認，而 preflight
# 是唯讀階段）。作用是讓 PF-07 不再把它們列為「未分類」，並讓確認閘門
# 明確告訴操作者這些檔案不會被帶進新專案。
FRESH_LOCAL_GLOBS=( '.cx-*.sh' '.cx-*.py' '.cx-*.txt' )
# 開發工具自己的目錄。跟這個專案是什麼無關，所以不該被複製進新專案。
FRESH_LOCAL_ITEMS=( .claude )

# 這個頂層項目是不是本機的東西（不屬於範本內容）？
_fresh_is_local_scratch() {         # _fresh_is_local_scratch <basename>
    local b=$1 g
    for g in "${FRESH_LOCAL_ITEMS[@]}"; do [[ $b == "$g" ]] && return 0; done
    for g in "${FRESH_LOCAL_GLOBS[@]}"; do
        # shellcheck disable=SC2053  # 右邊要當 glob 用，不能加引號
        [[ $b == $g ]] && return 0
    done
    return 1
}

_fresh_usage() {
    cat >&2 <<'TXT'
用法：cx fresh [--phase <名稱>] [--resume-from <名稱>] [--mode <模式>] [--rollback] [--from <目錄>]

  --phase <名稱>        跑到這一步為止（天花板，預設 all）
          preflight backup migrate delete rebuild verify git-init
          preflight 完全不動任何東西，只做前置檢查
          delete    做到刪除為止，不重建

  --resume-from <名稱>  從這一步開始（地板）。只接受 rebuild|verify|git-init
          重建失敗之後接續用，不必重跑破壞性流程。
          需要知道用哪一份封存：給 --from <目錄>，或讓 .cx/fresh.state 還在

  --mode  backup-only | git-only | carryover | scaffold    （預設 carryover）
          backup-only  只封存，不刪也不建
          git-only     只抹掉 git 紀錄（.git / .gitmodules / 子模組的 .git）
                       並重新初始化三個 repo。**程式碼原封不動**，不重建骨架
          scaffold     全新骨架（Nuxt 4 + Laravel 13 + Filament v5 + Larastan）
          carryover    全新骨架，再把你自己的程式碼從封存疊回去
                       （骨架檔用新版的 —— 那正是重建的目的）

  --rollback [--from <archive-dir>]             從封存還原
          省略 --from 就用 <封存根>/LATEST。還原前會先驗證封存，
          被覆蓋的內容先移到 .cx-restore-backup/ 而不是直接刪。
          資料庫不在還原範圍 —— 用 cx db restore。

流程（順序不可調換）：
  preflight → 備份 → 驗證封存 → 確認閘門 → 遷移 → 刪除 → 重建 → **驗證重建** → 三 Git 初始化
  確認閘門之前不刪除任何東西；驗證排在確認之前，壞掉的封存會在樹還完整時中止。
  重建之後的驗證失敗就不會進 git-init —— 把半套骨架 commit 進去會讓還原更難。

中斷之後：
  過了刪除那一步才中斷的話，.cx/fresh.state 會擋住「重跑整個流程」——
  否則第二次執行會把已經被刪掉的狀態重新封存一次並覆寫 LATEST，
  原本救得回來的那份封存就找不到了。畫面會告訴你接續或還原的指令。
TXT
}

# ---------------------------------------------------------------------------
# 安全刪除：多重護欄
# ---------------------------------------------------------------------------
_fresh_nuke() {
    local t=$1 real
    [[ -e $t || -L $t ]] || return 0
    # 拒絕 symlink（避免被指到樹外）—— 而且要**中止整個刪除**，不是略過後繼續。
    # 原本是 warn + return 0：於是 $CX_ROOT/.git 若是 symlink，它被跳過，
    # 迴圈照樣把 backend/ frontend/ README.md .gitmodules 全部刪掉，
    # 最後才由下面的斷言 cx_die —— 而 cx_die 會 exit，
    # _fresh_recovery_note 與 _fresh_state_write 都來不及寫。
    # 樹被毀了一半，麵包屑卻停在 migrate。
    [[ -L $t ]] && { cx_error "$t 是 symlink —— 拒絕刪除，且中止整個刪除階段"
                     cx_dim "  symlink 可能指到樹外。請先自己確認它指向哪裡再處理。"
                     return 1; }
    real=$(cd "$(dirname "$t")" && pwd -P)/$(basename "$t")
    # 必須嚴格位於 CX_ROOT 之下
    case $real in
        "$CX_ROOT"/*) : ;;
        *) cx_die "$EX_PRECOND" "拒絕刪除 CX_ROOT 之外的路徑：$real" ;;
    esac
    [[ $real == "$CX_ROOT" ]] && cx_die "$EX_PRECOND" "拒絕刪除 CX_ROOT 本身"
    [[ $real == "$HOME" ]] && cx_die "$EX_PRECOND" "拒絕刪除 HOME"
    [[ $real == / ]] && cx_die "$EX_PRECOND" "拒絕刪除 /"
    cx_run rm -rf -- "$real"
    cx_ok "已刪除 $(basename "$real")"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
_fresh_preflight() {
    cx_step "Preflight"
    local fail=0

    [[ $(id -u) -ne 0 ]] || { cx_error "PF-01 不可以 root 執行"; fail=1; }
    cx_ok "PF-01 非 root（$(id -un)）"

    [[ -f $CX_ROOT/.cxroot ]] || { cx_error "PF-02 找不到 .cxroot"; fail=1; }
    cx_ok "PF-02 CX_ROOT=$CX_ROOT"

    # PF-10 這棵樹必須是一般的 clone，不能是 git worktree。
    # worktree 的 .git 是指標檔，真正的物件庫在 CX_ROOT 之外 —— 封存抓不到、
    # 刪除刪不掉、rollback 還原不了，而整條流程會「成功」。
    # archive.sh 也有一道同樣的防線，但那時封存目錄已經建出來了；
    # 這裡擋掉才符合「preflight 完全不動任何東西」。
    if [[ -f $CX_ROOT/.git ]]; then
        cx_error "PF-10 這是 git worktree（.git 是檔案）—— cx fresh 不支援"
        cx_dim "  真正的物件庫：$(git -C "$CX_ROOT" rev-parse --absolute-git-dir 2>/dev/null || echo '<未知>')"
        cx_dim "  請在主 checkout 上執行： git worktree list"
        fail=1
    elif [[ -d $CX_ROOT/.git ]]; then
        cx_ok "PF-10 一般 clone（.git 是目錄）"
    else
        cx_warn "PF-10 沒有 .git —— 只有在已經 fresh 過的樹上才正常"
    fi

    if cx_docker_ok; then
        cx_ok "PF-03 Docker daemon 可用（$(docker version --format '{{.Server.Version}}')）"
    else
        cx_warn "PF-03 Docker daemon 不可用 —— 無法備份資料庫，也無法重建前後端"
        _FRESH_NO_DOCKER=1
    fi

    # 未提交變更
    local c n
    for c in . backend frontend; do
        [[ -d $CX_ROOT/$c ]] || continue
        cx_is_repo_root "$CX_ROOT/$c" || continue
        n=$(git -C "$CX_ROOT/$c" status --porcelain | grep -vc '^?? claude.md$' || true)
        if (( n > 0 )); then
            cx_warn "PF-04 $c 有 $n 項未提交變更（會一併封存）"
            git -C "$CX_ROOT/$c" status --short | sed 's/^/      /' >&2
        else
            cx_ok "PF-04 $c 無未提交變更"
        fi
    done

    # 未推送 commit
    for c in backend frontend; do
        [[ -d $CX_ROOT/$c ]] || continue
        cx_is_repo_root "$CX_ROOT/$c" || continue
        if git -C "$CX_ROOT/$c" branch -r --contains HEAD >/dev/null 2>&1 \
           && [[ -n $(git -C "$CX_ROOT/$c" branch -r --contains HEAD 2>/dev/null) ]]; then
            cx_ok "PF-05 $c 的 HEAD 已存在於遠端"
        else
            cx_warn "PF-05 $c 的 HEAD 不在任何遠端分支上 —— 只靠本地封存"
        fi
    done

    # 封存空間：需要 3 倍
    #
    # arc 用 --probe 取得（preflight 不該建目錄），所以它可能還不存在 ——
    # df 對不存在的路徑會失敗，往上找到第一個存在的祖先再問。
    local arc need avail probe
    arc=$(cx_archive_root --probe)
    probe=$arc
    while [[ -n $probe && ! -e $probe && $probe != / ]]; do probe=$(dirname "$probe"); done
    need=$(du -sk --exclude=node_modules --exclude=vendor "$CX_ROOT" 2>/dev/null | cut -f1)
    avail=$(df -Pk "$probe" 2>/dev/null | tail -1 | awk '{print $4}')
    # du / df 失敗時兩個變數會是空字串，而 bash 算術把空字串當 0 ——
    # `(( 0 > 0 ))` 為假，於是會印出「空間不足」這個指向完全錯誤的訊息。
    if [[ -z $need || -z $avail ]]; then
        cx_warn "PF-06 無法量測空間（du 或 df 失敗，探測路徑：$probe）—— 跳過這項檢查"
    elif (( avail > need * 3 )); then
        cx_ok "PF-06 空間充足（需 $((need/1024))MB × 3，可用 $((avail/1024/1024))GB）"
    else
        cx_error "PF-06 空間不足（需 $((need/1024))MB × 3，可用 $((avail/1024))MB）"; fail=1
    fi

    # PF-08 git identity —— 沒有它，_fresh_git_init 會在樹**已經重建完之後**
    # 才死在 "Please tell me who you are"，而那時已經過了不可逆點。
    if git -C "$CX_ROOT" config user.email >/dev/null 2>&1 \
       && git -C "$CX_ROOT" config user.name >/dev/null 2>&1; then
        cx_ok "PF-08 git identity（$(git -C "$CX_ROOT" config user.name)）"
    else
        cx_error "PF-08 git 沒有設定 user.name / user.email —— 重建階段的 commit 會失敗"
        cx_dim "  git config --global user.name  \"你的名字\""
        cx_dim "  git config --global user.email \"you@example.com\""
        fail=1
    fi

    # PF-09 git 版本。archive.sh 用 rev-parse --absolute-git-dir（≥2.13），
    # _fresh_git_init 用 init -b main（≥2.28）。MANIFEST 有記版本但沒人斷言。
    local gv
    gv=$(git --version 2>/dev/null | awk '{print $3}')
    if [[ -n $gv ]] && printf '%s\n2.28.0\n' "$gv" | sort -V -C; then
        cx_error "PF-09 git $gv 太舊 —— 重建需要 git ≥ 2.28（init -b main）"
        fail=1
    else
        cx_ok "PF-09 git $gv"
    fi

    # 頂層項目分類
    local -a known=("${FRESH_PRESERVE[@]}" "${FRESH_MIGRATE[@]}" "${FRESH_DELETE[@]}" .cx .cx.lock)
    local -a unknown=()
    local e b
    while IFS= read -r -d '' e; do
        b=${e##*/}
        local hit=0 k
        for k in "${known[@]}"; do [[ $b == "$k" ]] && { hit=1; break; }; done
        (( hit )) || _fresh_is_local_scratch "$b" && hit=1
        (( hit )) || unknown+=("$b")
    done < <(find "$CX_ROOT" -mindepth 1 -maxdepth 1 -print0)
    local -a scratch=()
    while IFS= read -r -d '' e; do
        b=${e##*/}; _fresh_is_local_scratch "$b" && scratch+=("$b")
    done < <(find "$CX_ROOT" -mindepth 1 -maxdepth 1 -print0)
    if (( ${#scratch[@]} )); then
        cx_warn "PF-07 本機暫存腳本 ${#scratch[@]} 個（不屬於範本，不會被帶進新專案）：${scratch[*]}"
        cx_dim "  要留著就自己搬到專案外；cx fresh 不會刪它們，只是不當成範本內容。"
    fi
    if (( ${#unknown[@]} )); then
        cx_warn "PF-07 未分類的頂層項目（將被保留不動）：${unknown[*]}"
    else
        cx_ok "PF-07 所有頂層項目皆已分類"
    fi

    (( fail == 0 )) || cx_die "$EX_PRECOND" "Preflight 未通過"
    cx_ok "Preflight 全數通過"
}

# ---------------------------------------------------------------------------
# 遷移 docker 自定義設定：php/ nuxt/ → docker/
# 使用者明確要求「必須完整保留 docker 相關自定義 image、config 設定與檔案」
# ---------------------------------------------------------------------------
# 每一個會改變狀態的步驟都要經過這裡。
#
# 為什麼需要它：dispatcher 的 `"$fn" "$@" || _rc=$?`（cx:196）會讓**整個呼叫樹**
# 的 errexit 失效 —— 這是 archive.sh:56-69 量測記錄過的 bash 行為，包 subshell
# 或重新 set -e 都救不回來。於是這個檔案裡每一個指令都必須自己檢查回傳值。
#
# 而「靠紀律記得檢查」是行不通的：_fresh_migrate 原本 5 個 cp、1 個 mkdir
# 全部沒檢查，最後一行是 cx_ok，所以那個函式**永遠不可能回傳非零** ——
# cmd_fresh_main 那句寫得很慎重的
#     _fresh_migrate || cx_die "遷移失敗 —— 已中止，未刪除任何東西"
# 是死碼。註解描述的保護從來沒有存在過。
#
# 把「執行 + 檢查 + 回報」綁成一個動作，忘記檢查就變成不可能。
_fresh_step() {                     # _fresh_step <說明> -- <指令...>
    local label=$1; shift
    [[ ${1:-} == -- ]] && shift
    local rc=0
    cx_run "$@" || rc=$?
    if (( rc )); then
        cx_error "$label（exit $rc）"
        return "$rc"
    fi
    cx_ok "$label"
}

_fresh_migrate() {
    cx_step "遷移 Docker 自定義設定到 docker/"
    _fresh_step "建立 docker/{php,nuxt,legacy}" -- \
        mkdir -p "$CX_ROOT/docker/php" "$CX_ROOT/docker/nuxt" "$CX_ROOT/docker/legacy" || return $?

    local f d
    for d in php nuxt; do
        [[ -d $CX_ROOT/$d ]] || continue
        for f in "$CX_ROOT/$d"/*; do
            [[ -e $f ]] || continue
            _fresh_step "$d/$(basename "$f") → docker/$d/" -- \
                cp -a "$f" "$CX_ROOT/docker/$d/$(basename "$f")" || return $?
        done
    done

    # 這裡曾經把 docker-compose.yml 與 .dockerignore 複製到 docker/legacy/ ——
    # 那是為了在「刪掉原處」之前留一份參考。現在那兩個檔改成保留（見
    # FRESH_PRESERVE 的說明），所以複製一份 .orig 只會讓人以為根目錄那份會被換掉。

    # 舊腳本也留一份，方便對照
    for f in init.sh refresh.sh README.md; do
        [[ -f $CX_ROOT/$f ]] || continue
        _fresh_step "$f → docker/legacy/" -- \
            cp -a "$CX_ROOT/$f" "$CX_ROOT/docker/legacy/$f.orig" || return $?
    done

    cx_ok "遷移完成 —— 所有自定義設定都有副本在 docker/ 底下"
}

# ---------------------------------------------------------------------------
# 確認閘門
# ---------------------------------------------------------------------------
# ⚠ 閘門必須知道 mode。
#
#   scaffold 與 carryover 的差別是**你自己寫的程式碼會不會回來**，
#   而那是這兩個模式之間唯一真正重要的差異。原本的閘門完全沒提到模式 ——
#   於是 `cx fresh --mode scaffold` 會用一段跟 carryover 一模一樣的文字，
#   問你要不要刪掉 backend/ 與 frontend/，然後**不告訴你它不會疊回來**。
#
#   claude.md 早就寫著 scaffold「需額外輸入 NO CARRYOVER」，但那個閘門
#   從來沒有存在過（2026-09-05 稽核發現）。與其把文件改成符合現況，
#   不如把現況改成符合文件 —— 因為文件描述的才是對的行為。
_fresh_gate() {
    local A=$1 mode=${2:-carryover}
    local body msg_db

    msg_db=$(sed -n 's/^db_dump=//p' "$A/MANIFEST.txt" | head -1)
    case $msg_db in
        '<docker-unavailable>') msg_db='⚠ 未備份（Docker daemon 不可用）' ;;
        '<no-container>')       msg_db='⚠ 未備份（mysql 容器未執行）' ;;
        '<failed>')             msg_db='⚠ 備份失敗' ;;
        '')                     msg_db='⚠ 無記錄' ;;
        *)                      msg_db="✔ $msg_db" ;;
    esac

    # git-only 刪的東西與其他模式完全不同，所以閘門文字也必須完全不同。
    # ⚠ 這不是「順便講清楚」——「閘門說謊比動到檔案更糟」是本檔既有的原則
    #   （見 _fresh_gate 排在 _fresh_migrate 之前的理由）。一份說「即將刪除
    #   backend/ 與 frontend/」的確認畫面，配上一個其實不會刪它們的操作，
    #   會讓下一次真的要刪的時候沒有人相信那份清單。
    if [[ $mode == git-only ]]; then
        body=$(cat <<TXT
即將永久刪除下列項目：

  .git/            主庫 git 歷史（$(sed -n 's/^main_commits=//p' "$A/MANIFEST.txt" | head -1) commits）
  .gitmodules      子模組設定
  backend/.git     子模組指標檔（$(sed -n 's/^backend_commits=//p' "$A/MANIFEST.txt" | head -1) commits 的歷史隨主庫 .git/modules/ 一起消失）
  frontend/.git    子模組指標檔（$(sed -n 's/^frontend_commits=//p' "$A/MANIFEST.txt" | head -1) commits）

**你的程式碼原封不動。** backend/ 與 frontend/ 底下的程式碼完全不會被碰，
也不會重建骨架 —— 這個模式只做「抹掉歷史，重新開始記錄」。

會被**重新產生**的（那是 git 初始化的一部分，不是重建）：
  .gitmodules              submodule add 產生
  backend/.gitignore       從 templates/gitignore/ 複製
  frontend/.gitignore      （兩個子模組都是 PUBLIC repo，忽略規則不能少）

資料庫備份狀態：$msg_db

封存位置（在專案外，刪除不會波及）：
  $A

之後會重新 git init 三個 repo，並建立 $(_git_main_branch 2>/dev/null || echo main) 與 $(_git_dev_branch 2>/dev/null || echo dev) 兩條線。
遠端**不會**自動建立 —— 要的話跑 cx git remote-init 或 cx git remote-set。

此操作不可逆（歷史撤不回來，但程式碼還在）。確定要繼續嗎？
TXT
)
        cx_confirm --danger "cx fresh --mode git-only — 抹除 git 紀錄" "$body"             || { cx_error "使用者取消，未變更任何檔案"; return 1; }
        cx_ask_typed "最終確認"             "請輸入下列字串以確認抹除 git 紀錄：\n\n    DESTROY $(cx_project)\n"             "DESTROY $(cx_project)" || { cx_error "確認失敗，未變更任何檔案"; return 1; }
        return 0
    fi

    body=$(cat <<TXT
即將永久刪除下列項目：

  .git/            主庫 git 歷史（$(sed -n 's/^main_commits=//p' "$A/MANIFEST.txt" | head -1) commits）
  .gitmodules      子模組設定
  backend/         Laravel 專案（$(sed -n 's/^backend_commits=//p' "$A/MANIFEST.txt" | head -1) commits）
  frontend/        Nuxt 專案（$(sed -n 's/^frontend_commits=//p' "$A/MANIFEST.txt" | head -1) commits）
  php/  nuxt/      舊 Docker 設定目錄（已複製到 docker/）
  init.sh  refresh.sh  README.md

資料庫備份狀態：$msg_db

封存位置（在專案外，刪除不會波及）：
  $A

保留不動：bin/ cx .cxroot templates/ docs/ claude.md docker/ .vscode/
          docker-compose.yml .dockerignore ansible/ .env

重建模式：$mode
$( [[ $mode == scaffold ]] \
     && printf '%s' "  ⚠ scaffold —— 只產生全新骨架。你自己寫的程式碼（app/ routes/
     tests/ pages/ components/ …）**不會**被疊回去，只會留在上面那份封存裡。" \
     || printf '%s' "  carryover —— 產生全新骨架之後，會把 app/ routes/ tests/ 等
     從封存疊回去。" )

此操作不可逆。確定要繼續嗎？
TXT
)
    cx_confirm --danger "cx fresh — 刪除確認" "$body" || { cx_error "使用者取消，未變更任何檔案"; return 1; }
    cx_ask_typed "最終確認" \
        "請輸入下列字串以確認刪除：\n\n    DESTROY $(cx_project)\n" \
        "DESTROY $(cx_project)" || { cx_error "確認失敗，未變更任何檔案"; return 1; }
    # scaffold 是唯一會**默默丟掉使用者程式碼**的模式，所以多要一個 token。
    if [[ $mode == scaffold ]]; then
        cx_ask_typed "scaffold 確認" \
            "scaffold 不會把你的程式碼疊回去。\n\n請輸入：\n\n    NO CARRYOVER\n" \
            "NO CARRYOVER" || { cx_error "確認失敗，未變更任何檔案"; return 1; }
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 刪除
# ---------------------------------------------------------------------------
_fresh_delete() {                   # _fresh_delete [模式]
    local mode=${1:-carryover}
    cx_step "刪除"
    local t
    if [[ $mode == git-only ]]; then
        for t in "${FRESH_DELETE_GIT_ONLY[@]}"; do
            _fresh_nuke "$CX_ROOT/$t" || return 1
        done
        # 子模組的真實物件庫在 .git/modules/ 底下，隨主庫的 .git 一起消失。
        # 但 backend/.git 與 frontend/.git 是**指標檔**，指向剛被刪掉的地方 ——
        # 留著的話 git submodule add 會說 "already exists in the index"
        # 或直接把一個壞掉的指標加進新的 repo。
        local c
        for c in backend frontend; do
            [[ -e $CX_ROOT/$c/.git ]] && { _fresh_nuke "$CX_ROOT/$c/.git" || return 1; }
        done
        if (( CX_DRY_RUN )); then
            cx_dim "  [dry-run] 略過刪除後的斷言（實際上什麼都沒刪）"
        else
            [[ ! -e $CX_ROOT/.gitmodules ]] || { cx_error ".gitmodules 仍存在"; return 1; }
            [[ ! -e $CX_ROOT/.git ]]        || { cx_error ".git 仍存在"; return 1; }
            [[ ! -e $CX_ROOT/backend/.git ]]  || { cx_error "backend/.git 仍存在"; return 1; }
            [[ ! -e $CX_ROOT/frontend/.git ]] || { cx_error "frontend/.git 仍存在"; return 1; }
        fi
        cx_ok "斷言通過：三個 .git 與 .gitmodules 皆已移除（程式碼原封不動）"
        return 0
    fi
    for t in "${FRESH_DELETE[@]}" "${FRESH_MIGRATE[@]}"; do
        # docker-compose.yml 與 .dockerignore 已複製到 docker/legacy/，原處刪除
        _fresh_nuke "$CX_ROOT/$t" || return 1
    done

    # 斷言：.gitmodules 與 .git 必須真的消失，否則後續 git init 會出問題。
    #
    # ⚠ dry-run 之下要跳過。刪除走 cx_run（dry-run 不執行），而這些斷言原本是
    #   無條件的 —— 於是 `cx --dry-run fresh --phase delete` 會死在
    #   「.gitmodules 仍存在」。最需要 dry-run 的動詞，dry-run 是壞的。
    if (( CX_DRY_RUN )); then
        cx_dim "  [dry-run] 略過刪除後的斷言（實際上什麼都沒刪）"
    else
    # ⚠ 這裡一律 return，不可以 cx_die。cx_die 會 exit 整個行程，
    #   於是 cmd_fresh_main 的 _fresh_recovery_note 與 _fresh_state_write
    #   都不會執行 —— 樹已經被動過，卻沒有留下任何救援線索。
    #   閘門**之後**的失敗一律交還控制權，這是本檔的通則。
    [[ ! -e $CX_ROOT/.gitmodules ]] || { cx_error ".gitmodules 仍存在"; return 1; }
    [[ ! -e $CX_ROOT/.git ]]        || { cx_error ".git 仍存在"; return 1; }
    [[ ! -e $CX_ROOT/backend ]]     || { cx_error "backend/ 仍存在"; return 1; }
    [[ ! -e $CX_ROOT/frontend ]]    || { cx_error "frontend/ 仍存在"; return 1; }
    fi
    cx_ok "斷言通過：.git / .gitmodules / backend / frontend 皆已移除"

    # 重建空目錄，且必須由「當前使用者」建立。
    # 否則 Docker 之後會以 root:root 0755 自動建立 bind mount 來源，
    # 容器內 uid 1000 寫不進去，非 root 的操作者也刪不掉。
    cx_run mkdir -p "$CX_ROOT/backend" "$CX_ROOT/frontend"
    [[ -O $CX_ROOT/backend && -O $CX_ROOT/frontend ]] \
        || { cx_error "backend/ frontend/ 擁有者不是目前使用者"; return 1; }
    cx_ok "已建立空的 backend/ frontend/（擁有者 $(id -un)）"
}

# ---------------------------------------------------------------------------
# 重建
# ---------------------------------------------------------------------------
#
# 兩種模式的差別只有一件事：要不要把使用者自己寫的程式碼疊回去。
#
#   scaffold   只產生全新骨架。用在「這個 repo 是別的專案的起點」——
#              docs/template.md 描述的那個情境。
#   carryover  先產生全新骨架，再從封存的 src tar 把使用者的程式碼疊回去。
#              用在「框架要升級，但我的東西要留著」。
#
# 為什麼是「先建骨架再疊」而不是「保留舊的再補」：框架升級真正會變的是
# 骨架檔（bootstrap/、config/、nuxt.config.ts、package.json 的相依範圍），
# 而那些正是最容易在手動合併時漏掉的。反過來做的話，你得知道「這一版新增
# 了哪些骨架檔」——而那份清單不存在。
#
# ⚠ 這一段跑在 _fresh_delete **之後**，也就是不可逆點的另一邊。所以：
#   * 每一步失敗都要立刻停，並且指向 cx fresh --rollback
#   * 不做任何「猜測性修補」——半個骨架比沒有骨架更難處理
#   * 所有外部指令都 </dev/null，避免互動式提示在非互動環境掛住

# 重建要用哪一條工具鏈。這裡不沿用 cx_runner()：重建的當下 docker/compose
# 的 app 服務還沒有映像（原始碼剛被刪掉），所以容器路徑只能用一次性的
# 官方映像，而不是本專案的映像。
_fresh_tool() {                     # _fresh_tool <node|php>
    case $1 in
        node) cx_have_native npm && { printf 'native'; return 0; } ;;
        php)  cx_have_native composer && cx_have_native php && { printf 'native'; return 0; } ;;
    esac
    cx_docker_ok && { printf 'docker'; return 0; }
    printf 'none'
}

# _fresh_delete 刪完之後會**重新建立空的** backend/ 與 frontend/
# （為了確保擁有者是呼叫者而不是之後某個容器的 root）。所以重建這一側的
# 前置條件不能是「目錄不存在」，而是「目錄是空的」——
# 2026-09-05 拋棄式副本實跑時，第一版寫成前者，於是重建在第一步就自己擋自己。
_fresh_dir_ready() {                # _fresh_dir_ready <path>
    local d=$1
    [[ -e $d ]] || return 0                       # 不存在：可以建
    [[ -d $d ]] || { cx_error "$d 存在但不是目錄"; return 1; }
    if [[ -n $(ls -A "$d" 2>/dev/null) ]]; then
        cx_error "$d 不是空的 —— 重建階段預期它是空的或不存在"
        return 1
    fi
    return 0
}

_fresh_rebuild_frontend() {
    local dir="$CX_ROOT/frontend"
    cx_step "重建前端（Vue 3 + Nuxt 4）"
    _fresh_dir_ready "$dir" || return 1

    local tool; tool=$(_fresh_tool node)
    case $tool in
        native)
            cx_info "用 host 的 npx 產生骨架"
            # 旗標的三個理由：
            #   --template minimal  非互動模式下 nuxi 把它列為**必填**，不給會直接
            #                       列出可用範本然後失敗（2026-09-05 實測）。
            #                       minimal 對應本專案原本的形狀：單一 app.vue。
            #   --no-install        相依交給 cx setup deps，重建階段不下載 400MB。
            #   --no-gitInit        三個 repo 的初始化統一由 _fresh_git_init 做。
            #                       非互動模式下這個布林旗標也是必填的 ——
            #                       「不給」不等於 false，會直接失敗（實測）。
            cx_run npx --yes nuxi@"$CX_NUXI_VERSION" init "$dir" \
                --template "${CX_NUXT_TEMPLATE:-minimal}" \
                --packageManager npm --no-install --no-gitInit --force </dev/null \
                || { cx_error "nuxi init 失敗"; return 1; }
            ;;
        docker)
            cx_info "用一次性的 node 映像產生骨架"
            cx_run docker run --rm -u "$(id -u):$(id -g)" \
                -v "$CX_ROOT:/w" -w /w \
                -e HOME=/tmp \
                "$CX_IMG_NODE" \
                npx --yes nuxi@"$CX_NUXI_VERSION" init frontend \
                --template "${CX_NUXT_TEMPLATE:-minimal}" \
                --packageManager npm --no-install --no-gitInit --force </dev/null \
                || { cx_error "nuxi init 失敗（容器）"; return 1; }
            ;;
        *)  cx_error "重建前端需要 npm 或 Docker，兩者都不可用"
            cx_dim "  cx setup tools node   或   啟用 Docker"
            return 1 ;;
    esac

    [[ -f $dir/nuxt.config.ts || -f $dir/nuxt.config.js ]] \
        || { cx_error "nuxi 沒有產生 nuxt.config —— 骨架不完整"; return 1; }
    cx_ok "frontend/ 骨架完成"
}

_fresh_rebuild_backend() {
    local dir="$CX_ROOT/backend"
    cx_step "重建後端（Laravel 13 + Filament v5 + Larastan）"
    # composer create-project 不接受「已存在且非空」的目標，空目錄則沒問題。
    _fresh_dir_ready "$dir" || return 1
    # 空目錄也要先移開：create-project 對「已存在的目錄」一律拒絕，即使是空的。
    [[ -d $dir ]] && cx_run rmdir "$dir"

    local tool; tool=$(_fresh_tool php)
    local -a run=()
    case $tool in
        native) run=(env -C "$CX_ROOT") ;;
        docker)
            # 用官方 composer 映像，不是本專案的 app 映像 —— 後者此刻還沒建。
            # -e HOME=/tmp：以非 root 身分跑時 composer 要有地方寫快取，
            # 沒有的話會噴 "Cannot create cache directory" 的警告甚至失敗。
            # 前端那條路一直都有這個旗標，後端漏了。
            run=(docker run --rm -u "$(id -u):$(id -g)"
                 -e HOME=/tmp
                 -v "$CX_ROOT:/w" -w /w
                 "$CX_IMG_COMPOSER")
            ;;
        *)  cx_error "重建後端需要 composer + php 或 Docker，都不可用"
            cx_dim "  cx setup tools composer && cx setup system php   或   啟用 Docker"
            return 1 ;;
    esac


    cx_info "composer create-project laravel/laravel"
    cx_run "${run[@]}" composer create-project laravel/laravel backend \
        --no-interaction --prefer-dist </dev/null \
        || { cx_error "create-project 失敗"; return 1; }

    local -a runb=()
    case $tool in
        native) runb=(env -C "$dir") ;;
        docker) runb=(docker run --rm -u "$(id -u):$(id -g)"
                      -e HOME=/tmp
                      -v "$CX_ROOT:/w" -w /w/backend
                      "$CX_IMG_COMPOSER") ;;
    esac

    cx_info "composer require filament/filament:^5.0"
    cx_run "${runb[@]}" composer require filament/filament:^5.0 \
        --no-interaction --no-scripts </dev/null \
        || { cx_error "安裝 Filament 失敗"; return 1; }

    cx_info "composer require --dev larastan/larastan:^3.0"
    cx_run "${runb[@]}" composer require --dev larastan/larastan:^3.0 \
        --no-interaction --no-scripts </dev/null \
        || { cx_error "安裝 Larastan 失敗"; return 1; }

    [[ -f $dir/artisan ]] || { cx_error "backend/artisan 不存在 —— 骨架不完整"; return 1; }
    cx_ok "backend/ 骨架完成"
    cx_dim "  Filament 面板與 Larastan 設定要在相依裝好之後才能產生："
    cx_dim "    cx setup deps && cx art filament:install --panels && cx scan code"
}

# carryover：把使用者自己的程式碼從封存疊回新骨架上。
# 只疊「應用層」的目錄 —— 骨架檔（config/、bootstrap/、package.json、
# nuxt.config.ts）刻意讓新版的贏，那正是重建的目的。
_fresh_carryover() {
    local A=$1 c
    cx_step "把應用層程式碼疊回新骨架（carryover）"
    local tmp; tmp=$(mktemp -d) || return 1
    # shellcheck disable=SC2064  # 刻意用單引號延後展開：$tmp 是 local，RETURN
    #   trap 執行時仍在作用域內。用雙引號把路徑烘進去的話，TMPDIR 含單引號
    #   就會把壞掉的路徑交給 rm -rf。全庫其他 11 處都是這個安全形式。
    trap 'rm -rf "${tmp:-}"' RETURN

    local c d n
    for c in backend frontend; do
        [[ -f $A/src-$c.tar.gz ]] || { cx_warn "$c 沒有封存的原始碼，略過"; continue; }
        cx_run tar -xzf "$A/src-$c.tar.gz" -C "$tmp" || return 1
        n=0
        # while-read 而不是 `for d in ${KEEP[$c]}` —— 後者靠字詞分割，
        # 目錄名含空白就會裂開。shellcheck 的 SC2086 抓得到，但 _lint_sh
        # 只 gate error，所以那個問題在 CI 上是看不見的。
        while IFS= read -r d; do
            [[ -n $d ]] || continue
            [[ -d $tmp/$c/$d ]] || continue
            cx_run mkdir -p "$CX_ROOT/$c/$(dirname "$d")" || return 1
            # -T：把來源目錄的**內容**疊上去，而不是變成子目錄
            cx_run cp -a -T "$tmp/$c/$d" "$CX_ROOT/$c/$d" || return 1
            n=$((n + 1))
        done < <(_fresh_keep_dirs "$c")
        cx_ok "$c：疊回 $n 個目錄"
        cx_dim "  骨架檔（config/、bootstrap/、package.json、nuxt.config）刻意用新版的"
        cx_dim "  舊版留在封存裡：$A/src-$c.tar.gz"
    done

    # 這裡曾經另外用 sed 把 phpunit.xml 的 bootstrap= 接回去。
    # 現在 _fresh_rebuild 會在 carryover **之後**跑 scaffold_patch.py，
    # 那支程式已經負責同一件事（而且是整組零件一起，不只 phpunit.xml）。
    # 留兩份實作的話，兩邊的比對條件會各自演化：這裡只換字面上的
    # vendor/autoload.php，scaffold_patch 換的是任何 bootstrap="…"。
}

_fresh_rebuild() {                  # _fresh_rebuild <mode> <archive_dir>
    local mode=$1 A=$2
    # dry-run 之下前面的刪除沒有真的發生，所以 backend/ 與 frontend/ 還是滿的，
    # 重建一定會撞到「目錄不是空的」。那不是缺陷，是 dry-run 的必然結果 ——
    # 但它不該被報成失敗，否則 `cx --dry-run fresh` 永遠跑不完整條流程。
    if (( CX_DRY_RUN )); then
        cx_step "重建（dry-run：略過）"
        cx_dim "  [dry-run] mode=$mode —— 實際執行時會："
        cx_dim "    composer create-project laravel/laravel backend（+ filament/filament、larastan）"
        cx_dim "    npx nuxi init frontend --template minimal"
        [[ $mode == carryover ]] && cx_dim "    再從 $A 的 src-*.tar.gz 疊回應用層目錄"
        return 0
    fi
    _fresh_rebuild_backend  || return 1
    _fresh_rebuild_frontend || return 1

    [[ $mode == carryover ]] && { _fresh_carryover "$A" || return 1; }

    # ── 把「範本自己擁有的東西」裝回去 ──────────────────────────────────────
    #
    # composer create-project 與 nuxi init 產生的是**框架的**骨架，
    # 裡面當然沒有本專案加上去的保護。少了這一步，cx init 交出來的新專案會：
    #   * 沒有測試資料庫的 hard guard（phpunit.xml 的 bootstrap= 也會被寫回
    #     vendor/autoload.php —— 檔案在不在都無所謂了，因為沒有人呼叫它）
    #   * 沒有 ESLint 基線
    # 2026-09-05 實測：修這一段之前，cx init shop 產出的專案 cx verify cli
    # 有 9 個 FAIL，其中 6 個就是這兩組。
    #
    # ⚠ 必須排在 _fresh_carryover **之後**。
    #   carryover 用 `cp -a -T` 把封存的 tests/ 疊上來，會覆蓋同名檔案 ——
    #   排在前面的話，從「還沒有防護的舊專案」carryover 過來時，
    #   剛裝好的 TestCase.php 會被舊版蓋掉（實測 assertResolvedConfig 由 1 變 0），
    #   而 bootstrap.php 因為封存裡沒有反而留著 —— 一個半接上的防護，
    #   Layer A 在跑、Layer B 不見了，而 _fresh_verify_rebuild 也不會發現。
    #   範本擁有的檔案必須是**最後**寫入的那一個。
    cx_step "裝回範本自有的設定（測試防護 / ESLint）"
    cx_run python3 "$CX_ROOT/bin/lib/scaffold_patch.py" --root "$CX_ROOT" \
        || { cx_error "範本設定裝回失敗"; return 1; }
    return 0
}

# ---------------------------------------------------------------------------
# 重建結果的驗證（在 git-init 之前）
# ---------------------------------------------------------------------------
#
# 為什麼一定要有這一步：原本 _fresh_rebuild 成功之後直接進 _fresh_git_init，
# 也就是把重建結果**無條件 commit 進去**。如果 nuxi 或 composer 產出的是半套
# 骨架（網路中斷、磁碟滿、上游改了旗標），那段歷史就進了新的 repo ——
# 而還原時你會多出一段不該保留的歷史，比沒有 commit 更難處理。
#
# 這一步必須便宜、離線、只回答一個問題：這個骨架完整到可以 commit 了嗎。
_fresh_verify_rebuild() {           # _fresh_verify_rebuild <mode> <archive>
    local mode=$1 A=$2 fail=0
    if (( CX_DRY_RUN )); then
        cx_step "驗證重建結果（dry-run：略過，因為沒有真的重建）"
        return 0
    fi
    cx_step "驗證重建結果"

    # ── 結構 ────────────────────────────────────────────────────────────
    local f
    for f in backend/artisan backend/composer.json backend/phpunit.xml; do
        [[ -f $CX_ROOT/$f ]] && cx_ok "存在：$f" || { cx_error "缺少：$f"; fail=1; }
    done
    if [[ -f $CX_ROOT/frontend/nuxt.config.ts || -f $CX_ROOT/frontend/nuxt.config.js ]]; then
        cx_ok "存在：frontend/nuxt.config"
    else
        cx_error "缺少：frontend/nuxt.config.{ts,js}"; fail=1
    fi
    [[ -f $CX_ROOT/frontend/package.json ]] \
        && cx_ok "存在：frontend/package.json" || { cx_error "缺少：frontend/package.json"; fail=1; }

    # 三個必要套件 —— 骨架建起來了不代表相依對
    local pkg
    for pkg in laravel/framework filament/filament larastan/larastan; do
        grep -q "\"$pkg\"" "$CX_ROOT/backend/composer.json" 2>/dev/null \
            && cx_ok "composer.json 含 $pkg" || { cx_error "composer.json 缺少 $pkg"; fail=1; }
    done

    # ── 根目錄的基礎設施 ────────────────────────────────────────────────
    # 少了這一段，「重建完成」可以在**沒有 docker-compose.yml** 的情況下宣告成功，
    # 而使用者要到下一次 cx dev up 才發現整個 compose 都不能用。
    # 這正是 2026-09-05 抓到的那個缺陷會走的路徑。
    for f in docker-compose.yml .dockerignore docker/compose/dev.yml \
             docker/compose/test.yml docker/compose/prod.yml; do
        [[ -f $CX_ROOT/$f ]] && cx_ok "存在：$f" || { cx_error "缺少：$f"; fail=1; }
    done
    # 而且要是**現行**那一份（引用 docker/compose/），不是舊版面留下來的
    if grep -q 'docker/compose/' "$CX_ROOT/docker-compose.yml" 2>/dev/null; then
        cx_ok "docker-compose.yml 是現行版面（引用 docker/compose/）"
    else
        cx_error "docker-compose.yml 不是現行版面 —— 沒有引用 docker/compose/"
        fail=1
    fi

    # ── 不該有的殘留 ────────────────────────────────────────────────────
    # 前一次半途失敗留下的 .git 會讓 git submodule add 報
    # 「already exists and is not a valid git repo」，而訊息不會提到是殘留。
    local c
    for c in backend frontend; do
        if [[ -e $CX_ROOT/$c/.git ]]; then
            cx_error "$c/.git 已存在 —— 上一次重建的殘留，會讓 submodule add 失敗"
            cx_dim "  處理：rm -rf $CX_ROOT/$c/.git 之後重跑 --resume-from git-init"
            fail=1
        fi
    done

    # ── carryover 的完整性 ──────────────────────────────────────────────
    # 這是唯一抓得到「cp -a -T 疊到一半失敗」的檢查：比對封存裡的項目數
    # 與樹上的項目數。cp 的部分失敗在上面的結構檢查裡完全看不出來。
    if [[ $mode == carryover ]]; then
        local tmp; tmp=$(mktemp -d) || return 1
        # shellcheck disable=SC2064
        trap 'rm -rf "${tmp:-}"' RETURN
        local d n_arc n_tree
        for c in backend frontend; do
            [[ -f $A/src-$c.tar.gz ]] || continue
            tar -xzf "$A/src-$c.tar.gz" -C "$tmp" 2>/dev/null || continue
            while IFS= read -r d; do
                [[ -n $d && -d $tmp/$c/$d ]] || continue
                if [[ ! -d $CX_ROOT/$c/$d ]]; then
                    cx_error "carryover 沒疊回：$c/$d"; fail=1; continue
                fi
                n_arc=$(find "$tmp/$c/$d" -type f | wc -l)
                n_tree=$(find "$CX_ROOT/$c/$d" -type f | wc -l)
                if (( n_tree < n_arc )); then
                    cx_error "carryover 疊回不完整：$c/$d（封存 $n_arc 個檔，樹上只有 $n_tree 個）"
                    fail=1
                else
                    cx_ok "carryover：$c/$d（$n_tree 個檔）"
                fi
            done < <(_fresh_keep_dirs "$c")
        done
    fi

    # ── 測試資料庫防護的接線 ────────────────────────────────────────────
    # carryover 的 KEEP 帶 tests 但**不帶 phpunit.xml**，所以重建會把
    # tests/bootstrap.php 疊回去、卻讓 phpunit.xml 回到 vendor/autoload.php
    # —— 防護的檔案都在，但沒有人呼叫它了。
    if [[ -f $CX_ROOT/backend/tests/bootstrap.php ]]; then
        if grep -q 'bootstrap="tests/bootstrap.php"' "$CX_ROOT/backend/phpunit.xml" 2>/dev/null; then
            cx_ok "測試資料庫防護的接線完整"
        elif [[ $mode == carryover ]]; then
            cx_error "tests/bootstrap.php 疊回來了，但 phpunit.xml 沒有指向它"
            cx_dim "  carryover 的 KEEP 帶 tests、不帶 phpunit.xml —— 防護會靜默失效。"
            cx_dim "  修正：把 phpunit.xml 的 bootstrap= 改成 tests/bootstrap.php"
            fail=1
        else
            cx_warn "scaffold 產生了全新的 phpunit.xml —— 測試資料庫防護需要重新接上"
            cx_dim "  把 bootstrap= 改成 tests/bootstrap.php（cx verify cli 的 GRD-wire 會盯著）"
        fi
    fi

    # ── 沿用既有的驗收機制 ──────────────────────────────────────────────
    # cli / docs / tui 這三個範圍不需要 Docker、不需要 .env，在剛重建完的
    # 樹上就跑得完 —— 那正是重建之後的狀態。報告寫進**封存目錄**，
    # 這樣證據在之後的 rollback 之後仍然留著。
    if (( ! CX_DRY_RUN )) && [[ -d $A ]]; then
        if "$CX_ROOT/cx" --root "$CX_ROOT" verify cli docs tui --quiet \
                --report "$A/post-rebuild-verify.md" >/dev/null 2>&1; then
            cx_ok "cx verify cli docs tui 通過（報告：$A/post-rebuild-verify.md）"
        else
            cx_warn "cx verify cli docs tui 有 FAIL —— 見 $A/post-rebuild-verify.md"
            cx_dim "  這一項不擋 git-init：重建之後的文件與實作不一致是預期的，"
            cx_dim "  但要有人看過。上面的結構檢查才是擋門的那一道。"
        fi
    fi

    (( fail == 0 )) || { cx_error "重建結果驗證未通過"; return 1; }
    cx_ok "重建結果完整"
}

# ---------------------------------------------------------------------------
# 三個 Git 的初始化
# ---------------------------------------------------------------------------
# 順序不可調換：子模組要先是有效的 repo（且有至少一個 commit），
# 主庫才 submodule add 得起來 —— 對一個沒有 commit 的 repo 做 submodule add
# 會得到 "does not have a commit checked out"。
_fresh_git_init() {
    if (( CX_DRY_RUN )); then
        cx_step "初始化三個 Git repo（dry-run：略過）"
        cx_dim "  [dry-run] backend 與 frontend 各 git init -b <CX_GIT_MAIN_BRANCH> + 首次 commit"
        cx_dim "  [dry-run] 主庫 git init + submodule add（相對 URL，追蹤 <CX_GIT_MAIN_BRANCH>）+ commit"
        cx_dim "  [dry-run] 三個 repo 各建立 <CX_GIT_DEV_BRANCH>，主庫設 submodule.recurse"
        return 0
    fi
    cx_step "初始化三個 Git repo"
    # 分支名一律從 .cxroot 推導。原本三處寫死 -b main，於是 .cxroot 的
    # CX_GIT_MAIN_BRANCH 只是裝飾 —— 改了它，cx init 產出的專案還是 main。
    # git.sh 的存取器是唯一來源；fresh 只是它的另一個使用者。
    declare -F _git_main_branch >/dev/null || . "$CX_ROOT/bin/cmd/git.sh"
    local main_br dev_br
    main_br=$(_git_main_branch); dev_br=$(_git_dev_branch)
    local c
    for c in backend frontend; do
        [[ -d $CX_ROOT/$c ]] || { cx_error "$c 不存在，無法初始化"; return 1; }
        if [[ -e $CX_ROOT/$c/.git ]]; then
            cx_ok "$c 已經是 git repo，略過"
            continue
        fi
        cx_run git -C "$CX_ROOT/$c" init -b "$main_br" || return 1
        # .gitignore 從 templates/ 拿 —— 那是本專案維護的版本，
        # 比框架自帶的更貼近這裡的目錄佈局（vendor 的 volume、reports/ 等）。
        [[ -f $CX_ROOT/templates/gitignore/$c ]] \
            && cx_run cp "$CX_ROOT/templates/gitignore/$c" "$CX_ROOT/$c/.gitignore"
        cx_run git -C "$CX_ROOT/$c" add -A || return 1
        cx_run git -C "$CX_ROOT/$c" commit -q -m "初始化 $(cx_project)-$c" || return 1
        cx_ok "$c：$(git -C "$CX_ROOT/$c" rev-parse --short HEAD 2>/dev/null)"
    done

    if [[ ! -e $CX_ROOT/.git ]]; then
        cx_run git -C "$CX_ROOT" init -b "$main_br" || return 1
        [[ -f $CX_ROOT/templates/gitignore/main ]] \
            && cx_run cp "$CX_ROOT/templates/gitignore/main" "$CX_ROOT/.gitignore"
    fi

    # 子模組用**相對** URL（../<repo>.git）。絕對 URL 會把某一台機器的
    # 使用者名稱／協定烘進版控，別人 clone 下來一定要手改。
    # 相對 URL 由主庫的 origin 推導，所以在還沒有 origin 的本地端也能先掛上，
    # 之後 cx git remote-init 建好遠端就自動對得起來。
    local url
    for c in backend frontend; do
        git -C "$CX_ROOT" config --file .gitmodules --get "submodule.$c.url" >/dev/null 2>&1 && {
            cx_ok "$c 已在 .gitmodules 中"; continue; }
        case $c in
            backend)  url="../${CX_REPO_BACKEND:-$(cx_project)-backend}.git" ;;
            frontend) url="../${CX_REPO_FRONTEND:-$(cx_project)-frontend}.git" ;;
        esac
        # 先用本地路徑 add（此刻遠端還不存在），再把 URL 改寫成相對形式。
        # ⚠ -b 用 main_br 而不是 dev_br。.gitmodules 的 branch 只能寫**一個**值，
        #   而主庫有 main 與 dev 兩條線；子模組該站哪一條由 _git_sub_target_branch()
        #   依主庫當前分支決定，這裡的值只是 fallback 與 git submodule update --remote
        #   的目標。原本寫 dev_br，於是範本自己（main）與 cx init 產物（dev）
        #   對同一個指令行為不同 —— 兩份會漂移的事實。
        cx_run git -C "$CX_ROOT" -c protocol.file.allow=always \
            submodule add --force -b "$main_br" "./$c" "$c" || return 1
        cx_run git -C "$CX_ROOT" config --file .gitmodules "submodule.$c.url" "$url" || return 1
        cx_ok "$c → $url"
    done

    # ⚠ submodule add 對「已經是有效 repo」的目錄**不會 absorb gitdir** ——
    # 它只印 "Adding existing repo at 'backend' to the index"，於是 backend/.git
    # 留成真目錄、.git/modules/ 是空的。那跟任何人 clone 下來看到的佈局**不一樣**：
    #   * 別人 clone 得到指標檔 + .git/modules/backend
    #   * cx init 產出的卻是各自獨立的 .git 目錄
    # 兩種佈局在 archive.sh 走的是不同分支（rev-parse --absolute-git-dir 的結果
    # 一個在樹內、一個在樹外），也就是新專案第一次 cx fresh 的封存形狀會跟
    # 範本自己的不一樣。收斂成標準佈局，讓後續每一條路徑只需要面對一種現實。
    cx_run git -C "$CX_ROOT" submodule absorbgitdirs \
        || cx_warn "submodule absorbgitdirs 失敗 —— 子模組的 .git 仍是獨立目錄（不影響功能）"

    cx_run git -C "$CX_ROOT" add -A || return 1
    if git -C "$CX_ROOT" diff --cached --quiet; then
        cx_ok "主庫沒有要提交的變更"
    else
        cx_run git -C "$CX_ROOT" commit -q -m "初始化 $(cx_project)：$(cx_project)-backend 與 $(cx_project)-frontend 子模組" \
            || return 1
        cx_ok "主庫：$(git -C "$CX_ROOT" rev-parse --short HEAD 2>/dev/null)"
    fi
    # gitflow 的分支拓撲。原本完全沒有這一步 —— 新專案三個 repo 只有 main，
    # 於是 cx git feature start 第一次就 EX_PRECOND。與 cx git flow-init 共用
    # 同一個函式，免得「新專案長什麼樣」與「舊專案補成什麼樣」變成兩份定義。
    _git_flow_ensure_branches || cx_warn "分支拓撲沒有補完 —— 之後可以跑 cx git flow-init"

    cx_dim "  遠端還沒建。要建： cx git remote-init（需要 gh 已登入）"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 階段機
# ---------------------------------------------------------------------------
#
# --phase <名稱>        天花板：跑到這一步為止（含）
# --resume-from <名稱>  地板：從這一步開始（含）
#
# 為什麼要分成兩個旗標而不是共用 --phase：
#   舊的 --phase 語意是**不一致**的 —— preflight 與 migrate 是「只跑這一步就返回」，
#   backup 與 delete 是「跑到這一步為止」。所以 `cx fresh --phase migrate`
#   會跳過 preflight、備份**與確認閘門**，直接開始複製檔案。那是設計缺陷。
#   現在 --phase 一律是天花板，語意單一；「從中間開始」交給 --resume-from。
#   把 --phase delete 悄悄改成「從 delete 開始」會把一個有界的指令變成
#   無界的破壞性指令，所以必須是不同的旗標。
_FRESH_PHASES=(preflight backup migrate delete rebuild verify git-init)

_fresh_phase_index() {              # _fresh_phase_index <名稱> → 索引
    local want=$1 i=0 ph
    for ph in "${_FRESH_PHASES[@]}"; do
        [[ $ph == "$want" ]] && { printf '%s' "$i"; return 0; }
        i=$((i + 1))
    done
    return 1
}

# ── 麵包屑 ─────────────────────────────────────────────────────────────────
# 沒有它的話：_fresh_delete 中途被 SIGKILL 之後，下一次執行的 preflight
# 看到的是一棵沒有 .git 的樹，PF-04/05 只是 skip，流程照跑，然後
# LATEST 被**覆寫成那份沒用的新封存** —— 從此 cx fresh --rollback
# （不帶 --from）什麼都還原不了。唯一的安全網就這樣被自己蓋掉了。
_FRESH_STATE=".cx/fresh.state"

# 語意：除了 delete 之外都是「已完成的階段」；delete 是「**已進入**」——
# 理由見 cmd_fresh_main 裡那段呼叫的註解（唯一不可逆的階段要撐過中途被砍）。
_fresh_state_write() {              # _fresh_state_write <階段> <封存路徑>
    (( CX_DRY_RUN )) && return 0
    cx_ensure_host_dirs "$CX_ROOT/.cx" >/dev/null 2>&1
    printf 'phase=%s\narchive=%s\nstamp=%s\n' "$1" "$2" "$(cx_stamp)" \
        > "$CX_ROOT/$_FRESH_STATE"
}

_fresh_state_get() {                # _fresh_state_get <鍵>
    [[ -f $CX_ROOT/$_FRESH_STATE ]] || return 1
    sed -n "s/^$1=//p" "$CX_ROOT/$_FRESH_STATE" | head -1
}

_fresh_state_clear() { (( CX_DRY_RUN )) || rm -f "$CX_ROOT/$_FRESH_STATE"; }

# 過了不可逆點之後才寫下的救援指引。終端機的捲動記錄是最容易弄丟的東西，
# 一個放在專案根目錄的檔案不可能被忽略。
_fresh_recovery_note() {            # _fresh_recovery_note <封存路徑> <情境>
    (( CX_DRY_RUN )) && return 0
    local A=$1 why=$2
    cat > "$CX_ROOT/CX-RECOVERY.md" <<EOF
# cx fresh 中斷後的救援指引

情境：$why
時間：$(date -u +%Y-%m-%dT%H:%M:%SZ)
封存：$A

## 回到重建前的狀態

    cx fresh --rollback --from $A

還原前會先驗證封存，被覆蓋的內容會先移到 .cx-restore-backup/<時間戳>/。
資料庫不在還原範圍 —— 要的話另外跑：

    cx db restore $A/db-*.sql.gz

## 或者，從失敗的那一步繼續

    cx fresh --resume-from rebuild --from $A --mode <carryover|scaffold>

## 確認沒問題之後

刪掉這個檔案，以及 .cx/fresh.state。
EOF
    cx_warn "救援指引已寫到 CX-RECOVERY.md"
}

cmd_fresh_main() {
    local phase=all mode=carryover rollback=0 from='' resume=''
    while (( $# )); do
        case $1 in
            --phase)        [[ -n ${2:-} ]] || cx_die "$EX_USAGE" "--phase 需要一個值"
                            phase=$2; shift 2 ;;
            --phase=*)      phase=${1#*=}; shift ;;
            --resume-from)  [[ -n ${2:-} ]] || cx_die "$EX_USAGE" "--resume-from 需要一個值"
                            resume=$2; shift 2 ;;
            --resume-from=*) resume=${1#*=}; shift ;;
            --mode)         [[ -n ${2:-} ]] || cx_die "$EX_USAGE" "--mode 需要一個值"
                            mode=$2; shift 2 ;;
            --mode=*)       mode=${1#*=}; shift ;;
            --rollback)     rollback=1; shift ;;
            --from)         [[ -n ${2:-} ]] || cx_die "$EX_USAGE" "--from 需要一個路徑"
                            from=$(cx_resolve "$2"); shift 2 ;;
            --from=*)       from=$(cx_resolve "${1#*=}"); shift ;;
            -h|--help)      _fresh_usage; return 0 ;;
            *)              cx_die "$EX_USAGE" "未知參數：$1" ;;
        esac
    done

    # 白名單驗證 —— 少了這段，任何打錯的 phase 都會 fall through 到完整的
    # 破壞性流程。
    local ceiling floor=0
    if [[ $phase == all ]]; then
        ceiling=$(( ${#_FRESH_PHASES[@]} - 1 ))
    else
        ceiling=$(_fresh_phase_index "$phase") \
            || cx_die "$EX_USAGE" "未知的 phase：$phase（${_FRESH_PHASES[*]} all）"
    fi
    if [[ -n $resume ]]; then
        case $resume in
            rebuild|verify|git-init) : ;;
            *) cx_die "$EX_USAGE" \
                "--resume-from 只接受 rebuild|verify|git-init（收到 $resume）
    更早的階段涉及備份與刪除，不能跳過 —— 那些就是要重跑整個流程。" ;;
        esac
        floor=$(_fresh_phase_index "$resume")
    fi
    (( floor <= ceiling )) || cx_die "$EX_USAGE" \
        "--resume-from $resume 比 --phase $phase 還晚，沒有東西可以跑"
    case $mode in
        backup-only|git-only|carryover|scaffold) : ;;
        *) cx_die "$EX_USAGE" "未知的 mode：$mode（backup-only|git-only|carryover|scaffold）" ;;
    esac

    # archive.sh 要在這裡就載入，不能等到下面 —— 底下 --rollback 會呼叫
    # cx_archive_root()，那個函式定義在 archive.sh 裡。原本 source 寫在旗標
    # 處理之後，於是 `cx fresh --rollback` 會得到 command not found，
    # 而不是它該給的訊息。
    # shellcheck source=/dev/null
    . "$CX_ROOT/bin/lib/archive.sh"

    # ── --rollback：從封存還原 ───────────────────────────────────────────
    if (( rollback )); then
        local src=$from
        if [[ -z $src ]]; then
            local latest; latest="$(cx_archive_root --probe)/LATEST"
            [[ -f $latest ]] || cx_die "$EX_PRECOND" \
                "沒有 --from，也找不到 $latest —— 先跑過 cx fresh 才會有封存"
            src=$(<"$latest")
        fi
        cx_lock fresh
        local rrc=0
        cx_restore "$src" || rrc=$?
        (( rrc )) || { _fresh_state_clear; rm -f "$CX_ROOT/CX-RECOVERY.md"; }
        return "$rrc"
    fi
    [[ -n $from && -z $resume ]] && cx_warn "--from 只有 --rollback 與 --resume-from 會用到，本次忽略"

    cx_lock fresh

    # ── 中斷偵測 ────────────────────────────────────────────────────────
    local prev_phase prev_arc
    prev_phase=$(_fresh_state_get phase 2>/dev/null || true)
    prev_arc=$(_fresh_state_get archive 2>/dev/null || true)
    if [[ -n $prev_phase && -z $resume ]]; then
        local pidx; pidx=$(_fresh_phase_index "$prev_phase" 2>/dev/null || echo -1)
        if (( pidx >= 3 )); then      # delete 之後 = 已過不可逆點
            cx_error "上一次 cx fresh 停在「$prev_phase」之後就沒有繼續（$CX_ROOT/$_FRESH_STATE）"
            cx_dim "  這棵樹已經過了不可逆點。重跑整個流程會把**已經被刪掉的狀態**"
            cx_dim "  重新封存一次，並覆寫 LATEST —— 原本那份救得回來的封存就找不到了。"
            cx_dim ""
            cx_dim "  接續：    cx fresh --resume-from rebuild --from $prev_arc --mode $mode"
            cx_dim "  或還原：  cx fresh --rollback --from $prev_arc"
            cx_dim "  真的要重來： rm $CX_ROOT/$_FRESH_STATE"
            return "$EX_PRECOND"
        fi
    fi

    local A=''
    # ── 0 preflight ─────────────────────────────────────────────────────
    if (( floor <= 0 && ceiling >= 0 )); then
        _fresh_preflight || return $?
        _fresh_state_write preflight ''
    fi
    (( ceiling >= 1 )) || { cx_ok "preflight 階段完成"; return 0; }

    # ── 1 backup（含驗證與確認閘門）──────────────────────────────────────
    if (( floor <= 1 )); then
        # dry-run 之下只探測路徑，不建立目錄
        if (( CX_DRY_RUN )); then
            A="$(cx_archive_root --probe)/$(cx_stamp)"
        else
            A="$(cx_archive_root)/$(cx_stamp)"
        fi
        cx_info "封存目錄：$A"
        cx_backup "$A" || return $?
        cx_verify_archive "$A" || cx_die "$EX_FAIL" "封存驗證失敗 —— 未刪除任何東西"
        (( CX_DRY_RUN )) || printf '%s\n' "$A" > "$(cx_archive_root)/LATEST"
        _fresh_state_write backup "$A"

        if [[ $mode == backup-only ]]; then
            cx_ok "backup-only 完成，未刪除任何東西"
            cx_info "封存：$A"
            _fresh_state_clear
            return 0
        fi
        (( ceiling >= 2 )) || { cx_ok "backup 階段完成"; cx_info "封存：$A"; _fresh_state_clear; return 0; }

        # 閘門必須在 _fresh_migrate **之前**。
        # 原本順序是 migrate → gate，而 migrate 會把 docker-compose.yml /
        # .dockerignore / README.md 複製成 docker/legacy/*.orig —— 那是三個
        # 進版控的檔案。於是使用者在確認畫面按取消，畫面印「未變更任何檔案」，
        # git status 卻多出三個 M。訊息說謊比動到檔案更糟。
        _fresh_gate "$A" "$mode" || { _fresh_state_clear; return "$EX_ABORT"; }
    else
        # resume：沿用上一次的封存
        A=${from:-$prev_arc}
        [[ -n $A && -d $A ]] || cx_die "$EX_PRECOND" \
            "--resume-from 需要知道用哪一份封存 —— 給 --from <目錄>，或讓 .cx/fresh.state 存在"
        cx_info "沿用既有封存：$A"
    fi

    # ── 2 migrate ───────────────────────────────────────────────────────
    # git-only 不碰任何非 git 的檔案，所以遷移舊版面的 docker 設定與它無關。
    if [[ $mode == git-only ]]; then
        cx_dim "  git-only：略過 migrate（不動任何非 git 的檔案）"
    elif (( floor <= 2 && ceiling >= 2 )); then
        # migrate 的 rc 一定要檢查。閘門已經過了，這裡是不可逆點的另一邊 ——
        # 遷移失敗卻繼續 _fresh_delete，等於把 docker 自定義設定連同原處
        # 一起刪掉，而 docker/legacy/ 底下沒有可用的副本。
        _fresh_migrate || { _fresh_recovery_note "$A" "遷移失敗"; cx_die "$EX_FAIL" \
            "遷移失敗 —— 已中止，未刪除任何東西（封存在 $A）"; }
        _fresh_state_write migrate "$A"
    fi
    (( ceiling >= 3 )) || { cx_ok "migrate 階段完成"; cx_info "封存：$A"; return 0; }

    # ── 3 delete（不可逆點）──────────────────────────────────────────────
    if (( floor <= 3 )); then
        # ⚠ 麵包屑必須寫在 _fresh_delete **之前**。
        # 原本寫在之後：刪除途中被 SIGKILL 的話，狀態仍停在 migrate（index 2），
        # 於是下一次執行的守門 `pidx >= 3` 不成立 —— cx fresh 會對著已經被毀掉
        # 的樹重新封存一次，並**覆寫 LATEST**，把唯一救得回來的封存蓋掉。
        # 那正是 _fresh_state_write 上方註解宣稱要防的事，而它防不到。
        # delete 這一格因此讀作「已進入」而非「已完成」—— 它是唯一不可逆的階段，
        # 而麵包屑存在的意義就是撐過「死在階段中間」。
        _fresh_state_write delete "$A"
        _fresh_delete "$mode" || { _fresh_recovery_note "$A" "刪除失敗"; return "$EX_FAIL"; }
    fi
    (( ceiling >= 4 )) || { cx_ok "delete 階段完成"; cx_info "封存：$A"; return 0; }

    # ── 4 rebuild ───────────────────────────────────────────────────────
    # git-only 沒有重建骨架，所以也沒有東西要 rebuild 或 verify ——
    # 那兩格檢查的全部內容都是「新產生的骨架完不完整」。
    if [[ $mode == git-only ]]; then
        cx_dim "  git-only：略過 rebuild 與 verify（沒有產生新骨架）"
    elif (( floor <= 4 )); then
        if ! _fresh_rebuild "$mode" "$A"; then
            _fresh_recovery_note "$A" "重建失敗（mode=$mode）"
            _fresh_offer_rollback "$A" "重建失敗"
            return "$EX_FAIL"
        fi
        _fresh_state_write rebuild "$A"
    fi
    (( ceiling >= 5 )) || { cx_ok "rebuild 階段完成"; cx_info "封存：$A"; return 0; }

    # ── 5 verify（重建之後、git-init 之前）───────────────────────────────
    if [[ $mode == git-only ]]; then
        :
    elif (( floor <= 5 )); then
        if ! _fresh_verify_rebuild "$mode" "$A"; then
            _fresh_recovery_note "$A" "重建結果驗證失敗"
            cx_error "重建的結果不完整 —— **不會**繼續 git-init"
            cx_dim "  把半套骨架 commit 進去會讓還原更難：你會多出一段不該保留的歷史。"
            _fresh_offer_rollback "$A" "重建結果驗證失敗"
            return "$EX_FAIL"
        fi
        _fresh_state_write verify "$A"
    fi
    (( ceiling >= 6 )) || { cx_ok "verify 階段完成"; cx_info "封存：$A"; return 0; }

    # ── 6 git-init ──────────────────────────────────────────────────────
    if (( floor <= 6 )); then
        if ! _fresh_git_init; then
            _fresh_recovery_note "$A" "Git 初始化失敗"
            cx_error "Git 初始化失敗 —— 前後端已重建，但還沒有版控"
            return "$EX_FAIL"
        fi
    fi

    _fresh_state_clear
    rm -f "$CX_ROOT/CX-RECOVERY.md" 2>/dev/null || true
    cx_ok "清理與重建完成"
    cx_info "封存：$A"
    cx_dim "  後續： cx setup deps  →  cx dev up -d --build  →  cx doctor"
    cx_dim "  要回到重建前： cx fresh --rollback --from $A"
}

# 失敗之後的還原提議。
#
# 刻意**不自動**還原：cx_restore 會把現有的樹搬進 .cx-restore-backup/ 再覆蓋。
# 如果重建是因為磁碟滿或網路斷才失敗，自動還原會讓磁碟壓力加倍、而且可能
# 自己也失敗到一半 —— 那會產生**第三種**狀態，比停在第二種更糟。
#
# 也刻意不只是印出指令：操作者就在鍵盤前，封存已經驗證過，下一步毫無歧義。
# 讓他去複製貼上一段路徑，是「訊息告訴你該做什麼但不幫你做」的那種設計。
#
# --yes 之下**不**自動還原 —— 那個旗標的意思是「我預先同意我打的那個破壞性
# 計畫」，不是「出事時你看著辦」。這個不對稱是刻意的，所以要講出來。
_fresh_offer_rollback() {
    local A=$1 why=$2
    if (( CX_ASSUME_YES )); then
        cx_warn "--yes 之下不自動還原（那個旗標同意的是你打的計畫，不是出事後的處置）"
        cx_dim "  要還原： cx fresh --rollback --from $A"
        return 0
    fi
    cx_confirm "還原" "$why。\n\n要現在從封存還原嗎？\n\n  $A\n\n不還原的話，之後仍可用 cx fresh --rollback --from <上面那個路徑>。" \
        || { cx_dim "  未還原。指引在 CX-RECOVERY.md"; return 0; }
    cx_restore "$A"
}
