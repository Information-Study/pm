#!/usr/bin/env bash
# cx 封存函式庫。
#
# ⚠ 為什麼不能只 tar backend/ 和 frontend/：
#   backend/.git 與 frontend/.git 是 32 bytes 的「指標檔」（gitdir: ../.git/modules/backend），
#   真正的物件庫在 <root>/.git/modules/<name>。
#   只 tar 子目錄 → 只封存到那個指標 → 107 個 commit 全部遺失。
#   所以每個子專案都要 (a) git bundle  (b) 單獨打包真實 gitdir  (c) 在 MANIFEST 記錄還原位置。
#   記錄位置是必要的：git submodule add 對「已是有效 repo」的目錄不會 absorb gitdir，
#   重建後 .git 可能是真目錄而非指標檔，還原路徑會與備份時不同。

# 封存根目錄。
#
# ⚠ 帶 --probe 時**不建立目錄**。preflight 會呼叫這個函式來算可用空間，
#   而 usage 明寫「preflight 完全不動任何東西」—— 原本的無條件 mkdir 讓那句話
#   不成立（純檢查的動詞不該留下痕跡）。
cx_archive_root() {
    local base="${CX_ARCHIVE_ROOT:-$(dirname "$CX_ROOT")/$(basename "$CX_ROOT")_archive}"
    if [[ ${1:-} == --probe ]]; then
        printf '%s' "$base"
        return 0
    fi
    mkdir -p "$base" || return 1
    ( cd "$base" && pwd -P )
}

# 時戳：不能用 date +%s 以外的花俏格式，要可排序且無空白
cx_stamp() { date -u +%Y%m%dT%H%M%SZ; }

cx_is_detached() { ! git -C "$1" symbolic-ref -q HEAD >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# cx_backup <archive_dir>
# 產出：
#   MANIFEST.txt          還原所需的全部中繼資料
#   src-<name>.tar.gz     原始碼（排除 node_modules/vendor/.nuxt/.output）
#   git-<name>.bundle     完整 git 歷史
#   gitdir-<name>.tar.gz  真實 gitdir（含 config/hooks/logs）
#   db-<name>.sql.gz      mysqldump（docker 可用時）
#   SHA256SUMS
# ---------------------------------------------------------------------------
cx_backup() {
    local A=$1
    # dry-run 之下完全不寫。原本 mkdir 與整份 MANIFEST 都不經過 cx_run，
    # 於是 `cx --dry-run fresh` 會真的建出封存目錄與 MANIFEST ——
    # dry-run 的契約是「什麼都不做」，例外一個都不能有。
    if (( CX_DRY_RUN )); then
        cx_step "封存（dry-run：不寫入任何檔案）"
        cx_dim "  [dry-run] 封存目錄：$A"
        cx_dim "  [dry-run] 會產生 MANIFEST.txt、git-*.bundle、gitdir-*.tar.gz、src-*.tar.gz、SHA256SUMS"
        return 0
    fi
    mkdir -p "$A" || { cx_error "無法建立封存目錄 $A"; return 1; }
    local m="$A/MANIFEST.txt"

    {
        echo "# cx backup manifest"
        echo "created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "cx_root=$CX_ROOT"
        echo "project=${CX_PROJECT_NAME:-pm}"
        echo "host=$(hostname)"
        echo "user=$(id -un)"
        echo "git_version=$(git --version | awk '{print $3}')"
    } > "$m"

    # ---- 主庫 ----
    cx_step "封存主庫"
    # ⚠ 三種狀態要分開，不能只問 -d。
    #   目錄  → 正常的 clone，物件庫（含 modules/）就在裡面
    #   檔案  → git worktree 或被 absorb 的子模組：真正的物件庫在 CX_ROOT **之外**
    #   不存在 → 已經被 fresh 過，或是 --resume-from 的中途狀態
    #
    # 中間那個是 2026-09-05 抓到的最嚴重缺陷：原本 -d 為假就走 else 只印一句
    # warn，於是 worktree 上不產生 bundle、不產生 gitdir tar、MANIFEST 也沒有
    # main_head=；而 cx_verify_archive 的 expect 清單是**從 MANIFEST 推導**的，
    # 少了那個鍵就什麼都不檢查 → 回報「封存驗證通過」。
    # 接著 _fresh_nuke 只刪掉那個指標檔（真歷史在 CX_ROOT 外，連越界防護都
    # 看不到它），cx_restore 也沒有東西可以還原。
    # 整條流程會「成功」，而使用者以為自己有一份可還原的封存。
    if [[ -f $CX_ROOT/.git ]]; then
        local _real_gd; _real_gd=$(git -C "$CX_ROOT" rev-parse --absolute-git-dir 2>/dev/null || echo '<unknown>')
        cx_die "$EX_PRECOND" "$(printf '%s\n' \
            "$CX_ROOT/.git 是檔案不是目錄 —— 這是 git worktree（或被 absorb 的子模組）。" \
            "" \
            "  真正的物件庫在：$_real_gd" \
            "  那個路徑在 CX_ROOT 之外，所以：" \
            "    * 封存抓不到主庫歷史（bundle 與 gitdir tar 都不會產生）" \
            "    * 刪除只會拿掉這個指標檔，歷史其實還在" \
            "    * cx fresh --rollback 沒有東西可以還原" \
            "" \
            "  請在主 checkout 上執行（git worktree list 看得到是哪一個）。")"
    fi
    if [[ -d $CX_ROOT/.git ]]; then
        echo "main_state=repo" >> "$m"
        local head_main; head_main=$(git -C "$CX_ROOT" rev-parse HEAD 2>/dev/null || echo '<unborn>')
        echo "main_head=$head_main" >> "$m"
        echo "main_commits=$(git -C "$CX_ROOT" rev-list --count HEAD 2>/dev/null || echo 0)" >> "$m"
        echo "main_branch=$(git -C "$CX_ROOT" branch --show-current 2>/dev/null || echo '<detached>')" >> "$m"
        git -C "$CX_ROOT" remote -v | sed 's/^/main_remote=/' >> "$m"
        # ⚠ 每一個產出都必須顯式檢查。
        #
        # cx 的 dispatcher 是 `"$fn" "$@" || _rc=$?`，而 bash 對「|| 清單裡的命令」
        # 會停用 errexit，**而且遞迴套用到整個函式呼叫樹**（實測 bash 5.3.9：
        # 子 shell、甚至在子 shell 裡重新 set -e 都救不回來，只有真正的子行程可以）。
        # 也就是說 cx:6 的 set -Eeuo pipefail 與 cx:84 的 ERR trap
        # 對這個檔裡的每一行都**沒有作用**。
        #
        # 原本這裡是 `cx_run git ... 2>/dev/null` 之後無條件 cx_ok：
        # bundle 失敗時 git 會走 lockfile rollback、一個殘檔都不留，
        # stderr 又被吞掉，於是畫面照樣印出「✔ git-main.bundle」。
        # 接著 cx_verify_archive 對「不存在的檔案」是跳過而不是失敗，
        # 確認閘門還會照 MANIFEST 顯示 commit 數讓操作者安心按下確認 ——
        # 然後 _fresh_delete 把 .git 刪掉。
        cx_run git -C "$CX_ROOT" bundle create "$A/git-main.bundle" --all HEAD             || cx_die "$EX_FAIL" "git bundle create 失敗（主庫）—— 封存不完整，已中止，不會刪除任何東西"
        [[ -s $A/git-main.bundle ]]             || cx_die "$EX_FAIL" "git-main.bundle 不存在或是空檔 —— 封存不完整，已中止"
        cx_ok "git-main.bundle（$head_main）"
        # 主庫的 .git 整包（含 modules/，所以子模組物件庫其實在這裡面也有一份）
        cx_run tar -czf "$A/gitdir-main.tar.gz" -C "$CX_ROOT" .git             || cx_die "$EX_FAIL" "tar gitdir-main 失敗 —— 封存不完整，已中止"
        [[ -s $A/gitdir-main.tar.gz ]]             || cx_die "$EX_FAIL" "gitdir-main.tar.gz 不存在或是空檔 —— 封存不完整，已中止"
        cx_ok "gitdir-main.tar.gz（含 .git/modules/）"
    else
        echo "main_state=absent" >> "$m"
        cx_warn "主庫沒有 .git，略過"
    fi

    # ---- 子專案 ----
    local c
    for c in backend frontend; do
        [[ -d $CX_ROOT/$c ]] || { cx_warn "$c 不存在，略過"; continue; }
        # ⚠ symlink 會產出「驗證全綠但沒有原始碼」的封存。
        #   `[[ -d ]]` 會跟隨 symlink 回報成功，但下面的 `tar -C "$CX_ROOT" -- "$c"`
        #   打包的是 symlink 本身（GNU tar 不加 -h 不跟隨），而
        #   `[[ -s src-$c.tar.gz ]]` 對一個只含 symlink 的 tar 照樣通過。
        #   於是 cx_verify_archive 全綠、確認閘門顯示 commit 數、使用者按下確認，
        #   然後 _fresh_delete 把樹刪掉 —— 而封存裡沒有任何程式碼。
        #   還原路徑也不對：cx_restore 會在原本是 symlink 的位置解出一個真目錄。
        #   這種佈局要先自己處理掉，封存不該猜。
        if [[ -L $CX_ROOT/$c ]]; then
            cx_die "$EX_FAIL" \
                "$c 是 symlink（指向 $(readlink "$CX_ROOT/$c")）—— 封存無法正確處理，已中止。
    tar 不會跟隨它，產出的封存會通過驗證但不含任何原始碼。
    請先把它換成真目錄（或把子專案移進來）再跑 cx fresh。"
        fi
        cx_step "封存 $c"

        # 原始碼
        cx_run tar -czf "$A/src-$c.tar.gz" -C "$CX_ROOT" \
            --exclude="$c/node_modules" --exclude="$c/vendor" \
            --exclude="$c/.nuxt" --exclude="$c/.output" \
            --exclude="$c/storage/logs" --exclude="$c/storage/framework/cache" \
            -- "$c"             || cx_die "$EX_FAIL" "tar src-$c 失敗 —— 封存不完整，已中止"
        [[ -s $A/src-$c.tar.gz ]]             || cx_die "$EX_FAIL" "src-$c.tar.gz 不存在或是空檔 —— 封存不完整，已中止"
        cx_ok "src-$c.tar.gz"

        if cx_is_repo_root "$CX_ROOT/$c"; then
            # bundle 的 refs 必須「每個子專案各自計算」——
            # 不能算一次就重複用，否則 backend 在分支、frontend 是 detached 時會漏掉 frontend 的 HEAD。
            local refs=(--all)
            cx_is_detached "$CX_ROOT/$c" && refs=(--all HEAD)
            cx_run git -C "$CX_ROOT/$c" bundle create "$A/git-$c.bundle" "${refs[@]}"                 || cx_die "$EX_FAIL" "git bundle create 失敗（$c）—— 封存不完整，已中止"
            [[ -s $A/git-$c.bundle ]]                 || cx_die "$EX_FAIL" "git-$c.bundle 不存在或是空檔 —— 封存不完整，已中止"
            cx_ok "git-$c.bundle（refs: ${refs[*]}）"

            # 真實 gitdir + 還原位置
            local gd rel
            gd=$(git -C "$CX_ROOT/$c" rev-parse --absolute-git-dir)
            rel=$(realpath --relative-to="$CX_ROOT" "$gd")
            cx_run tar -czf "$A/gitdir-$c.tar.gz" -C "$(dirname "$gd")" -- "$(basename "$gd")"                 || cx_die "$EX_FAIL" "tar gitdir-$c 失敗 —— 封存不完整，已中止"
            [[ -s $A/gitdir-$c.tar.gz ]]                 || cx_die "$EX_FAIL" "gitdir-$c.tar.gz 不存在或是空檔 —— 封存不完整，已中止"
            cx_ok "gitdir-$c.tar.gz（真實位置：$rel）"

            {
                echo "${c}_head=$(git -C "$CX_ROOT/$c" rev-parse HEAD)"
                echo "${c}_commits=$(git -C "$CX_ROOT/$c" rev-list --count HEAD)"
                echo "${c}_detached=$(cx_is_detached "$CX_ROOT/$c" && echo yes || echo no)"
                echo "${c}_gitdir=$rel"
                git -C "$CX_ROOT/$c" remote -v | sed "s/^/${c}_remote=/"
            } >> "$m"
        else
            cx_warn "$c 不是 git repo"
            echo "${c}_gitdir=<none>" >> "$m"
        fi
    done

    # ---- 資料庫 ----
    cx_step "封存資料庫"
    if cx_docker_ok; then
        # 容器要**限定在本專案**。原本是 --filter name=mysql，
        # 三個模式（dev/test/prod）同時在跑的時候會隨機挑一個，
        # 而且同一台機器上的別的專案也會被挑中 —— 備份到別人的資料庫，
        # 或是備份到 test 的空庫然後把 dev 刪掉。
        local cid=''
        local mo
        for mo in "${CX_MODE:-dev}" dev prod test; do
            cid=$(docker ps -q \
                    --filter "label=com.docker.compose.project=$(cx_project_for "$mo")" \
                    --filter "label=com.docker.compose.service=mysql" | head -1)
            [[ -n $cid ]] && break
        done
        if [[ -n $cid ]]; then
            # 名稱與密碼都問容器自己，不要寫死。
            # 原本是 ${CX_DB_DATABASE:-pwg} 與 ${MYSQL_ROOT_PASSWORD:-password} ——
            # pwg 是別的專案留下來的名字，password 也不是這裡的密碼，
            # 兩個 fallback 都會生效（外層 shell 沒有這兩個變數），
            # 於是 mysqldump 必定失敗，然後只印一行「mysqldump 失敗」就繼續刪。
            # 封存是刪除前的唯一安全網，它不該靠猜。
            local dbname
            dbname=$(docker exec "$cid" printenv MYSQL_DATABASE 2>/dev/null) \
                || dbname=''
            [[ -n $dbname ]] || dbname=$(cx_project)
            # dbname 來自 `docker exec printenv`，是**容器可控**的值。
            # 直接內插進下面的 sh -c 會讓含單引號的資料庫名注入 shell，
            # 而且它還會流進 MANIFEST 的 db_dump= 與 cx_verify_archive 的 grep。
            # 先驗形狀，再用位置參數傳，不做字串內插。
            case $dbname in
                *[!A-Za-z0-9_-]*|'')
                    cx_die "$EX_FAIL" "資料庫名含非預期字元，拒絕封存：$(cx_q "$dbname")" ;;
            esac
            # 密碼用容器內的環境變數展開，不進 host 的行程列表
            #（/proc/<pid>/cmdline 全機器可讀）。
            local err="$A/.mysqldump.err"
            if docker exec -i "$cid" sh -c \
                 'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" \
                      --single-transaction --routines --triggers \
                      --databases "$1"' _ "$dbname" \
                 2>"$err" | gzip > "$A/db-$dbname.sql.gz"; then
                gzip -t "$A/db-$dbname.sql.gz" \
                    && { cx_ok "db-$dbname.sql.gz"; echo "db_dump=db-$dbname.sql.gz" >> "$m"; rm -f "$err"; } \
                    || cx_die "$EX_FAIL" "mysqldump 產出損毀"
            else
                rm -f "$A/db-$dbname.sql.gz"
                # 原本 2>/dev/null 把原因整個丟掉，使用者只看到「失敗」
                # 卻不知道是密碼錯、資料庫不存在還是容器不是 mysql。
                cx_error "mysqldump 失敗（資料庫 $dbname）—— 這次封存沒有資料庫備份"
                [[ -s $err ]] && cx_dim "  $(head -3 "$err" | tr '\n' ' ')"
                echo "db_dump=<failed>" >> "$m"
            fi
        else
            cx_warn "找不到本專案執行中的 mysql 容器 → 無資料庫備份"
            echo "db_dump=<no-container>" >> "$m"
        fi
    else
        cx_warn "Docker daemon 不可用 → 無法備份資料庫"
        echo "db_dump=<docker-unavailable>" >> "$m"
    fi

    # ---- 校驗碼 ----
    ( cd "$A" && sha256sum ./*.tar.gz ./*.bundle ./*.sql.gz 2>/dev/null > SHA256SUMS || true )
    cx_ok "SHA256SUMS"
}

# ---------------------------------------------------------------------------
# cx_verify_archive <archive_dir>
# 必須在「確認閘門之前」呼叫 —— 壞掉的封存要在樹還完整時就中止。
# ---------------------------------------------------------------------------
cx_verify_archive() {
    local A=$1 fail=0
    # dry-run 之下 cx_backup 什麼都沒寫，這裡當然驗不到東西 ——
    # 而「驗證失敗」會讓整個 dry-run 中止，於是最需要 dry-run 的動詞
    # 永遠跑不完。dry-run 的契約是「照著流程走一遍但不動任何東西」。
    if (( CX_DRY_RUN )); then
        cx_step "驗證封存（dry-run：略過，因為沒有真的封存）"
        return 0
    fi
    cx_step "驗證封存（在刪除任何東西之前）"

    [[ -f $A/MANIFEST.txt ]] || { cx_error "缺少 MANIFEST.txt"; return 1; }

    # ── 先算出「MANIFEST 說應該要有哪些產物」──────────────────────────────
    #
    # ⚠ 這一段是整個 cx fresh 流程最重要的一道防線，而它原本是壞的。
    #
    # 舊版的每個迴圈都是 `for b in "$A"/*.bundle; do [[ -e $b ]] || continue`，
    # 也就是「檔案不存在」被當成「沒事可驗」而不是「封存不完整」。
    # 交叉檢查那一段更是 `-f $A/git-$c.bundle || continue`，同樣跳過。
    # SHA256SUMS 也救不了：它是事後對「當時存在的檔案」生成的，
    # 缺檔根本不在清單裡，sha256sum -c 當然全綠。
    #
    # 結果是：MANIFEST 白紙黑字寫著 main_commits=113，封存目錄裡一個 bundle
    # 都沒有，這個函式仍然回 0 → 確認閘門照 MANIFEST 顯示 commit 數
    # → 操作者安心按下確認 → _fresh_delete 把 .git 刪掉。
    #
    # 現在改成「由 MANIFEST 推導出必須存在的清單，逐一斷言」。
    local -a expect=()
    local head_main main_state
    head_main=$(sed -n 's/^main_head=//p' "$A/MANIFEST.txt" | head -1)
    main_state=$(sed -n 's/^main_state=//p' "$A/MANIFEST.txt" | head -1)
    # ⚠ 「MANIFEST 沒提到主庫」**不可以**當成「主庫不用檢查」。
    # 那正是 worktree 缺陷得以通過驗證的原因：少一個鍵 → expect 少兩個項目 →
    # 迴圈什麼都沒驗 → 回報通過。所以主庫的狀態必須是**明寫**的，
    # 而且無法辨識時要失敗，不是放行。
    [[ -z $main_state && -n $head_main ]] && main_state=repo   # 舊封存沒有這個鍵
    case $main_state in
        repo)   expect+=(git-main.bundle gitdir-main.tar.gz) ;;
        absent) cx_warn "MANIFEST 記載封存當時主庫沒有 .git —— 這份封存不含主庫歷史" ;;
        '')     cx_error "MANIFEST 既沒有 main_state 也沒有 main_head —— 無法判斷主庫有沒有被封存"
                cx_dim "  這種封存不可以拿來還原：它可能是在 worktree 上產生的（見 cx_backup 的說明）"
                fail=1 ;;
        *)      cx_error "MANIFEST 的 main_state 無法辨識：$main_state"; fail=1 ;;
    esac

    local c head gitdir
    for c in backend frontend; do
        head=$(sed -n "s/^${c}_head=//p" "$A/MANIFEST.txt" | head -1)
        gitdir=$(sed -n "s/^${c}_gitdir=//p" "$A/MANIFEST.txt" | head -1)
        # src tar 只要 MANIFEST 提過這個子專案就該有
        [[ -n $head || -n $gitdir ]] && expect+=("src-$c.tar.gz")
        # bundle 與 gitdir tar 只有「它真的是 git repo」時才會產生
        if [[ -n $head && $head != '<unborn>' && $gitdir != '<none>' ]]; then
            expect+=("git-$c.bundle" "gitdir-$c.tar.gz")
        fi
    done

    local db
    db=$(sed -n 's/^db_dump=//p' "$A/MANIFEST.txt" | head -1)
    case $db in
        ''|'<failed>'|'<no-container>'|'<docker-unavailable>') : ;;
        *) expect+=("$db") ;;
    esac

    local e
    for e in "${expect[@]}"; do
        if [[ -s $A/$e ]]; then
            cx_ok "存在：$e"
        else
            cx_error "MANIFEST 說應該有 $e，但它不存在或是空檔"
            fail=1
        fi
    done
    (( ${#expect[@]} )) || { cx_error "MANIFEST 沒有記載任何產物 —— 備份等於沒做"; fail=1; }

    # ── 校驗碼 ────────────────────────────────────────────────────────────
    if [[ -f $A/SHA256SUMS ]]; then
        ( cd "$A" && sha256sum -c --quiet SHA256SUMS ) \
            && cx_ok "SHA256 全部相符" || { cx_error "SHA256 校驗失敗"; fail=1; }
        # SHA256SUMS 必須涵蓋每一個預期產物 —— 少一行就代表它是事後才生成的、
        # 對缺檔完全無感，那正是舊版的漏洞。
        for e in "${expect[@]}"; do
            grep -q "  \./$e\$\|  $e\$" "$A/SHA256SUMS" \
                || { cx_error "SHA256SUMS 沒有涵蓋 $e"; fail=1; }
        done
    else
        cx_error "缺少 SHA256SUMS"
        fail=1
    fi

    # ⚠ `git bundle verify` 只讀 header。
    #
    # 實測（2026-09-04）：把一個 bundle 截斷成 200 bytes，
    # `git bundle verify` 仍然回 0 並印出「is okay」與完整的 ref 清單 ——
    # 因為 ref 清單就在 header 裡，後面的 packfile 它根本沒碰。
    # 拿它當「備份完好」的證據，等於沒有驗。
    #
    # 唯一可靠的做法是真的把物件解出來：往一個暫時的 bare repo fetch。
    # 實測可以擋下「截斷」與「中間位元翻轉」兩種毀損。
    # 成本是一次 unpack，但這是刪除 git 歷史之前的最後一道關卡，值得。
    local b bt
    for b in "$A"/*.bundle; do
        [[ -e $b ]] || continue
        bt=$(mktemp -d) || { cx_error "無法建立暫存目錄"; fail=1; continue; }
        git init -q --bare "$bt" 2>/dev/null
        if git -C "$bt" fetch -q "$b" '+refs/heads/*:refs/heads/*' >/dev/null 2>&1; then
            cx_ok "bundle 可解出：$(basename "$b")"
        else
            cx_error "bundle 損毀（解不出物件）：$(basename "$b")"; fail=1
        fi
        rm -rf "$bt"
    done

    local t
    for t in "$A"/*.tar.gz; do
        [[ -e $t ]] || continue
        if tar -tzf "$t" >/dev/null 2>&1; then
            cx_ok "tar 可讀：$(basename "$t")（$(tar -tzf "$t" | wc -l) 個項目）"
        else
            cx_error "tar 損毀：$(basename "$t")"; fail=1
        fi
    done

    # ── 交叉檢查：bundle 裡真的含有 MANIFEST 記載的 HEAD ──────────────────
    # 舊版這裡有一條
    #   || [[ $(git bundle list-heads … | wc -l) -gt 0 ]]
    # 的退路，使這個斷言對「任何非空 bundle」恆真 —— 等於沒有檢查。已移除。
    for c in main backend frontend; do
        head=$(sed -n "s/^${c}_head=//p" "$A/MANIFEST.txt" | head -1)
        [[ -n $head && $head != '<unborn>' ]] || continue
        if [[ ! -f $A/git-$c.bundle ]]; then
            cx_error "$c 有 HEAD 紀錄（$head）卻沒有 bundle"; fail=1; continue
        fi
        # 只比對 bundle 自己列出的 ref 尖端。
        # 不要退回去查「本地 repo 有沒有這個 commit」—— 本地當然有，
        # 那會讓這個斷言恆真，等於沒有檢查
        #（舊版的 `|| [[ $(… list-heads | wc -l) -gt 0 ]]` 是同一種錯誤）。
        # cx_backup 建 bundle 時一律帶 --all（detached 時再加 HEAD），
        # 所以 HEAD 必定會出現在 list-heads 裡。
        if git bundle list-heads "$A/git-$c.bundle" 2>/dev/null | awk '{print $1}' | grep -qx "$head"; then
            cx_ok "$c 的 HEAD ${head:0:12} 可由 bundle 到達"
        else
            cx_error "$c 的 HEAD $head 不在 bundle 中"; fail=1
        fi
    done

    (( fail )) && cx_error "封存驗證失敗 —— 不會進入確認閘門，也不會刪除任何東西"
    return $fail
}

# ---------------------------------------------------------------------------
# cx_restore <archive_dir>
#
# 封存的另一半。在 2026-09-05 之前這個函式不存在 —— cx_backup 與
# cx_verify_archive 都寫得很仔細，但「有備份，卻從來沒有還原過」本身就是
# 一個已知的失敗模式，而且是最貴的那一種：你會在最需要它的那一刻才發現。
#
# 還原順序與 cx_backup 的封存順序相反，而且每一步都要能單獨失敗而不留半套：
#   1. 驗證封存（沿用 cx_verify_archive —— 壞掉的封存不可以拿來覆蓋好的樹）
#   2. 列出將被覆蓋的路徑，過確認閘門
#   3. 主庫 .git ← gitdir-main.tar.gz
#   4. 前後端原始碼 ← src-<name>.tar.gz
#   5. 前後端的真實 gitdir ← gitdir-<name>.tar.gz，放回 MANIFEST 記錄的位置
#   6. 對帳：commit 數與 HEAD 要跟 MANIFEST 一致
#
# ⚠ 不碰資料庫。db-*.sql.gz 要另外用 cx db restore 匯入 —— 把「檔案還原」與
#   「資料庫還原」綁在一起的話，任何一邊失敗都會讓另一邊處於不確定狀態，
#   而且資料庫還原是不可逆的。
cx_restore() {
    local A=$1 fail=0
    [[ -d $A ]] || { cx_error "封存目錄不存在：$A"; return "$EX_PRECOND"; }

    cx_step "還原封存"
    cx_info "來源：$A"

    # ── 1. 先驗證 ────────────────────────────────────────────────────────
    cx_verify_archive "$A" || {
        cx_error "封存驗證失敗 —— 拒絕用一份壞掉的封存覆蓋現有的樹"
        return "$EX_PRECOND"
    }

    local m="$A/MANIFEST.txt"

    # ── 2. 列出會被覆蓋的東西，過閘門 ────────────────────────────────────
    local -a targets=() existing=()
    [[ -f $A/gitdir-main.tar.gz ]] && targets+=(".git")
    local c
    for c in backend frontend; do
        [[ -f $A/src-$c.tar.gz ]] && targets+=("$c")
    done
    local t
    for t in "${targets[@]}"; do
        [[ -e $CX_ROOT/$t ]] && existing+=("$t")
    done

    cx_step "將要還原的內容"
    local head_main commits_main
    head_main=$(sed -n 's/^main_head=//p' "$m" | head -1)
    commits_main=$(sed -n 's/^main_commits=//p' "$m" | head -1)
    [[ -n $head_main ]] && cx_info "主庫  HEAD ${head_main:0:12}・${commits_main:-?} 個 commit"
    for c in backend frontend; do
        local h n
        h=$(sed -n "s/^${c}_head=//p" "$m" | head -1)
        n=$(sed -n "s/^${c}_commits=//p" "$m" | head -1)
        [[ -n $h ]] && cx_info "$(printf '%-9s' "$c")HEAD ${h:0:12}・${n:-?} 個 commit"
    done

    if (( ${#existing[@]} )); then
        cx_warn "下列路徑已經存在，還原會**覆蓋**它們：${existing[*]}"
    fi
    cx_confirm "還原封存" \
        "會把 ${targets[*]} 還原到 $CX_ROOT。\n\n已存在的會被覆蓋（先移到 .cx-restore-backup/）。\n\n資料庫不在還原範圍內。" \
        || { cx_warn "已取消，什麼都沒有動"; return "$EX_ABORT"; }

    # 被覆蓋的東西先搬走而不是直接刪 —— 還原到一半失敗的時候，
    # 使用者至少還拿得回原本的狀態。
    # cx_stamp 只到秒。連續兩次還原（冪等性測試正是這樣做的）會撞到同一個
    # 目錄名，而 `mv .git "$bak/"` 在目標已有非空 .git 時會失敗：
    #     mv: cannot overwrite '…/.cx-restore-backup/<stamp>/.git': Directory not empty
    # 加上 PID 讓它在同一秒內也唯一。2026-09-05 由 cx test cli 抓到。
    local bak="$CX_ROOT/.cx-restore-backup/$(cx_stamp).$$"
    if (( ${#existing[@]} )); then
        cx_run mkdir -p "$bak" || return "$EX_FAIL"
        for t in "${existing[@]}"; do
            cx_run mv "$CX_ROOT/$t" "$bak/" || return "$EX_FAIL"
        done
        cx_ok "既有內容已移到 ${bak#"$CX_ROOT"/}"
    fi

    # ── 3. 主庫 gitdir ───────────────────────────────────────────────────
    if [[ -f $A/gitdir-main.tar.gz ]]; then
        cx_run tar -xzf "$A/gitdir-main.tar.gz" -C "$CX_ROOT" \
            || { cx_error "還原 .git 失敗"; fail=1; }
        [[ -d $CX_ROOT/.git ]] && cx_ok ".git（含 .git/modules/）"
    fi

    # ── 4. 原始碼 ────────────────────────────────────────────────────────
    for c in backend frontend; do
        [[ -f $A/src-$c.tar.gz ]] || continue
        cx_run tar -xzf "$A/src-$c.tar.gz" -C "$CX_ROOT" \
            || { cx_error "還原 $c 原始碼失敗"; fail=1; continue; }
        cx_ok "$c/（原始碼；node_modules 與 vendor 不在封存內）"
    done

    # ── 5. 子模組的真實 gitdir ───────────────────────────────────────────
    # 這一步是子模組專屬的坑：backend/.git 是一個 32 bytes 的指標檔
    #（gitdir: ../.git/modules/backend），真正的 gitdir 在別的地方。
    # 只還原 src tar 的話，backend/ 會是一棵沒有 git 的普通目錄。
    for c in backend frontend; do
        [[ -f $A/gitdir-$c.tar.gz ]] || continue
        local rel dest
        rel=$(sed -n "s/^${c}_gitdir=//p" "$m" | head -1)
        [[ -n $rel && $rel != '<none>' ]] || continue
        dest="$CX_ROOT/$(dirname "$rel")"
        cx_run mkdir -p "$dest" || { fail=1; continue; }
        # gitdir 已經由主庫的 .git tar 帶回來時就不用再解一次
        if [[ -e $CX_ROOT/$rel ]]; then
            cx_ok "$c 的 gitdir 已隨主庫 .git 還原（$rel）"
        else
            cx_run tar -xzf "$A/gitdir-$c.tar.gz" -C "$dest" \
                || { cx_error "還原 $c 的 gitdir 失敗"; fail=1; continue; }
            cx_ok "$c 的 gitdir → $rel"
        fi
    done

    (( fail )) && { cx_error "還原過程有錯誤 —— 原本的內容在 ${bak#"$CX_ROOT"/}"; return "$EX_FAIL"; }

    # ── 6. 對帳 ──────────────────────────────────────────────────────────
    cx_step "對帳（還原結果 vs MANIFEST）"
    local rc=0
    _cx_restore_check() {          # <label> <repo path> <manifest prefix>
        local label=$1 repo=$2 pfx=$3 want_head want_n got_head got_n
        want_head=$(sed -n "s/^${pfx}_head=//p" "$m" | head -1)
        [[ -n $want_head && $want_head != '<unborn>' ]] || return 0
        if ! cx_is_repo_root "$repo"; then
            cx_error "$label 還原後不是 git repo 的根"; return 1
        fi
        got_head=$(git -C "$repo" rev-parse HEAD 2>/dev/null)
        want_n=$(sed -n "s/^${pfx}_commits=//p" "$m" | head -1)
        got_n=$(git -C "$repo" rev-list --count HEAD 2>/dev/null)
        if [[ $got_head == "$want_head" && $got_n == "$want_n" ]]; then
            cx_ok "$label HEAD ${got_head:0:12}・$got_n 個 commit（與 MANIFEST 一致）"
            return 0
        fi
        cx_error "$label 對不上：MANIFEST ${want_head:0:12}/$want_n，實際 ${got_head:0:12}/$got_n"
        return 1
    }
    _cx_restore_check "主庫" "$CX_ROOT" main || rc=1
    for c in backend frontend; do
        [[ -d $CX_ROOT/$c ]] || continue
        _cx_restore_check "$c" "$CX_ROOT/$c" "$c" || rc=1
    done
    unset -f _cx_restore_check

    if (( rc )); then
        cx_error "還原完成但對帳不一致 —— 請檢查上面的差異"
        return "$EX_FAIL"
    fi
    cx_ok "還原完成並對帳通過"
    (( ${#existing[@]} )) && cx_dim "  被覆蓋的舊內容留在 ${bak#"$CX_ROOT"/}，確認沒問題後可以自行刪除"
    cx_dim "  資料庫不在還原範圍：要的話用 cx db restore $A/db-*.sql.gz"
    return 0
}
