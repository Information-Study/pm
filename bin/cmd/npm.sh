#!/usr/bin/env bash
# cx npm —— npm。預設在 frontend/，加 --backend 則在 backend/。
#
# 為什麼需要 --backend：backend 也有自己的 package.json
#（Vite + Tailwind，用來建置 Laravel 端的 blade 資產 public/build/）。
# 舊版的 init.sh / refresh.sh 呼叫一個叫 npm-php 的 service 來做這件事，
# 但那個 service 從來沒有存在過（驗證文件的缺陷 D3）——
# 所以「後端資產」在舊專案裡其實從來沒被建置過。
#
# welcome.blade.php 有 @vite(...)，沒有 public/build/manifest.json 時
# 渲染會直接丟 ViteManifestNotFoundException。

# ⚠ 前端與後端走的是不同的容器，這不是可以合併的兩條路：
#
#   frontend → compose 的 nuxt service。那個容器就是 node，
#              node_modules 是具名 volume、由 Alpine 映像種子化，
#              跟容器內的 libc 一致。
#
#   backend  → 不能用 app service。app 是 php:8.5-fpm-alpine，
#              裡面根本沒有 node/npm，實測會是
#                exec: "npm": executable file not found in $PATH
#              後端資產在正式流程裡是由 env/docker/php/Dockerfile 的
#              backend-assets stage 建的（那個 stage 才有 node，
#              而且它在映像內自己 npm ci，不掛 host 的 node_modules）。
#
# ── 為什麼後端優先用 host 的 npm ────────────────────────────────────────────
# src/backend/node_modules 是掛在 host 上的真實目錄，它的原生模組（Vite 8 的
# rolldown binding）是照安裝當下的 libc 編的。
# host 是 Ubuntu（glibc），把它掛進 Alpine（musl）容器會直接爆：
#   Error: Cannot find native binding
#   Cannot find module '@rolldown/binding-linux-x64-musl'
# 訊息指向 npm 的 optional dependencies bug，其實只是 libc 不匹配。
#
# 所以順序是：host 的 npm → 沒有的話用 glibc 的 node 映像（bookworm-slim），
# 兩條路產生的 node_modules 都能被對方使用。
# 刻意不用 Alpine：那會產生一份只有 Alpine 能用的 node_modules，
# 之後在 host 上跑 npm run build 又會壞，而且錯誤訊息一模一樣。
CX_NODE_GLIBC_IMAGE="${CX_NODE_GLIBC_IMAGE:-$CX_IMG_NODE_GLIBC}"

# ── backend 的兩條路 ────────────────────────────────────────────────────────
# native：host 的 npm 直接跑（src/backend/node_modules 是 host 上的真實目錄）
# docker：glibc 的 node 一次性容器（**不是** compose 的 nuxt service，
#         那個容器的 node_modules 是 frontend 的具名 volume，跟 backend 無關）
_npm_backend_native() {
    cx_runner_need_native "cx npm --backend" npm
    cx_runner_banner "host npm $(npm --version 2>/dev/null)"
    cx_run env -C "$CX_ROOT/src/backend" npm "$@"
}

_npm_backend_docker() {
    cx_runner_need_docker "cx npm --backend"
    cx_runner_banner "$CX_NODE_GLIBC_IMAGE 一次性容器"
    cx_run docker run --rm \
        -u "$(id -u):$(id -g)" \
        -v "$CX_ROOT/src/backend:/app" \
        -w /app \
        -e npm_config_cache=/tmp/.npm \
        -e HOME=/tmp \
        "$CX_NODE_GLIBC_IMAGE" npm "$@"
}

_npm_backend() {
    case $(cx_runner) in
        docker) _npm_backend_docker "$@" ;;
        *)      _npm_backend_native "$@" ;;
    esac
}

# ── frontend 的兩條路 ───────────────────────────────────────────────────────
_npm_frontend_native() {
    cx_runner_need_native "cx npm" npm
    cx_runner_banner "host npm $(npm --version 2>/dev/null)"
    cx_run env -C "$CX_ROOT/src/frontend" npm "$@"
}

_npm_frontend_docker() {
    cx_runner_need_docker "cx npm"
    [[ -f $CX_ROOT/env/docker/compose/${CX_MODE}.yml ]] \
        || cx_die "$EX_PRECOND" "缺少 env/docker/compose/${CX_MODE}.yml"
    cx_runner_banner "compose 的 nuxt service"
    cx_compose_init "$CX_MODE"
    # --no-deps：npm 不需要資料庫。少了它會為了跑一個 npm ci 把整組拉起來。
    cx_dc run --rm --no-deps --entrypoint npm nuxt "$@"
}

_npm_frontend() {
    case $(cx_runner) in
        docker) _npm_frontend_docker "$@" ;;
        *)      _npm_frontend_native "$@" ;;
    esac
}

_npm_usage() {
    cat >&2 <<'TXT'
用法：cx npm [--backend|--frontend] <npm 參數...>

  （預設）      在 frontend/ 執行
  --backend     在 backend/ 執行（Laravel 端的 Vite 資產）
  --frontend    明確指定 frontend/

  --            之後的參數原樣交給 npm（要傳 npm 自己的 -h 時用）

runner 由全域 --runner 決定：
  cx --runner docker npm ci      frontend 用 compose 的 nuxt service
                                 backend 用 node:24.20-bookworm-slim 一次性容器
  cx --runner native npm ci      直接用 host 的 npm

例
  cx npm ci
  cx npm run build
  cx npm --backend ci
  cx npm --backend run build
  cx npm -- --help              # npm 自己的說明
TXT
}

cmd_npm_main() {
    local where=frontend
    while (( $# )); do
        case $1 in
            -h|--help)       _npm_usage; return 0 ;;
            --backend|--php) where=backend;  shift ;;
            --frontend)      where=frontend; shift ;;
            --) shift; break ;;
            *) break ;;
        esac
    done
    (( $# )) || { _npm_usage; return "$EX_USAGE"; }

    [[ -f $CX_ROOT/$where/package.json ]] \
        || cx_die "$EX_PRECOND" "找不到 $where/package.json"

    if [[ $where == backend ]]; then
        _npm_backend "$@"
    else
        _npm_frontend "$@"
    fi
}
