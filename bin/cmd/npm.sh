#!/usr/bin/env bash
# cx npm — npm 包裝（永遠在 frontend/ 執行）。
cmd_npm_main() {
    (( $# )) || { printf '用法：cx npm <npm 參數...>\n例：cx npm ci ／ cx npm run build\n' >&2; return "$EX_USAGE"; }
    [[ -f $CX_ROOT/frontend/package.json ]] || cx_die "$EX_PRECOND" "找不到 frontend/package.json"
    if cx_docker_ok && [[ -f $CX_ROOT/docker-compose.yml ]]; then
        cx_dim "runner: docker"
        cx_run docker compose --project-directory "$CX_ROOT" -p "pm_${CX_MODE}" \
            -f "$CX_ROOT/docker-compose.yml" -f "$CX_ROOT/docker/compose/${CX_MODE}.yml" \
            run --rm --no-deps --entrypoint npm nuxt "$@"
    else
        cx_have npm || cx_die "$EX_PRECOND" "本機沒有 npm，且 Docker 不可用"
        cx_dim "runner: native (npm $(npm --version))"
        cx_run env -C "$CX_ROOT/frontend" npm "$@"
    fi
}
