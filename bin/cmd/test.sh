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

後端測試的資料庫：走 sqlite :memory:，所以 cx test back 不需要 MySQL。

⚠ 導向 sqlite 的是 cx，不是 phpunit.xml。那個檔的 <env force="true">
  在容器裡**沒有作用** —— PHPUnit 的 force 只寫 putenv() 與 $_ENV，
  不寫 $_SERVER，而 Laravel 的 Env 讀 $_SERVER 優先，
  compose 的 environment: 讓 $_SERVER 一定有值。
  實測：容器裡裸跑 php artisan test 打的是真的 dev MySQL。
  請一律用 cx test（它用 -e 蓋掉 $_SERVER）—— 見 claude.md §0 紅線 5。
TXT
}

# 跑測試用的容器：優先用「已經起來的 app」，沒有就開一個 run --rm。
# 用 run --rm 時要 --no-deps —— sqlite in-memory 不需要 MySQL，
# 不加的話會為了跑一個單元測試而把整個資料庫拉起來。
# 後端測試的環境變數。兩條路共用同一份，而且這是**唯一**一道保險 ——
# 不是「第二道」。phpunit.xml 的 <env force="true"> 在容器裡無效：
# PHPUnit 的 force 只寫 putenv() 與 $_ENV，不寫 $_SERVER，而 Laravel 的 Env
# 讀 $_SERVER 優先，compose 的 environment: 讓 $_SERVER 一定有值。
# 實測容器裡裸跑 php artisan test 打的是真的 dev MySQL（claude.md §0 紅線 5）。
# 拿掉這份清單，任何用 RefreshDatabase 的測試都會清空開發資料庫。
_test_env_pairs() {
    printf '%s\n' \
        DB_CONNECTION=sqlite \
        DB_DATABASE=:memory: \
        APP_ENV=testing \
        CACHE_STORE=array \
        SESSION_DRIVER=array \
        QUEUE_CONNECTION=sync
}

# 同一份清單的 docker 版（-e K=V）。原本容器路徑與覆蓋率各自抄了一份，
# 而且覆蓋率那份只抄了前三個 —— 少掉的 SESSION_DRIVER=array 讓 session
# 走 database driver，測試就死在「no such table: sessions」。
# 三個地方都必須讀同一個來源，否則下次還是會漂移。
_test_env_docker_args() {
    local kv
    while IFS= read -r kv; do printf '%s\n%s\n' -e "$kv"; done < <(_test_env_pairs)
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

    # 這些 -e 不是「第二道保險」，它是**唯一**一道。
    # phpunit.xml 的 <env force="true"> 在這個環境下是無效的：
    # PHPUnit 的 force 只寫 putenv() 與 $_ENV，不寫 $_SERVER；
    # 而 Laravel 的 Env 讀取順序是 ServerConstAdapter($_SERVER) 先於
    # EnvConstAdapter($_ENV)，compose 的 environment: 又讓 $_SERVER 一定有值，
    # 於是 $_SERVER 的 mysql/database 永遠贏過 phpunit.xml 的 sqlite/array。
    # 實測：容器裡裸跑 php artisan test（不帶 -e）會打到真的 dev MySQL。
    # 拿掉這些 -e，任何用 RefreshDatabase 的測試都會清空開發資料庫。
    local -a envs=(); mapfile -t envs < <(_test_env_docker_args)

    # 以 host 的 uid 執行。backend/ 是 bind mount，容器預設以 root 跑，
    # phpunit 會在裡面留下 root:root 的 .phpunit.result.cache，
    # 之後 --runner native 跑同一套測試就會噴
    #   file_put_contents(.phpunit.result.cache): Permission denied
    # backend/storage 與 bootstrap/cache 本來就屬於 uid 1000，所以這樣是安全的。
    local -a asuser=(-u "$(id -u):$(id -g)")
    if cx_dc_q ps --status running --services 2>/dev/null | grep -qx app; then
        cx_dc exec -T "${asuser[@]}" "${envs[@]}" app "$@"
    else
        cx_info "app 容器沒在跑 → 用 run --rm --no-deps"
        cx_dc run --rm --no-deps "${asuser[@]}" "${envs[@]}" --entrypoint "$1" app "${@:2}"
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

    # 與 cx test back 讀同一份環境變數清單。曾經只抄了 DB_CONNECTION /
    # DB_DATABASE / APP_ENV 三個，少掉 SESSION_DRIVER=array，
    # 於是 session 走 database driver 而 sqlite :memory: 沒跑過 migration，
    # 每次都死在 no such table: sessions —— 但 cx test back 是好的，
    # 看起來像「覆蓋率壞掉」，其實是兩份清單漂移。
    local -a envs=(); mapfile -t envs < <(_test_env_docker_args)

    # 產物寫到容器裡「每次執行都不一樣」的目錄，不要寫 /var/www/html/storage
    # 也不要寫固定的 /tmp/<檔名>：
    #   * storage 是 bind mount —— 以 root 跑的話會在 backend/ 留下 root:root
    #     的檔案，submodule 多出未提交變更而且 uid 1000 刪不掉
    #   * 固定路徑 —— /tmp 是 1777，別人（例如舊版以 root 跑過）留下的同名檔
    #     刪不掉也覆蓋不了，phpunit 直接 exit 255；更糟的是後面的 docker cp
    #     仍然會成功，把**上一次的舊報告**複製出來並印 ✔
    local -a asuser=(-u "$(id -u):$(id -g)")
    local tmpd="/tmp/cx-cov-$$"
    local rc=0
    cx_dc exec -T "${asuser[@]}" app mkdir -p "$tmpd" \
        || cx_die "$EX_FAIL" "容器內建不出暫存目錄 $tmpd"
    cx_dc exec -T "${asuser[@]}" -e XDEBUG_MODE=coverage "${envs[@]}" \
        app php artisan test \
            --coverage-clover="$tmpd/coverage-backend.xml" \
            --log-junit="$tmpd/junit-backend.xml" "$@" || rc=$?

    # 先搬報告再回傳 rc —— 測試失敗的時候 junit 報告才是最有用的，
    # 不能因為 rc 非 0 就跳過。
    local c
    c=$(cx_dc_q ps -q app 2>/dev/null | head -1)
    if [[ -n $c ]]; then
        docker cp "$c:$tmpd/coverage-backend.xml" \
                  "$CX_ROOT/reports/quality/coverage-backend.xml" 2>/dev/null \
            && cx_ok "reports/quality/coverage-backend.xml"
        docker cp "$c:$tmpd/junit-backend.xml" \
                  "$CX_ROOT/reports/quality/junit-backend.xml" 2>/dev/null \
            && cx_ok "reports/quality/junit-backend.xml"
        # 用 cx_dc（會遵守 --dry-run）而不是 cx_dc_q ——
        # cx_dc_q 直接呼叫 docker compose，所以 cx --dry-run test coverage
        # 會真的在容器裡執行 rm -rf。--dry-run 執行破壞性動作是不可接受的。
        cx_dc exec -T "${asuser[@]}" app rm -rf "$tmpd" 2>/dev/null || true
    fi

    # ⚠ 這個 return 是重點。原本函式最後一個指令是 docker cp / cx_ok，
    # 於是「測試失敗但報告搬成功」會回傳 0 ——
    # 實測 1 failed 1 passed 的情況下 cx test coverage rc=0，
    # 在 CI 上就是一個永遠綠的步驟。
    (( rc == 0 )) || cx_error "後端測試失敗（rc=$rc）—— 覆蓋率報告仍已產生"
    return "$rc"
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
