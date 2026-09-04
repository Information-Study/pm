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
  --mode  backup-only | carryover | scaffold    （預設 carryover）
  --rollback [--from <archive-dir>]             從封存還原
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
        git -C "$CX_ROOT/$c" rev-parse --git-dir >/dev/null 2>&1 || continue
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
        git -C "$CX_ROOT/$c" rev-parse --git-dir >/dev/null 2>&1 || continue
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
        "請輸入下列字串以確認刪除：\n\n    DESTROY pm\n" \
        "DESTROY pm" || { cx_error "確認失敗，未變更任何檔案"; return 1; }
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

    # 已解析但尚未實作的旗標必須明講，不能讓使用者以為它有效
    (( rollback )) && cx_die "$EX_USAGE" \
        "--rollback 尚未實作（見 claude.md §12）。手動還原：$(cx_archive_root)/LATEST 下的 bundle 與 gitdir tar"
    [[ -n $from ]] && cx_warn "--from 目前只有 --rollback 會用到，本次忽略"
    [[ $mode == carryover || $mode == scaffold ]] && \
        cx_warn "--mode $mode 的重建階段尚未實作，本次只會做到刪除為止"

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

    _fresh_migrate
    _fresh_gate "$A" || return "$EX_ABORT"
    _fresh_delete

    cx_ok "清理完成。重建階段尚未實作（見 claude.md §12）"
}
