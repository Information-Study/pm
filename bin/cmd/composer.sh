#!/usr/bin/env bash
# cx composer — composer 包裝（永遠在 backend/ 執行）。
#
# 兩條獨立的路：容器 或 原生。runner 由 --runner 決定。
cmd_composer_main() {
    (( $# )) || { printf '用法：cx composer <composer 參數...>\n' >&2; return "$EX_USAGE"; }
    [[ -f $CX_ROOT/backend/composer.json ]] || cx_die "$EX_PRECOND" "找不到 backend/composer.json"

    # 紅線：不得用 --ignore-platform-reqs 掩蓋相依衝突。
    # 兩條路都要擋 —— 原生路徑的平台需求跟容器不一樣，正是最容易想繞過的地方。
    local a
    for a in "$@"; do
        [[ $a == --ignore-platform-req* ]] && cx_die "$EX_USAGE" \
            "拒絕 $a —— 正確診斷是 composer why-not <套件> <版本>（見 claude.md 紅線 4）"
    done

    if [[ $(cx_runner) == docker ]]; then
        cx_runner_need_docker "cx composer"
        cx_runner_banner "容器內的 composer"
        cx_compose_init "$CX_MODE"
        cx_dc run --rm --no-deps --entrypoint composer app "$@"
    else
        cx_runner_need_native "cx composer" composer php
        # ⚠ 兩條路產生的 vendor/ 不保證可以互換。
        # 容器是 php:8.5-fpm-alpine（musl），host 是 Ubuntu（glibc），
        # 而且擴充清單也不同 —— composer 會照「當下這個 php」解相依。
        # 這是刻意的：原生路徑的 vendor 給 IDE 與原生 cx scan code 用，
        # 容器路徑的 vendor 由映像自己管。
        cx_runner_banner "composer $(composer --version 2>/dev/null | awk '{print $3}')"
        cx_run env -C "$CX_ROOT/backend" composer "$@"
    fi
}
