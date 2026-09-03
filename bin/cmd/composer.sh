#!/usr/bin/env bash
# cx composer — composer 包裝（永遠在 backend/ 執行）。
cmd_composer_main() {
    (( $# )) || { printf '用法：cx composer <composer 參數...>\n' >&2; return "$EX_USAGE"; }
    [[ -f $CX_ROOT/backend/composer.json ]] || cx_die "$EX_PRECOND" "找不到 backend/composer.json"
    # 紅線：不得用 --ignore-platform-reqs 掩蓋相依衝突
    local a
    for a in "$@"; do
        [[ $a == --ignore-platform-req* ]] && cx_die "$EX_USAGE" \
            "拒絕 $a —— 正確診斷是 composer why-not <套件> <版本>（見 claude.md 紅線 4）"
    done
    if cx_docker_ok && [[ -f $CX_ROOT/docker-compose.yml ]]; then
        cx_dim "runner: docker"
        cx_run docker compose --project-directory "$CX_ROOT" -p "pm_${CX_MODE}" \
            -f "$CX_ROOT/docker-compose.yml" -f "$CX_ROOT/docker/compose/${CX_MODE}.yml" \
            run --rm --no-deps --entrypoint composer app "$@"
    else
        cx_have composer || cx_die "$EX_PRECOND" "本機沒有 composer，且 Docker 不可用"
        cx_dim "runner: native"
        cx_run env -C "$CX_ROOT/backend" composer "$@"
    fi
}
