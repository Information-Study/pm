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

cx_archive_root() {
    local base="${CX_ARCHIVE_ROOT:-$(dirname "$CX_ROOT")/$(basename "$CX_ROOT")_archive}"
    mkdir -p "$base"
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
    mkdir -p "$A"
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
    if [[ -d $CX_ROOT/.git ]]; then
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
        cx_warn "主庫沒有 .git，略過"
    fi

    # ---- 子專案 ----
    local c
    for c in backend frontend; do
        [[ -d $CX_ROOT/$c ]] || { cx_warn "$c 不存在，略過"; continue; }
        cx_step "封存 $c"

        # 原始碼
        cx_run tar -czf "$A/src-$c.tar.gz" -C "$CX_ROOT" \
            --exclude="$c/node_modules" --exclude="$c/vendor" \
            --exclude="$c/.nuxt" --exclude="$c/.output" \
            --exclude="$c/storage/logs" --exclude="$c/storage/framework/cache" \
            -- "$c"             || cx_die "$EX_FAIL" "tar src-$c 失敗 —— 封存不完整，已中止"
        [[ -s $A/src-$c.tar.gz ]]             || cx_die "$EX_FAIL" "src-$c.tar.gz 不存在或是空檔 —— 封存不完整，已中止"
        cx_ok "src-$c.tar.gz"

        if git -C "$CX_ROOT/$c" rev-parse --git-dir >/dev/null 2>&1; then
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
            # 密碼用容器內的環境變數展開，不進 host 的行程列表
            #（/proc/<pid>/cmdline 全機器可讀）。
            local err="$A/.mysqldump.err"
            if docker exec -i "$cid" sh -c \
                 "exec mysqldump -uroot -p\"\$MYSQL_ROOT_PASSWORD\" \
                      --single-transaction --routines --triggers \
                      --databases '$dbname'" \
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
    local head_main
    head_main=$(sed -n 's/^main_head=//p' "$A/MANIFEST.txt" | head -1)
    if [[ -n $head_main ]]; then
        expect+=(git-main.bundle gitdir-main.tar.gz)
    fi

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
