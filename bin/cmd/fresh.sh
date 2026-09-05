#!/usr/bin/env bash
# cx fresh — 清理與重建。
#
# 強制順序（不可調換）：
#   preflight → backup → verify → [確認閘門] → migrate → delete → rebuild → git-init
#   驗證排在確認之前，這樣壞掉的封存會在樹還完整時就中止。
#   在確認閘門通過之前，不刪除任何東西。

# ── 保留：不動 ────────────────────────────────────────────────
FRESH_PRESERVE=(
    bin cx .cxroot templates docs claude.md
    .vscode reports ansible .env .env.example .gitignore
    docker sonar-project.properties
)
# ── 遷移：搬到 docker/ 之後才刪除原處（使用者要求保留 docker 自定義設定）──
FRESH_MIGRATE=( php nuxt docker-compose.yml .dockerignore )
# ── 刪除：確認後移除 ──────────────────────────────────────────
FRESH_DELETE=( .git .gitmodules backend frontend init.sh refresh.sh README.md )

_fresh_usage() {
    cat >&2 <<'TXT'
用法：cx fresh [--phase <phase>] [--mode <mode>] [--rollback [--from <dir>]]

  --phase preflight|backup|migrate|delete|all   （預設 all）
          preflight 完全不動任何東西，只做前置檢查
          delete    做到刪除為止，不重建

  --mode  backup-only | carryover | scaffold    （預設 carryover）
          backup-only  只封存，不刪也不建
          scaffold     全新骨架（Nuxt 4 + Laravel 13 + Filament v5 + Larastan）
          carryover    全新骨架，再把你自己的程式碼從封存疊回去
                       （骨架檔用新版的 —— 那正是重建的目的）

  --rollback [--from <archive-dir>]             從封存還原
          省略 --from 就用 <封存根>/LATEST。還原前會先驗證封存，
          被覆蓋的內容先移到 .cx-restore-backup/ 而不是直接刪。
          資料庫不在還原範圍 —— 用 cx db restore。

流程（順序不可調換）：
  preflight → 備份 → 驗證封存 → 確認閘門 → 遷移 → 刪除 → 重建 → 三 Git 初始化
  確認閘門之前不刪除任何東西；驗證排在確認之前，壞掉的封存會在樹還完整時中止。
TXT
}

# ---------------------------------------------------------------------------
# 安全刪除：多重護欄
# ---------------------------------------------------------------------------
_fresh_nuke() {
    local t=$1 real
    [[ -e $t || -L $t ]] || return 0
    # 拒絕 symlink（避免被指到樹外）
    [[ -L $t ]] && { cx_warn "跳過 symlink：$t"; return 0; }
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
    local arc need avail
    arc=$(cx_archive_root)
    need=$(du -sk --exclude=node_modules --exclude=vendor "$CX_ROOT" 2>/dev/null | cut -f1)
    avail=$(df -Pk "$arc" | tail -1 | awk '{print $4}')
    if (( avail > need * 3 )); then
        cx_ok "PF-06 空間充足（需 $((need/1024))MB × 3，可用 $((avail/1024/1024))GB）"
    else
        cx_error "PF-06 空間不足"; fail=1
    fi

    # 頂層項目分類
    local -a known=("${FRESH_PRESERVE[@]}" "${FRESH_MIGRATE[@]}" "${FRESH_DELETE[@]}" .cx .cx.lock)
    local -a unknown=()
    local e b
    while IFS= read -r -d '' e; do
        b=${e##*/}
        local hit=0 k
        for k in "${known[@]}"; do [[ $b == "$k" ]] && { hit=1; break; }; done
        (( hit )) || unknown+=("$b")
    done < <(find "$CX_ROOT" -mindepth 1 -maxdepth 1 -print0)
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
_fresh_migrate() {
    cx_step "遷移 Docker 自定義設定到 docker/"
    mkdir -p "$CX_ROOT/docker/php" "$CX_ROOT/docker/nuxt" "$CX_ROOT/docker/legacy"

    local f
    if [[ -d $CX_ROOT/php ]]; then
        for f in "$CX_ROOT"/php/*; do
            [[ -e $f ]] || continue
            cx_run cp -a "$f" "$CX_ROOT/docker/php/$(basename "$f")"
            cx_ok "php/$(basename "$f") → docker/php/"
        done
    fi
    if [[ -d $CX_ROOT/nuxt ]]; then
        for f in "$CX_ROOT"/nuxt/*; do
            [[ -e $f ]] || continue
            cx_run cp -a "$f" "$CX_ROOT/docker/nuxt/$(basename "$f")"
            cx_ok "nuxt/$(basename "$f") → docker/nuxt/"
        done
    fi
    # 舊 compose 留一份參考（Phase 2 會重寫根目錄那份）
    [[ -f $CX_ROOT/docker-compose.yml ]] && {
        cx_run cp -a "$CX_ROOT/docker-compose.yml" "$CX_ROOT/docker/legacy/docker-compose.yml.orig"
        cx_ok "docker-compose.yml → docker/legacy/（原始參考）"
    }
    [[ -f $CX_ROOT/.dockerignore ]] && {
        cx_run cp -a "$CX_ROOT/.dockerignore" "$CX_ROOT/docker/legacy/dockerignore.orig"
        cx_ok ".dockerignore → docker/legacy/"
    }
    # 舊腳本也留一份，方便對照
    for f in init.sh refresh.sh README.md; do
        [[ -f $CX_ROOT/$f ]] && cx_run cp -a "$CX_ROOT/$f" "$CX_ROOT/docker/legacy/$f.orig" && cx_ok "$f → docker/legacy/"
    done
    cx_ok "遷移完成 —— 所有自定義設定都有副本在 docker/ 底下"
}

# ---------------------------------------------------------------------------
# 確認閘門
# ---------------------------------------------------------------------------
_fresh_gate() {
    local A=$1
    local body msg_db

    msg_db=$(sed -n 's/^db_dump=//p' "$A/MANIFEST.txt" | head -1)
    case $msg_db in
        '<docker-unavailable>') msg_db='⚠ 未備份（Docker daemon 不可用）' ;;
        '<no-container>')       msg_db='⚠ 未備份（mysql 容器未執行）' ;;
        '<failed>')             msg_db='⚠ 備份失敗' ;;
        '')                     msg_db='⚠ 無記錄' ;;
        *)                      msg_db="✔ $msg_db" ;;
    esac

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

此操作不可逆。確定要繼續嗎？
TXT
)
    cx_confirm --danger "cx fresh — 刪除確認" "$body" || { cx_error "使用者取消，未變更任何檔案"; return 1; }
    cx_ask_typed "最終確認" \
        "請輸入下列字串以確認刪除：\n\n    DESTROY $(cx_project)\n" \
        "DESTROY $(cx_project)" || { cx_error "確認失敗，未變更任何檔案"; return 1; }
    return 0
}

# ---------------------------------------------------------------------------
# 刪除
# ---------------------------------------------------------------------------
_fresh_delete() {
    cx_step "刪除"
    local t
    for t in "${FRESH_DELETE[@]}" "${FRESH_MIGRATE[@]}"; do
        # docker-compose.yml 與 .dockerignore 已複製到 docker/legacy/，原處刪除
        _fresh_nuke "$CX_ROOT/$t"
    done

    # 斷言：.gitmodules 與 .git 必須真的消失，否則後續 git init 會出問題
    [[ ! -e $CX_ROOT/.gitmodules ]] || cx_die "$EX_FAIL" ".gitmodules 仍存在"
    [[ ! -e $CX_ROOT/.git ]]        || cx_die "$EX_FAIL" ".git 仍存在"
    [[ ! -e $CX_ROOT/backend ]]     || cx_die "$EX_FAIL" "backend/ 仍存在"
    [[ ! -e $CX_ROOT/frontend ]]    || cx_die "$EX_FAIL" "frontend/ 仍存在"
    cx_ok "斷言通過：.git / .gitmodules / backend / frontend 皆已移除"

    # 重建空目錄，且必須由「當前使用者」建立。
    # 否則 Docker 之後會以 root:root 0755 自動建立 bind mount 來源，
    # 容器內 uid 1000 寫不進去，非 root 的操作者也刪不掉。
    cx_run mkdir -p "$CX_ROOT/backend" "$CX_ROOT/frontend"
    [[ -O $CX_ROOT/backend && -O $CX_ROOT/frontend ]] \
        || cx_die "$EX_FAIL" "backend/ frontend/ 擁有者不是目前使用者"
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

_fresh_rebuild_frontend() {
    local dir="$CX_ROOT/frontend"
    cx_step "重建前端（Vue 3 + Nuxt 4）"
    [[ -e $dir ]] && { cx_error "$dir 已存在 —— 重建階段預期它已被刪除"; return 1; }

    local tool; tool=$(_fresh_tool node)
    case $tool in
        native)
            cx_info "用 host 的 npx 產生骨架"
            # --no-install：相依交給 cx setup deps，重建階段不下載 400MB。
            # --gitInit false：三個 repo 的初始化統一由 _fresh_git_init 做。
            cx_run npx --yes nuxi@latest init "$dir" \
                --packageManager npm --gitInit false --no-install --force </dev/null \
                || { cx_error "nuxi init 失敗"; return 1; }
            ;;
        docker)
            cx_info "用一次性的 node 映像產生骨架"
            cx_run docker run --rm -u "$(id -u):$(id -g)" \
                -v "$CX_ROOT:/w" -w /w \
                "${CX_IMG_NODE:-node:24.20-bookworm-slim}" \
                npx --yes nuxi@latest init frontend \
                --packageManager npm --gitInit false --no-install --force </dev/null \
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
    [[ -e $dir ]] && { cx_error "$dir 已存在 —— 重建階段預期它已被刪除"; return 1; }

    local tool; tool=$(_fresh_tool php)
    local -a run=()
    case $tool in
        native) run=(env -C "$CX_ROOT") ;;
        docker)
            # 用官方 composer 映像，不是本專案的 app 映像 —— 後者此刻還沒建。
            run=(docker run --rm -u "$(id -u):$(id -g)"
                 -v "$CX_ROOT:/w" -w /w
                 "${CX_IMG_COMPOSER:-composer:2}")
            ;;
        *)  cx_error "重建後端需要 composer + php 或 Docker，都不可用"
            cx_dim "  cx setup tools composer && cx setup system php   或   啟用 Docker"
            return 1 ;;
    esac

    local composer_bin=composer
    [[ $tool == docker ]] && composer_bin=composer

    cx_info "composer create-project laravel/laravel"
    cx_run "${run[@]}" "$composer_bin" create-project laravel/laravel backend \
        --no-interaction --prefer-dist </dev/null \
        || { cx_error "create-project 失敗"; return 1; }

    local -a runb=()
    case $tool in
        native) runb=(env -C "$dir") ;;
        docker) runb=(docker run --rm -u "$(id -u):$(id -g)"
                      -v "$CX_ROOT:/w" -w /w/backend
                      "${CX_IMG_COMPOSER:-composer:2}") ;;
    esac

    cx_info "composer require filament/filament:^5.0"
    cx_run "${runb[@]}" "$composer_bin" require filament/filament:^5.0 \
        --no-interaction --no-scripts </dev/null \
        || { cx_error "安裝 Filament 失敗"; return 1; }

    cx_info "composer require --dev larastan/larastan:^3.0"
    cx_run "${runb[@]}" "$composer_bin" require --dev larastan/larastan:^3.0 \
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
    # shellcheck disable=SC2064  # 要在設定 trap 的當下就把路徑固定住
    trap "rm -rf '$tmp'" RETURN

    local -A KEEP=(
        [backend]="app database/migrations database/seeders database/factories routes resources tests"
        [frontend]="app components pages layouts composables stores assets public server middleware plugins"
    )
    for c in backend frontend; do
        [[ -f $A/src-$c.tar.gz ]] || { cx_warn "$c 沒有封存的原始碼，略過"; continue; }
        cx_run tar -xzf "$A/src-$c.tar.gz" -C "$tmp" || return 1
        local d n=0
        for d in ${KEEP[$c]}; do
            [[ -d $tmp/$c/$d ]] || continue
            cx_run mkdir -p "$CX_ROOT/$c/$(dirname "$d")" || return 1
            # -T：把來源目錄的**內容**疊上去，而不是變成子目錄
            cx_run cp -a -T "$tmp/$c/$d" "$CX_ROOT/$c/$d" || return 1
            n=$((n + 1))
        done
        cx_ok "$c：疊回 $n 個目錄"
        cx_dim "  骨架檔（config/、bootstrap/、package.json、nuxt.config）刻意用新版的"
        cx_dim "  舊版留在封存裡：$A/src-$c.tar.gz"
    done
}

_fresh_rebuild() {                  # _fresh_rebuild <mode> <archive_dir>
    local mode=$1 A=$2
    _fresh_rebuild_backend  || return 1
    _fresh_rebuild_frontend || return 1
    [[ $mode == carryover ]] && { _fresh_carryover "$A" || return 1; }
    return 0
}

# ---------------------------------------------------------------------------
# 三個 Git 的初始化
# ---------------------------------------------------------------------------
# 順序不可調換：子模組要先是有效的 repo（且有至少一個 commit），
# 主庫才 submodule add 得起來 —— 對一個沒有 commit 的 repo 做 submodule add
# 會得到 "does not have a commit checked out"。
_fresh_git_init() {
    cx_step "初始化三個 Git repo"
    local c
    for c in backend frontend; do
        [[ -d $CX_ROOT/$c ]] || { cx_error "$c 不存在，無法初始化"; return 1; }
        if [[ -e $CX_ROOT/$c/.git ]]; then
            cx_ok "$c 已經是 git repo，略過"
            continue
        fi
        cx_run git -C "$CX_ROOT/$c" init -b main || return 1
        # .gitignore 從 templates/ 拿 —— 那是本專案維護的版本，
        # 比框架自帶的更貼近這裡的目錄佈局（vendor 的 volume、reports/ 等）。
        [[ -f $CX_ROOT/templates/gitignore/$c ]] \
            && cx_run cp "$CX_ROOT/templates/gitignore/$c" "$CX_ROOT/$c/.gitignore"
        cx_run git -C "$CX_ROOT/$c" add -A || return 1
        cx_run git -C "$CX_ROOT/$c" commit -q -m "初始化 $(cx_project)-$c" || return 1
        cx_ok "$c：$(git -C "$CX_ROOT/$c" rev-parse --short HEAD 2>/dev/null)"
    done

    if [[ ! -e $CX_ROOT/.git ]]; then
        cx_run git -C "$CX_ROOT" init -b main || return 1
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
        cx_run git -C "$CX_ROOT" -c protocol.file.allow=always \
            submodule add --force -b main "./$c" "$c" || return 1
        cx_run git -C "$CX_ROOT" config --file .gitmodules "submodule.$c.url" "$url" || return 1
        cx_ok "$c → $url"
    done

    cx_run git -C "$CX_ROOT" add -A || return 1
    if git -C "$CX_ROOT" diff --cached --quiet; then
        cx_ok "主庫沒有要提交的變更"
    else
        cx_run git -C "$CX_ROOT" commit -q -m "初始化 $(cx_project)：$(cx_project)-backend 與 $(cx_project)-frontend 子模組" \
            || return 1
        cx_ok "主庫：$(git -C "$CX_ROOT" rev-parse --short HEAD 2>/dev/null)"
    fi
    cx_dim "  遠端還沒建。要建： cx git remote-init（需要 gh 已登入）"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
cmd_fresh_main() {
    local phase=all mode=carryover rollback=0 from=''
    while (( $# )); do
        case $1 in
            --phase)    [[ -n ${2:-} ]] || cx_die "$EX_USAGE" "--phase 需要一個值"
                        phase=$2; shift 2 ;;
            --phase=*)  phase=${1#*=}; shift ;;
            --mode)     [[ -n ${2:-} ]] || cx_die "$EX_USAGE" "--mode 需要一個值"
                        mode=$2; shift 2 ;;
            --mode=*)   mode=${1#*=}; shift ;;
            --rollback) rollback=1; shift ;;
            --from)     [[ -n ${2:-} ]] || cx_die "$EX_USAGE" "--from 需要一個路徑"
                        from=$(cx_resolve "$2"); shift 2 ;;
            --from=*)   from=$(cx_resolve "${1#*=}"); shift ;;
            -h|--help)  _fresh_usage; return 0 ;;
            *)          cx_die "$EX_USAGE" "未知參數：$1" ;;
        esac
    done

    # 白名單驗證 —— 少了這段，任何打錯的 phase 都會 fall through 到
    # preflight → backup → migrate → gate → delete 的完整破壞流程。
    case $phase in
        preflight|backup|migrate|delete|all) : ;;
        *) cx_die "$EX_USAGE" "未知的 phase：$phase（preflight|backup|migrate|delete|all）" ;;
    esac
    case $mode in
        backup-only|carryover|scaffold) : ;;
        *) cx_die "$EX_USAGE" "未知的 mode：$mode（backup-only|carryover|scaffold）" ;;
    esac
    # archive.sh 要在這裡就載入，不能等到下面 —— 底下 --rollback 的錯誤訊息
    # 會呼叫 cx_archive_root()，那個函式定義在 archive.sh 裡。
    # 原本 source 寫在旗標處理之後，於是 `cx fresh --rollback` 會得到
    #   fresh.sh: line 270: cx_archive_root: command not found
    # 而不是它該給的「尚未實作，請看這個目錄」訊息。
    # shellcheck source=/dev/null
    . "$CX_ROOT/bin/lib/archive.sh"

    # ── --rollback：從封存還原 ───────────────────────────────────────────
    if (( rollback )); then
        local src=$from
        if [[ -z $src ]]; then
            local latest="$(cx_archive_root)/LATEST"
            [[ -f $latest ]] || cx_die "$EX_PRECOND" \
                "沒有 --from，也找不到 $latest —— 先跑過 cx fresh 才會有封存"
            src=$(<"$latest")
        fi
        cx_lock fresh
        cx_restore "$src"
        return $?
    fi
    [[ -n $from ]] && cx_warn "--from 只有 --rollback 會用到，本次忽略"

    cx_lock fresh

    case $phase in
        preflight) _fresh_preflight; return 0 ;;
        migrate)   _fresh_migrate; return 0 ;;
    esac

    _fresh_preflight

    local A
    A="$(cx_archive_root)/$(cx_stamp)"
    cx_info "封存目錄：$A"
    cx_backup "$A"
    cx_verify_archive "$A" || cx_die "$EX_FAIL" "封存驗證失敗 —— 未刪除任何東西"
    printf '%s\n' "$A" > "$(cx_archive_root)/LATEST"

    if [[ $mode == backup-only ]]; then
        cx_ok "backup-only 完成，未刪除任何東西"
        cx_info "封存：$A"
        return 0
    fi
    [[ $phase == backup ]] && { cx_ok "backup 階段完成"; cx_info "封存：$A"; return 0; }

    # 閘門必須在 _fresh_migrate **之前**。
    # 原本順序是 migrate → gate，而 migrate 會把 docker-compose.yml /
    # .dockerignore / README.md 複製成 docker/legacy/*.orig ——
    # 那是三個進版控的檔案。於是使用者在確認畫面按取消，畫面印
    # 「使用者取消，未變更任何檔案」，git status 卻多出三個 M。
    # 訊息說謊比動到檔案更糟：下次沒人會相信那句話。
    _fresh_gate "$A" || return "$EX_ABORT"
    # migrate 的 rc 一定要檢查。閘門移到它前面之後，這裡已經過了不可逆點 ——
    # 遷移失敗卻繼續 _fresh_delete，等於把 docker 自定義設定連同原處一起刪掉，
    # 而 docker/legacy/ 底下沒有可用的副本。
    _fresh_migrate || cx_die "$EX_FAIL" \
        "遷移失敗 —— 已中止，未刪除任何東西（封存在 $A）"
    _fresh_delete

    [[ $phase == delete ]] && { cx_ok "delete 階段完成"; cx_info "封存：$A"; return 0; }

    _fresh_rebuild "$mode" "$A" || cx_die "$EX_FAIL" \
        "重建失敗 —— 封存完好，可用 cx fresh --rollback --from $A 還原"
    _fresh_git_init || cx_die "$EX_FAIL" \
        "Git 初始化失敗 —— 前後端已重建，可手動 git init，或 cx fresh --rollback --from $A"

    cx_ok "清理與重建完成"
    cx_info "封存：$A"
    cx_dim "  後續： cx setup deps  →  cx dev up -d --build  →  cx doctor"
    cx_dim "  要回到重建前： cx fresh --rollback --from $A"
}
