#!/usr/bin/env bash
# cx art — artisan 包裝。有 Docker 走容器，否則直接跑本機 PHP。
cmd_art_main() {
    (( $# )) || { printf '用法：cx art <artisan 參數...>\n例：cx art migrate:status\n' >&2; return "$EX_USAGE"; }
    [[ -f $CX_ROOT/backend/artisan ]] || cx_die "$EX_PRECOND" "找不到 backend/artisan"
    if cx_docker_ok && [[ -f $CX_ROOT/docker-compose.yml ]]; then
        cx_dim "runner: docker"
        cx_run docker compose --project-directory "$CX_ROOT" -p "pm_${CX_MODE}" \
            -f "$CX_ROOT/docker-compose.yml" -f "$CX_ROOT/docker/compose/${CX_MODE}.yml" \
            run --rm --entrypoint php app artisan "$@"
    else
        cx_have php || cx_die "$EX_PRECOND" "本機沒有 php，且 Docker 不可用"
        cx_dim "runner: native (php $(php -r 'echo PHP_VERSION;'))"
        cx_run env -C "$CX_ROOT/backend" php artisan "$@"
    fi
}
