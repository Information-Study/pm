#!/usr/bin/env bash
# cx test —— 兩件事共用一個動詞：
#
#   1) test 模式的 compose 操作      cx test up -d / cx test ps / cx test logs …
#   2) 跑測試套件                    cx test back / cx test front / cx test all
#
# 兩組子指令沒有交集，所以不會有歧義。第一個參數落在 compose 動作白名單裡
# 就走 (1)，否則走 (2)。claude.md §7 兩種寫法都有列，這裡把它們統一起來。

_test_usage() {
    cat >&2 <<'TXT'
cx test <子指令> [參數...]

test 模式的容器操作（等同 cx --mode test <動作>）
  up / down / restart / ps / logs / sh / build / config / dc

跑測試
  back [參數...]     後端 PHPUnit（php artisan test）
  front              前端型別檢查（nuxt typecheck）
  all                back + front
  coverage           後端覆蓋率（需要 xdebug，會臨時打開）
  larastan           靜態分析（等同 cx scan code 的第一段）

範例
  cx test up -d --build      起測試環境（含 ModSecurity WAF）
  cx test back               跑後端測試
  cx test back --filter=User 只跑符合的測試
  cx test all
  cx test coverage

後端測試的資料庫：backend/phpunit.xml 把它導向 sqlite :memory:，
所以 cx test back 不需要 MySQL。那個檔的每個 <env> 都有 force="true" ——
沒有它的話 compose 傳進來的 DB_CONNECTION=mysql 會蓋掉 sqlite 設定，
測試會打到真正的開發資料庫，而 RefreshDatabase 會把它清空。
TXT
}

# 跑測試用的容器：優先用「已經起來的 app」，沒有就開一個 run --rm。
# 用 run --rm 時要 --no-deps —— sqlite in-memory 不需要 MySQL，
# 不加的話會為了跑一個單元測試而把整個資料庫拉起來。
# 後端測試的環境變數。兩條路共用同一份 —— 這是第二道保險：
# phpunit.xml 的每個 <env> 已經有 force="true"，但就算有人把它拿掉，
# 測試也不會打到真的資料庫。
_test_env_pairs() {
    printf '%s\n' \
        DB_CONNECTION=sqlite \
        DB_DATABASE=:memory: \
        APP_ENV=testing \
        CACHE_STORE=array \
        SESSION_DRIVER=array \
        QUEUE_CONNECTION=sync
}

# 原生路徑跑 php artisan test。
# sqlite :memory: 需要 pdo_sqlite —— 缺了它 Laravel 的錯誤是
#   could not find driver
# 完全不會提到「請安裝 php-sqlite3」，所以這裡先擋並講清楚。
_test_php_native() {
    cx_runner_need_native "cx test" php
    [[ -f $CX_ROOT/backend/vendor/autoload.php ]] || cx_die "$EX_PRECOND" \
        "backend/vendor 不存在 —— 先跑 cx --runner native composer install"
    if ! php -m 2>/dev/null | grep -qix pdo_sqlite; then
        cx_error "原生 PHP 缺少 pdo_sqlite —— 後端測試走 sqlite :memory:，沒有它跑不起來"
        cx_dim "  Laravel 的訊息會是「could not find driver」，不會提到套件名"
        local _pv; _pv=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)
        cx_dim "  安裝： sudo apt install php${_pv}-sqlite3"
        cx_dim "  或改用容器： cx --runner docker test back"
        exit "$EX_PRECOND"
    fi
    cx_runner_banner "php $(php -r 'echo PHP_VERSION;' 2>/dev/null)"
    local -a envs=()
    while IFS= read -r kv; do envs+=("$kv"); done < <(_test_env_pairs)
    cx_run env -C "$CX_ROOT/backend" "${envs[@]}" php artisan test "$@"
}

_test_php() {
    local mode=${CX_MODE}
    cx_runner_need_docker "cx test（容器路徑）"
    cx_runner_banner "容器內的 php"
    cx_compose_init "$mode"

    # 明確覆蓋資料庫設定。phpunit.xml 已經有 force="true"，這裡是第二道保險：
    # 就算有人不小心把 force 拿掉，也不會打到真的資料庫。
    local -a envs=(
        -e DB_CONNECTION=sqlite
        -e DB_DATABASE=:memory:
        -e APP_ENV=testing
        -e CACHE_STORE=array
        -e SESSION_DRIVER=array
        -e QUEUE_CONNECTION=sync
    )
    if cx_dc_q ps --status running --services 2>/dev/null | grep -qx app; then
        cx_dc exec -T "${envs[@]}" app "$@"
    else
        cx_info "app 容器沒在跑 → 用 run --rm --no-deps"
        cx_dc run --rm --no-deps "${envs[@]}" --entrypoint "$1" app "${@:2}"
    fi
}

_test_back() {
    cx_step "後端測試（php artisan test）"
    if [[ $(cx_runner) == docker ]]; then
        _test_php php artisan test "$@"
    else
        _test_php_native "$@"
    fi
}

_test_coverage() {
    cx_step "後端覆蓋率"
    cx_ensure_host_dirs "$CX_ROOT/reports/quality"
    # test 映像裝了 xdebug 但預設 XDEBUG_MODE=off（常開會讓 ZAP 的時間量測失真）。
    # 收覆蓋率時才臨時打開，而且只對這一個行程。
    # 覆蓋率只有容器路徑：test 映像裝了 xdebug，原生 PHP 不一定有，
    # 而且用哪一個 xdebug 版本會影響覆蓋率數字的可比性。
    [[ $(cx_runner) == native ]] && cx_die "$EX_PRECOND" \
        "cx test coverage 只有容器路徑（需要 test 映像裡的 xdebug）—— 改用 cx --runner docker test coverage"
    cx_runner_need_docker "cx test coverage"
    cx_compose_init "$CX_MODE"
    cx_dc exec -T \
        -e XDEBUG_MODE=coverage \
        -e DB_CONNECTION=sqlite -e DB_DATABASE=:memory: -e APP_ENV=testing \
        app php artisan test \
            --coverage-clover=/var/www/html/storage/coverage-backend.xml \
            --log-junit=/var/www/html/storage/junit-backend.xml "$@"
    # sonar-project.properties 指定的是 reports/quality/ 底下的路徑，
    # 所以要把報告從容器搬出來。
    local c
    c=$(cx_dc_q ps -q app 2>/dev/null | head -1)
    if [[ -n $c ]]; then
        docker cp "$c:/var/www/html/storage/coverage-backend.xml" \
                  "$CX_ROOT/reports/quality/coverage-backend.xml" 2>/dev/null \
            && cx_ok "reports/quality/coverage-backend.xml"
        docker cp "$c:/var/www/html/storage/junit-backend.xml" \
                  "$CX_ROOT/reports/quality/junit-backend.xml" 2>/dev/null \
            && cx_ok "reports/quality/junit-backend.xml"
    fi
}

_test_front() {
    cx_step "前端型別檢查（nuxt typecheck）"
    # frontend 目前沒有測試框架，typecheck 是唯一有意義的自動檢查。
    # 它同時會驗證 nuxt.config.ts、元件與 store 的型別。
    if [[ $(cx_runner) == docker ]]; then
        cx_runner_need_docker "cx test front"
        cx_runner_banner "compose 的 nuxt service"
        cx_compose_init "$CX_MODE"
        cx_dc run --rm --no-deps --entrypoint npm nuxt run typecheck
    else
        cx_runner_need_native "cx test front" npm
        # node_modules 是原生路徑的硬需求。以前這裡是 cx_warn + return 0，
        # 也就是「跳過」還算成功 —— CI 上會變成一個永遠綠但什麼都沒做的步驟。
        [[ -d $CX_ROOT/frontend/node_modules ]] || cx_die "$EX_PRECOND" \
            "frontend/node_modules 不存在 —— 先跑 cx --runner native npm ci"
        cx_runner_banner "host npm $(npm --version 2>/dev/null)"
        ( cd "$CX_ROOT/frontend" && cx_run npm run typecheck )
    fi
}

_test_larastan() {
    # shellcheck source=/dev/null
    . "$CX_ROOT/bin/cmd/scan.sh"
    cmd_scan_main code
}

cmd_test_main() {
    local sub=${1:-all}
    [[ $# -gt 0 ]] && shift

    case $sub in
        -h|--help|help) _test_usage; return 0 ;;
    esac

    # (1) compose 動作 → 直接轉給 compose.sh，模式固定 test
    case " $CX_COMPOSE_VERBS_LIST " in
        *" $sub "*)
            # shellcheck source=/dev/null
            . "$CX_ROOT/bin/cmd/compose.sh"
            CX_VERB=$sub CX_MODE=test cmd_compose_main "$@"
            return
            ;;
    esac

    # (2) 測試套件
    case $sub in
        back|backend)   _test_back "$@" ;;
        front|frontend) _test_front "$@" ;;
        coverage|cov)   _test_coverage "$@" ;;
        larastan|code)  _test_larastan ;;
        all)
            local rc=0
            _test_back "$@" || rc=$?
            _test_front     || rc=$?
            return "$rc"
            ;;
        *) cx_error "未知的子指令：$sub"; _test_usage; return "$EX_USAGE" ;;
    esac
}
