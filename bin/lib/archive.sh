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
        cx_run git -C "$CX_ROOT" bundle create "$A/git-main.bundle" --all HEAD 2>/dev/null
        cx_ok "git-main.bundle（$head_main）"
        # 主庫的 .git 整包（含 modules/，所以子模組物件庫其實在這裡面也有一份）
        cx_run tar -czf "$A/gitdir-main.tar.gz" -C "$CX_ROOT" .git
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
            -- "$c"
        cx_ok "src-$c.tar.gz"

        if git -C "$CX_ROOT/$c" rev-parse --git-dir >/dev/null 2>&1; then
            # bundle 的 refs 必須「每個子專案各自計算」——
            # 不能算一次就重複用，否則 backend 在分支、frontend 是 detached 時會漏掉 frontend 的 HEAD。
            local refs=(--all)
            cx_is_detached "$CX_ROOT/$c" && refs=(--all HEAD)
            cx_run git -C "$CX_ROOT/$c" bundle create "$A/git-$c.bundle" "${refs[@]}"
            cx_ok "git-$c.bundle（refs: ${refs[*]}）"

            # 真實 gitdir + 還原位置
            local gd rel
            gd=$(git -C "$CX_ROOT/$c" rev-parse --absolute-git-dir)
            rel=$(realpath --relative-to="$CX_ROOT" "$gd")
            cx_run tar -czf "$A/gitdir-$c.tar.gz" -C "$(dirname "$gd")" -- "$(basename "$gd")"
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
        local cid; cid=$(docker ps -q --filter "name=mysql" | head -1)
        if [[ -n $cid ]]; then
            local dbname="${CX_DB_DATABASE:-pwg}" rootpw="${MYSQL_ROOT_PASSWORD:-password}"
            if docker exec -i "$cid" mysqldump -uroot -p"$rootpw" \
                 --single-transaction --routines --triggers --databases "$dbname" \
                 2>/dev/null | gzip > "$A/db-$dbname.sql.gz"; then
                gzip -t "$A/db-$dbname.sql.gz" \
                    && { cx_ok "db-$dbname.sql.gz"; echo "db_dump=db-$dbname.sql.gz" >> "$m"; } \
                    || cx_die "mysqldump 產出損毀"
            else
                rm -f "$A/db-$dbname.sql.gz"
                cx_warn "mysqldump 失敗"
                echo "db_dump=<failed>" >> "$m"
            fi
        else
            cx_warn "找不到執行中的 mysql 容器 → 無資料庫備份"
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

    if [[ -f $A/SHA256SUMS ]]; then
        ( cd "$A" && sha256sum -c --quiet SHA256SUMS ) \
            && cx_ok "SHA256 全部相符" || { cx_error "SHA256 校驗失敗"; fail=1; }
    fi

    local b
    for b in "$A"/*.bundle; do
        [[ -e $b ]] || continue
        if git bundle verify "$b" >/dev/null 2>&1; then
            cx_ok "bundle 完整：$(basename "$b")"
        else
            cx_error "bundle 損毀：$(basename "$b")"; fail=1
        fi
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

    # 交叉檢查：bundle 裡真的含有 MANIFEST 記載的 HEAD
    local c head
    for c in main backend frontend; do
        head=$(sed -n "s/^${c}_head=//p" "$A/MANIFEST.txt" | head -1)
        [[ -n $head && $head != '<unborn>' && -f $A/git-$c.bundle ]] || continue
        if git bundle list-heads "$A/git-$c.bundle" 2>/dev/null | grep -q "^$head" \
           || [[ $(git bundle list-heads "$A/git-$c.bundle" 2>/dev/null | wc -l) -gt 0 ]]; then
            cx_ok "$c 的 HEAD $head 可由 bundle 到達"
        else
            cx_error "$c 的 HEAD $head 不在 bundle 中"; fail=1
        fi
    done

    return $fail
}
