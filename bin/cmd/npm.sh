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

cmd_npm_main() {
    local where=frontend svc=nuxt
    while (( $# )); do
        case $1 in
            --backend|--php) where=backend; svc=app; shift ;;
            --frontend)      where=frontend; svc=nuxt; shift ;;
            --) shift; break ;;
            *) break ;;
        esac
    done

    [[ -f $CX_ROOT/$where/package.json ]] \
        || cx_die "$EX_PRECOND" "找不到 $where/package.json"

    if cx_docker_ok && [[ -f $CX_ROOT/docker-compose.yml ]] \
       && [[ -f $CX_ROOT/docker/compose/${CX_MODE}.yml ]]; then
        cx_compose_init "$CX_MODE"
        # --no-deps：npm 不需要資料庫。少了它會為了跑一個 npm ci 把整組拉起來。
        cx_dc run --rm --no-deps --entrypoint npm "$svc" "$@"
    else
        cx_have npm || cx_die "$EX_PRECOND" "沒有 Docker 也沒有 npm —— 跑 cx setup tools node"
        cx_run env -C "$CX_ROOT/$where" npm "$@"
    fi
}
