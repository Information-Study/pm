#!/usr/bin/env bash
# cx style — 程式碼風格：PHP 用 Laravel Pint，前端用 Prettier。
#
# 為什麼是一個獨立的動詞，而不是塞進 cx lint：
#   cx lint 做的是 Ansible 的靜態檢查（歷史因素，見那個檔案的檔頭）。
#   而「風格」與「靜態分析」是兩件事：風格會**改檔案**，靜態分析不會。
#   把兩者混在一個動詞底下，遲早會有人在 CI 裡跑 lint 然後意外改了一整棵樹。
#   所以：cx style 預設會改檔案，--check 只檢查不改（CI 用這個）。
#   cx lint php / cx lint js 則是 --check 的別名，永遠不改檔案。
#
# 兩個工具都**已經隨既有相依裝好**，不需要額外安裝：
#   src/backend/vendor/bin/pint            ← composer.json 的 require-dev
#   src/frontend/node_modules/.bin/prettier ← package.json 的 devDependencies
# 在 2026-09-05 之前這兩個都沒有任何動詞叫得到，等於買了沒用。

_style_usage() {
    cat >&2 <<'TXT'
用法：cx style [php|js|all] [--check] [-- 工具參數...]

  php     Laravel Pint（backend/）
  js      Prettier（frontend/）
  all     兩者都跑（預設）

旗標
  --check   只檢查不修改，有差異就回非零 —— CI 與提交前用這個
            （不加的話會**直接改檔案**）

範例
  cx style                    # 兩邊都格式化
  cx style php                # 只格式化 backend
  cx style --check            # 只檢查（CI）
  cx style php -- --dirty     # 把 --dirty 傳給 pint（只處理未提交的檔）
TXT
}

# ── PHP：Pint ───────────────────────────────────────────────────────────────
_style_php() {
    local check=$1; shift
    [[ -f $CX_ROOT/src/backend/composer.json ]] || {
        cx_warn "找不到 src/backend/composer.json，略過 PHP"; return "$EX_PRECOND"; }

    local -a args=()
    (( check )) && args+=(--test)
    args+=("$@")

    cx_step "PHP 風格 — Laravel Pint$( ((check)) && printf '（--test，不改檔案）')"
    if [[ $(cx_runner) == docker ]]; then
        cx_runner_need_docker "cx style php"
        cx_runner_banner "容器內的 pint"
        cx_compose_init "$CX_MODE"
        # -u：backend/ 在 dev 是 bind mount，以 root 跑會把改過的檔案變成 root:root。
        cx_dc run --rm --no-deps -u "$(id -u):$(id -g)" \
            --entrypoint vendor/bin/pint app "${args[@]}"
    else
        cx_runner_need_native "cx style php" php
        [[ -x $CX_ROOT/src/backend/vendor/bin/pint ]] || cx_die "$EX_PRECOND" \
            "找不到 src/backend/vendor/bin/pint —— 先跑 cx --runner native composer install"
        cx_runner_banner "src/backend/vendor/bin/pint"
        cx_run env -C "$CX_ROOT/src/backend" vendor/bin/pint "${args[@]}"
    fi
}

# ── 前端：Prettier ──────────────────────────────────────────────────────────
_style_js() {
    local check=$1; shift
    [[ -f $CX_ROOT/src/frontend/package.json ]] || {
        cx_warn "找不到 src/frontend/package.json，略過前端"; return "$EX_PRECOND"; }

    local -a args=()
    if (( check )); then args+=(--check); else args+=(--write); fi
    # 明確給目標。裸的 prettier 不吃預設路徑，而 `.` 會連 node_modules
    # 與 .nuxt／.output 一起掃 —— 那是幾萬個檔案，而且會改到產出物。
    args+=(. --ignore-path .gitignore)
    args+=("$@")

    cx_step "前端風格 — Prettier$( ((check)) && printf '（--check，不改檔案）')"
    if [[ $(cx_runner) == docker ]]; then
        cx_runner_need_docker "cx style js"
        cx_runner_banner "compose 的 nuxt service"
        cx_compose_init "$CX_MODE"
        cx_dc run --rm --no-deps -u "$(id -u):$(id -g)" \
            --entrypoint npx nuxt prettier "${args[@]}"
    else
        cx_runner_need_native "cx style js" npm
        [[ -x $CX_ROOT/src/frontend/node_modules/.bin/prettier ]] || cx_die "$EX_PRECOND" \
            "找不到 src/frontend/node_modules/.bin/prettier —— 先跑 cx --runner native npm ci"
        cx_runner_banner "src/frontend/node_modules/.bin/prettier"
        cx_run env -C "$CX_ROOT/src/frontend" node_modules/.bin/prettier "${args[@]}"
    fi
}

cmd_style_main() {
    local target=all check=0
    local -a passthru=()
    while (( $# )); do
        case $1 in
            php|js|all)   target=$1; shift ;;
            --check)      check=1; shift ;;
            -h|--help)    _style_usage; return 0 ;;
            --)           shift; passthru=("$@"); break ;;
            *)            cx_die "$EX_USAGE" "未知參數：$1（cx style --help）" ;;
        esac
    done

    # 兩邊都跑完再回傳最嚴重的碼 —— 不是遇到第一個差異就停。
    # 停在第一個的話，前端的格式問題永遠等不到後端乾淨的那一天才會被看見。
    local worst=0 rc=0
    case $target in
        php) _style_php "$check" "${passthru[@]+"${passthru[@]}"}" || worst=$? ;;
        js)  _style_js  "$check" "${passthru[@]+"${passthru[@]}"}" || worst=$? ;;
        all)
            rc=0; _style_php "$check" || rc=$?
            (( rc > worst )) && worst=$rc
            rc=0; _style_js "$check" || rc=$?
            (( rc > worst )) && worst=$rc
            ;;
    esac

    if (( worst == 0 )); then
        cx_ok "風格檢查通過"
    elif (( check )); then
        cx_error "有檔案不符合風格 —— 跑 cx style 自動修正"
    fi
    return "$worst"
}
