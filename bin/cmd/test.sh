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
_test_php() {
    local mode=${CX_MODE}
    cx_docker_need
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
    _test_php php artisan test "$@"
}

_test_coverage() {
    cx_step "後端覆蓋率"
    cx_ensure_host_dirs "$CX_ROOT/reports/quality"
    # test 映像裝了 xdebug 但預設 XDEBUG_MODE=off（常開會讓 ZAP 的時間量測失真）。
    # 收覆蓋率時才臨時打開，而且只對這一個行程。
    cx_docker_need
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
    if cx_docker_ok && [[ -f $CX_ROOT/docker-compose.yml ]]; then
        cx_compose_init "$CX_MODE"
        cx_dc run --rm --no-deps --entrypoint npm nuxt run typecheck
    elif cx_have npm && [[ -d $CX_ROOT/frontend/node_modules ]]; then
        ( cd "$CX_ROOT/frontend" && cx_run npm run typecheck )
    else
        cx_warn "沒有 Docker 也沒有 frontend/node_modules —— 跳過"
        cx_dim "  cx setup deps 或 cx dev up -d"
        return 0
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
