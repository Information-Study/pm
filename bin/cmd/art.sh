#!/usr/bin/env bash
# cx art — artisan 包裝。兩條獨立的路：容器 或 原生 PHP。
#
# runner 由 --runner 決定（docker|native|auto，預設 auto）。
# 被指定的那一邊不可用時硬失敗，不會偷偷換另一邊跑。
cmd_art_main() {
    (( $# )) || { printf '用法：cx art <artisan 參數...>\n例：cx art migrate:status\n' >&2; return "$EX_USAGE"; }
    [[ -f $CX_ROOT/backend/artisan ]] || cx_die "$EX_PRECOND" "找不到 backend/artisan"

    if [[ $(cx_runner) == docker ]]; then
        cx_runner_need_docker "cx art"
        cx_runner_banner "容器內的 php"
        cx_compose_init "$CX_MODE"
        cx_dc run --rm --no-deps --entrypoint php app artisan "$@"
    else
        cx_runner_need_native "cx art" php
        # vendor/ 是原生路徑的硬需求：artisan 第一行就 require vendor/autoload.php，
        # 缺了它的錯誤是 "Failed opening required" 而不是「請先安裝相依」。
        [[ -f $CX_ROOT/backend/vendor/autoload.php ]] || cx_die "$EX_PRECOND" \
            "backend/vendor 不存在 —— 先跑 cx --runner native composer install"
        cx_runner_banner "php $(php -r 'echo PHP_VERSION;' 2>/dev/null)"
        cx_run env -C "$CX_ROOT/backend" php artisan "$@"
    fi
}

# cx php — 直接跑 php（不是 artisan）。
#
# 存在的理由：cx art 只涵蓋 artisan，但很多時候要問的是「php 本身」——
# php -v / php -m / php -r / 跑一支一次性腳本。
# 沒有這個動詞的話，使用者只能自己找容器名或自己 cd 到 backend，
# 那正是「繞過 cx」的開始。
cmd_php_main() {
    (( $# )) || { printf '用法：cx php <php 參數...>\n例：cx php -m｜cx php -v｜cx php -r "echo PHP_VERSION;"\n' >&2; return "$EX_USAGE"; }

    if [[ $(cx_runner) == docker ]]; then
        cx_runner_need_docker "cx php"
        cx_runner_banner "容器內的 php"
        cx_compose_init "$CX_MODE"
        cx_dc run --rm --no-deps --entrypoint php app "$@"
    else
        cx_runner_need_native "cx php" php
        cx_runner_banner "php $(php -r 'echo PHP_VERSION;' 2>/dev/null)"
        cx_run env -C "$CX_ROOT/backend" php "$@"
    fi
}
