#!/usr/bin/env bash
# cx git — Git 操作，含 push guard 與 GitHub 遠端管理。

_git_usage() {
    cat >&2 <<'TXT'
用法：cx git <子指令>

  status                各 repo 的分支 / 變更 / 領先落後
  sync                  子模組 checkout 追蹤分支（解決 clone 後 detached HEAD）
  save [-m <訊息>]      子模組 commit + 主庫 gitlink commit（一次做完）
  guard install|status|remove
  remote-init [--dry-run]   用 gh 建立 Information-Study 的三個 public repo
  scan-secrets          祕密掃描（推送前自動執行）
  push                  推送（白名單 + 祕密掃描 + 子模組先於主庫）
TXT
}

_git_repos_order() { printf '%s\n' "$CX_ROOT/backend" "$CX_ROOT/frontend" "$CX_ROOT"; }

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
        sync)          _git_sync ;;
        save)          _git_save "$@" ;;
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
        printf '\n%s%s%s\n' "$C_BLU" "$(basename "$r")" "$C_RST"
        printf '  branch : %s\n' "$(git -C "$r" branch --show-current 2>/dev/null || echo '<detached>')"
        printf '  head   : %s\n' "$(git -C "$r" rev-parse --short HEAD 2>/dev/null || echo '<unborn>')"
        printf '  dirty  : %s 項\n' "$(git -C "$r" status --porcelain | wc -l)"
        printf '  origin : %s\n' "$(git -C "$r" remote get-url origin 2>/dev/null || echo '(未設定)')"
    done < <(_git_repos_order)
}

_git_sync() {
    cx_step "同步子模組到追蹤分支"
    local c b
    for c in backend frontend; do
        b=$(git config -f "$CX_ROOT/.gitmodules" --get "submodule.$c.branch" || echo main)
        if git -C "$CX_ROOT/$c" symbolic-ref -q HEAD >/dev/null 2>&1; then
            cx_ok "$c 已在分支 $(git -C "$CX_ROOT/$c" branch --show-current)"
        else
            cx_run git -C "$CX_ROOT/$c" checkout -q "$b"
            cx_ok "$c → $b（原本是 detached HEAD）"
        fi
    done
}

_git_save() {
    local msg=''
    while (( $# )); do case $1 in -m) msg=${2:?}; shift 2 ;; *) shift ;; esac; done
    [[ -n $msg ]] || cx_die "$EX_USAGE" "需要 -m <訊息>"
    local c changed=0
    for c in backend frontend; do
        if [[ -n $(git -C "$CX_ROOT/$c" status --porcelain) ]]; then
            cx_run git -C "$CX_ROOT/$c" add -A
            cx_run git -C "$CX_ROOT/$c" commit -q -m "$msg"
            cx_ok "$c 已提交"; changed=1
        else
            cx_dim "$c 無變更"
        fi
    done
    if [[ -n $(git -C "$CX_ROOT" status --porcelain) ]]; then
        cx_run git -C "$CX_ROOT" add -A
        cx_run git -C "$CX_ROOT" commit -q -m "$msg"
        cx_ok "主庫已提交（含 gitlink 更新）"
    elif (( changed )); then
        cx_warn "子模組有變更但主庫 gitlink 未動，請檢查"
    else
        cx_dim "主庫無變更"
    fi
}

# ---------------------------------------------------------------------------
# 祕密掃描：三個 repo 都是 public，這是最後一道防線
# ---------------------------------------------------------------------------
_git_scan_secrets() {
    cx_step "祕密掃描（三個 repo 皆為 PUBLIC）"
    local r slug bad=0 files hits

    while read -r r; do
        slug=$(_git_repo_slug "$r")
        files=$(git -C "$r" ls-files)
        [[ -n $files ]] || continue

        # 1) 檔名層級
        hits=$(printf '%s\n' "$files" | grep -iE '(^|/)\.env$|\.key$|\.pem$|\.p12$|\.pfx$|(^|/)auth\.json$|(^|/)id_rsa|\.sqlite$' || true)
        if [[ -n $hits ]]; then
            cx_error "$slug 有不該進版控的檔案："; printf '%s\n' "$hits" | sed 's/^/      /' >&2; bad=1
        fi

        # 2) 內容層級（排除 .example / lock 檔）
        hits=$(printf '%s\n' "$files" | grep -vE '\.example$|lock$|\.lock$' | tr '\n' '\0' \
               | xargs -0 -r grep -lIE \
                 'APP_KEY=base64:[A-Za-z0-9+/=]{20,}|BEGIN [A-Z ]*PRIVATE KEY|gh[pousr]_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}|xox[baprs]-[0-9A-Za-z-]{10,}' \
                 2>/dev/null || true)
        if [[ -n $hits ]]; then
            cx_error "$slug 疑似含憑證："; printf '%s\n' "$hits" | sed 's/^/      /' >&2; bad=1
        fi

        # 3) 絕對路徑洩漏（symlink 指向 $HOME）
        hits=$(git -C "$r" ls-files -s | awk '$1=="120000"{print $4}' || true)
        while IFS= read -r l; do
            [[ -n $l ]] || continue
            local tgt; tgt=$(git -C "$r" show ":$l" 2>/dev/null || true)
            [[ $tgt == /* ]] && { cx_error "$slug symlink 指向絕對路徑：$l → $tgt"; bad=1; }
        done <<< "$hits"

        # 4) gitleaks 掃「整個歷史」——祕密一旦進過 commit，改掉當前檔案是不夠的
        if cx_have gitleaks; then
            if ! gitleaks git "$r" --no-banner --redact \
                    --config "$CX_ROOT/docker/security/trivy/gitleaks.toml" \
                    >/dev/null 2>&1; then
                cx_error "$slug gitleaks 在 git 歷史中發現祕密"
                gitleaks git "$r" --no-banner --redact \
                    --config "$CX_ROOT/docker/security/trivy/gitleaks.toml" 2>&1 \
                    | grep -E 'RuleID|File|Commit' | sed 's/^/      /' >&2 || true
                bad=1
            fi
        else
            cx_warn "gitleaks 未安裝 —— 略過歷史掃描（建議安裝）"
        fi

        (( bad )) || cx_ok "$slug 乾淨（$(printf '%s\n' "$files" | wc -l) 個檔案，含歷史）"
    done < <(_git_repos_order)

    (( bad == 0 )) || cx_die "$EX_FAIL" "祕密掃描未通過，已中止"
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
        cx_ok "$slug origin → $url"
    done < <(_git_repos_order)

    cx_info "接著執行：cx git push"
}

# ---------------------------------------------------------------------------
# 推送：子模組先，主庫最後
# ---------------------------------------------------------------------------
_git_push() {
    _git_scan_secrets

    cx_step "推送前檢查"
    local r slug url
    while read -r r; do
        slug=$(_git_repo_slug "$r")
        url=$(git -C "$r" remote get-url origin 2>/dev/null || true)
        [[ -n $url ]] || cx_die "$EX_PRECOND" "$slug 沒有 origin（先跑 cx git remote-init）"
        printf '%s' "$url" | grep -qE "$CX_DENIED_REMOTE_RE" \
            && cx_die "$EX_PRECOND" "$slug 的 origin 在永久黑名單：$url"
        printf '%s' "$url" | grep -qE "$CX_ALLOWED_REMOTE_RE" \
            || cx_die "$EX_PRECOND" "$slug 的 origin 不在白名單：$url"
        cx_ok "$slug → $url"
    done < <(_git_repos_order)

    cx_confirm --danger "推送到 GitHub（PUBLIC）" \
"即將推送三個 repo 到 $CX_GH_ORG：

  1. $CX_REPO_BACKEND    （子模組，先推）
  2. $CX_REPO_FRONTEND   （子模組，先推）
  3. $CX_REPO_MAIN       （主庫，最後推 —— gitlink 需要子模組的 commit 已存在於遠端）

三個 repo 都是 PUBLIC。祕密掃描已通過。

確定要推送嗎？" || return "$EX_ABORT"

    while read -r r; do
        slug=$(_git_repo_slug "$r")
        local br; br=$(git -C "$r" branch --show-current)
        cx_info "推送 $slug（$br）…"
        CX_ALLOW_PUSH=1 cx_run git -C "$r" push -u origin "$br"
        cx_ok "$slug 已推送"
    done < <(_git_repos_order)

    cx_ok "全部完成"
}
