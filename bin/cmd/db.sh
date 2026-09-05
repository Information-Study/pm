#!/usr/bin/env bash
# cx db —— 資料庫操作（作用於目前 --mode 的 compose project）。
#
# 紅線 2：任何刪除都要互動確認，不可逆的還要輸入確認字串。
# 這裡 drop / fresh / restore 三個都會覆寫或清空資料，全部有閘門。

_db_usage() {
    cat >&2 <<'TXT'
cx db <子指令> [參數...]        （作用於 --mode，預設 dev）

  status              連線資訊、資料表數量、migration 狀態
  shell [SQL]         進 mysql client；給了 SQL 就執行它然後結束
  wait                等 MySQL 就緒（CI 用）
  migrate             php artisan migrate --force
  fresh               ⚠ migrate:fresh --seed（清空所有資料表再重建）
  seed                php artisan db:seed --force
  dump [檔案]         mysqldump 到檔案（預設 reports/db/<mode>-<時間>.sql.gz）
  restore <檔案>      ⚠ 從 dump 還原（會先要求輸入確認字串）
  admin               建立 Filament 管理員（artisan make:filament-user）

範例
  cx db status
  cx --mode test db fresh
  cx db shell "SELECT COUNT(*) FROM users"
  cx db dump
  cx db restore reports/db/dev-20260904T010203Z.sql.gz
TXT
}

# mysql client 在 app 容器裡（base stage 有裝 mysql-client），
# 不在 mysql 容器裡執行是因為 app 容器才有 .env 與 artisan。
_db_env() {
    # 從合併後的 compose 設定讀，而不是自己解析 .env ——
    # 這樣 env/docker/compose/<mode>.env 的覆寫才會被算進去。
    cx_dc_q config --format json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
env = ((d.get("services") or {}).get("app") or {}).get("environment") or {}
for k in ("DB_DATABASE", "DB_USERNAME", "DB_PASSWORD"):
    print(f"{k}={env.get(k, '')}")
'
}

# ⚠ 一定要在 mysql 容器裡執行 client，不能在 app 容器裡。
#
# app 容器是 Alpine，apk add mysql-client 裝到的其實是 MariaDB client。
# 它與 MySQL 原廠 client 有兩個要命的差異：
#   1) 預設會驗證伺服器憑證。MySQL 8.4 出廠是自簽憑證，於是每一次連線都是
#      ERROR 2026 (HY000): TLS/SSL error: self-signed certificate in certificate chain
#      —— 訊息看起來像 TLS 設定壞了，其實只是用錯 client。
#   2) 會印 "Deprecated program name ... use /usr/bin/mariadb"，污染輸出。
#
# mysql 容器裡是原廠 client，而且 MYSQL_ROOT_PASSWORD 本來就在它的環境變數裡，
# 密碼完全不用經過 host 的行程列表。
_db_mysql() {
    local dbname line
    while IFS= read -r line; do
        [[ $line == DB_DATABASE=* ]] && dbname=${line#*=}
    done < <(_db_env)
    [[ -n ${dbname:-} ]] || cx_die "$EX_PRECOND" "讀不出 DB_DATABASE（compose config 失敗？）"
    # sh -c 'script' <$0> <$@...>：密碼只在容器內展開。
    cx_dc exec -T mysql sh -c \
        'exec mysql -h 127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD" "$@"' \
        pm-db "$dbname" "$@"
}

_db_wait() {
    local i=0
    cx_info "等待 $(cx_project_for "$CX_DC_MODE") 的 MySQL 就緒"
    until cx_dc_q exec -T mysql mysqladmin ping -h 127.0.0.1 --silent >/dev/null 2>&1; do
        i=$((i + 1))
        (( i >= 60 )) && cx_die "$EX_PRECOND" "等待 MySQL 逾時（60 × 2s）"
        sleep 2
    done
    cx_ok "MySQL 就緒"
}

_db_status() {
    local dbname line
    while IFS= read -r line; do
        [[ $line == DB_DATABASE=* ]] && dbname=${line#*=}
    done < <(_db_env)
    cx_step "$(cx_project_for "$CX_DC_MODE") 資料庫"
    cx_info "資料庫：${dbname:-?}"
    cx_info "資料表："
    _db_mysql -N -e "SHOW TABLES" 2>/dev/null | sed 's/^/    /' || cx_warn "查不到資料表（容器沒起來？）"
    cx_step "migration"
    cx_dc exec -T app php artisan migrate:status || true
}

_db_shell() {
    local dbname line
    while IFS= read -r line; do
        [[ $line == DB_DATABASE=* ]] && dbname=${line#*=}
    done < <(_db_env)
    if (( $# )); then
        _db_mysql -e "$*"
    else
        # 互動式：不能加 -T，tty 要接回來
        cx_dc exec mysql sh -c \
            'exec mysql -h 127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD" "$@"' \
            pm-db "$dbname"
    fi
}

_db_dump() {
    local out=${1:-}
    local dir="$CX_ROOT/reports/db"
    cx_ensure_host_dirs "$dir"
    if [[ -z $out ]]; then
        out="$dir/${CX_DC_MODE}-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"
    else
        out=$(cx_resolve "$out")
    fi

    local dbname line
    while IFS= read -r line; do
        [[ $line == DB_DATABASE=* ]] && dbname=${line#*=}
    done < <(_db_env)

    cx_info "mysqldump $dbname → $out"
    # --single-transaction：InnoDB 下不鎖表也能拿到一致快照。
    # --routines --triggers：預設不含，漏掉的話還原回來會少東西而且不會報錯。
    if (( CX_DRY_RUN )); then
        cx_dim "[dry-run] mysqldump $dbname > $out"
        return 0
    fi
    cx_dc_q exec -T mysql sh -c \
        "exec mysqldump --single-transaction --routines --triggers \
             -h 127.0.0.1 -uroot -p\"\$MYSQL_ROOT_PASSWORD\" --databases '$dbname'" \
        | gzip -9 > "$out" || { rm -f "$out"; cx_die "$EX_FAIL" "mysqldump 失敗"; }

    # 驗證封存 —— 壞掉的備份要現在就發現，不是還原的時候。
    gzip -t "$out" || cx_die "$EX_FAIL" "產生的 gz 檔壞掉：$out"
    cx_ok "$(du -h "$out" | cut -f1)  $out"
}

_db_restore() {
    local src=${1:-}
    [[ -n $src ]] || cx_die "$EX_USAGE" "cx db restore 需要 dump 檔路徑"
    src=$(cx_resolve "$src")
    [[ -f $src ]] || cx_die "$EX_PRECOND" "找不到 $src"

    local dbname line
    while IFS= read -r line; do
        [[ $line == DB_DATABASE=* ]] && dbname=${line#*=}
    done < <(_db_env)

    cx_confirm --danger "從 dump 還原資料庫" \
"來源  ：$src
目標  ：$(cx_project_for "$CX_DC_MODE") 的 $dbname

還原會**覆蓋**目標資料庫的現有內容。這個動作不可逆。
建議先跑 cx db dump 留一份現況。" || return "$EX_ABORT"

    cx_ask_typed "確認還原" \
"這會覆蓋 $(cx_project_for "$CX_DC_MODE") 的 $dbname。

請輸入 RESTORE ${CX_DC_MODE} 以確認。" "RESTORE ${CX_DC_MODE}" || return "$EX_ABORT"

    cx_info "還原中"
    if [[ $src == *.gz ]]; then
        gzip -dc "$src"
    else
        cat "$src"
    fi | cx_dc_q exec -T mysql sh -c \
        "exec mysql -h 127.0.0.1 -uroot -p\"\$MYSQL_ROOT_PASSWORD\"" \
        || cx_die "$EX_FAIL" "還原失敗"
    cx_ok "已還原"
}

_db_fresh() {
    cx_confirm --danger "重建資料庫 schema" \
"這會對 $(cx_project_for "$CX_DC_MODE") 執行：

    php artisan migrate:fresh --seed --force

**所有資料表會被 drop 再重建**，現有資料全部消失。
要保留資料請改用 cx db migrate。" || return "$EX_ABORT"

    cx_dc exec -T app php artisan migrate:fresh --seed --force
    # test 模式的一次性哨兵檔要一起清掉，否則 entrypoint 下次啟動時
    # 會以為「已經 fresh 過了」而跳過 —— 但也可能反過來，
    # 手動 fresh 之後留著哨兵檔才是對的。這裡選擇「更新它」，
    # 語意是「這個 volume 的 fresh 已經做過」，與 entrypoint 一致。
    cx_dc exec -T app sh -c \
        'date -u +%Y-%m-%dT%H:%M:%SZ > storage/.pm-db-fresh-done 2>/dev/null || true'
    cx_ok "完成"
}

_db_admin() {
    cx_step "建立 Filament 管理員"
    cx_dim "  Filament v5 的 make:filament-user 支援 --name --email --password；"
    cx_dim "  不給參數會互動詢問。"
    cx_dc exec app php artisan make:filament-user "$@"
}

# ═══ 原生路徑 ═══════════════════════════════════════════════════════════════
# docker 路徑打的是 compose 的 mysql 容器；原生路徑打的是
# backend/.env 指到的那台 MySQL（Ansible 部署出來的就是這種）。
# 兩條路各自獨立，不互相依賴。

# 連線設定的來源順序（後面的覆蓋前面的，但空值不算數）：
#
#   1. 專案根的 .env      —— 這個 repo 的真相。cx setup env 產生的隨機密碼在這裡，
#                            compose 也是從這裡把值餵進容器。
#   2. backend/.env       —— 真機部署的真相（Ansible 寫到 shared/.env）。
#                            但在 Docker 開發環境裡它的 DB_PASSWORD 是**空的** ——
#                            容器的密碼是 compose 從根 .env 注入的環境變數，
#                            不是寫在這個檔裡。所以空值必須略過，不能覆蓋掉根 .env。
#   3. CX_DB_HOST / CX_DB_PORT 環境變數 —— 臨時指定實際位置。
#
# 少了第 2 步的「空值不算數」，dev 環境會拿到空密碼，
# 而 MySQL 回的是 "Access denied ... (using password: NO)" ——
# 看起來像密碼錯了，其實是根本沒帶密碼。
_db_env_file_get() {
    local f=$1 k=$2
    [[ -f $f ]] || return 0
    sed -n "s/^[[:space:]]*${k}[[:space:]]*=[[:space:]]*//p" "$f" \
        | tail -1 | sed 's/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//'
}

_db_native_load() {
    local f_root="$CX_ROOT/.env" f_be="$CX_ROOT/backend/.env" v
    [[ -f $f_root || -f $f_be ]] || cx_die "$EX_PRECOND" \
        "找不到 .env 也找不到 backend/.env —— 原生路徑的連線設定從那裡讀（先跑 cx setup env）"

    _DBN_DATABASE=$(_db_env_file_get "$f_root" DB_DATABASE)
    _DBN_USERNAME=$(_db_env_file_get "$f_root" DB_USERNAME)
    _DBN_PASSWORD=$(_db_env_file_get "$f_root" DB_PASSWORD)
    _DBN_HOST=$(_db_env_file_get "$f_root" DB_HOST)
    _DBN_PORT=$(_db_env_file_get "$f_root" DB_PORT)

    local k
    for k in DATABASE USERNAME PASSWORD HOST PORT; do
        v=$(_db_env_file_get "$f_be" "DB_$k")
        [[ -n $v ]] && printf -v "_DBN_$k" '%s' "$v"
    done

    : "${_DBN_HOST:=127.0.0.1}"
    : "${_DBN_PORT:=3306}"
    [[ -n $_DBN_DATABASE ]] || cx_die "$EX_PRECOND" \
        "讀不到 DB_DATABASE（.env 與 backend/.env 都沒有）"
    _db_native_apply_override
    _db_native_assert_host
}

# ⚠ backend/.env 記的是「容器眼中的世界」：DB_HOST 通常是 mysql
# （compose 的 service 名），那個名字在 host 上解析不到。
#
# 所以原生路徑允許用環境變數覆寫，而且會在解析不到的時候把原因講清楚 ——
# 不講的話，Laravel 丟的是一大串 vendor stack trace，
# 最後一行也只說 "getaddrinfo for mysql failed"，沒有人會聯想到
# 「這個 .env 是給容器用的」。
#
#   CX_DB_HOST=127.0.0.1 CX_DB_PORT=3306  cx --runner native db status   # 打 dev 容器發布的埠
#   CX_DB_HOST=127.0.0.1 CX_DB_PORT=13306 cx --runner native db status   # test
#   （真機部署時 backend/.env 本來就是 127.0.0.1，不需要覆寫）
_db_native_apply_override() {
    [[ -n ${CX_DB_HOST:-} ]] && _DBN_HOST=$CX_DB_HOST
    [[ -n ${CX_DB_PORT:-} ]] && _DBN_PORT=$CX_DB_PORT
    return 0
}

# host 解析得到嗎？IP 直接放行，名字才需要問 getent。
_db_native_assert_host() {
    case $_DBN_HOST in
        *[!0-9.]*) : ;;      # 含非數字與點 → 是名字，往下檢查
        *) return 0 ;;        # 純數字與點 → 當成 IPv4，放行
    esac
    getent hosts "$_DBN_HOST" >/dev/null 2>&1 && return 0
    cx_error "host 解析不到 backend/.env 的 DB_HOST=$_DBN_HOST"
    cx_dim "  那個檔記的是「容器眼中的世界」——「$_DBN_HOST」是 compose 的 service 名，"
    cx_dim "  只有在容器網路裡才解析得到，host 上不存在。"
    cx_dim "  原生路徑請指定實際位置，例如打 dev 容器發布的埠："
    cx_dim "    CX_DB_HOST=127.0.0.1 CX_DB_PORT=3306 cx --runner native db status"
    cx_dim "  （真機部署時 backend/.env 本來就是 127.0.0.1，不需要覆寫）"
    cx_dim "  或改用容器路徑： cx --runner docker db status"
    exit "$EX_PRECOND"
}

_db_native_cnf() {
    local f
    f=$(mktemp "${TMPDIR:-/tmp}/cx-db-XXXXXX") || cx_die "$EX_FAIL" "無法建立暫存檔"
    chmod 600 "$f"
    {
        printf '[client]\n'
        printf 'host=%s\n'     "$_DBN_HOST"
        printf 'port=%s\n'     "$_DBN_PORT"
        printf 'user=%s\n'     "$_DBN_USERNAME"
        printf 'password=%s\n' "$_DBN_PASSWORD"
    } > "$f"
    printf '%s\n' "$f"
}

_db_mysql_native() {
    cx_runner_need_native "cx db" mysql
    _db_native_load
    local cnf; cnf=$(_db_native_cnf)
    local rc=0
    mysql --defaults-file="$cnf" "$_DBN_DATABASE" "$@" || rc=$?
    rm -f "$cnf"
    return "$rc"
}

_db_wait_native() {
    cx_runner_need_native "cx db wait" mysql
    _db_native_load
    local cnf; cnf=$(_db_native_cnf) i=0
    cx_info "等待 $_DBN_HOST:$_DBN_PORT 的 MySQL 就緒"
    until mysql --defaults-file="$cnf" -e 'SELECT 1' >/dev/null 2>&1; do
        i=$((i + 1))
        (( i >= 60 )) && { rm -f "$cnf"; cx_die "$EX_PRECOND" "等待 MySQL 逾時（60 × 2s）"; }
        sleep 2
    done
    rm -f "$cnf"
    cx_ok "MySQL 就緒"
}

_db_status_native() {
    _db_native_load
    cx_step "原生資料庫（backend/.env）"
    cx_info "連線：$_DBN_USERNAME@$_DBN_HOST:$_DBN_PORT／$_DBN_DATABASE"
    cx_info "資料表："
    _db_mysql_native -N -e "SHOW TABLES" 2>/dev/null | sed 's/^/    /' \
        || cx_warn "查不到資料表（連不上？跑 cx --runner native db wait）"
    cx_step "migration"
    _db_artisan_native migrate:status || true
}

# 原生的 artisan。與 cx art 的原生路徑同一套前置檢查，另外把解析好的連線設定
# 餵給 Laravel —— 因為 backend/.env 在 Docker 開發環境裡的 DB_PASSWORD 是空的
# （容器的密碼是 compose 注入的環境變數）。不餵的話 MySQL 回
#   Access denied for user 'pm'@'...' (using password: NO)
# 看起來像密碼錯，其實是根本沒帶密碼。
#
# Laravel 的 Dotenv 是 immutable 載入：**真實環境變數優先於 .env**，
# 所以這裡 export 就會生效。
#
# ⚠ 用 export 而不是 `env DB_PASSWORD=... php`：
# 命令列參數在 /proc/<pid>/cmdline 是全機器可讀的，
# 而環境變數在 /proc/<pid>/environ 只有同一個使用者讀得到。
# 同理也不會經過 cx_run 印出來。
_db_artisan_native() {
    cx_runner_need_native "cx db" php
    [[ -f $CX_ROOT/backend/vendor/autoload.php ]] || cx_die "$EX_PRECOND" \
        "backend/vendor 不存在 —— 先跑 cx --runner native composer install"
    _db_native_load
    (
        export DB_CONNECTION=mysql
        export DB_HOST="$_DBN_HOST"
        export DB_PORT="$_DBN_PORT"
        export DB_DATABASE="$_DBN_DATABASE"
        export DB_USERNAME="$_DBN_USERNAME"
        export DB_PASSWORD="$_DBN_PASSWORD"
        cd "$CX_ROOT/backend" && cx_run php artisan "$@"
    )
}

_db_shell_native() {
    if (( $# )); then
        _db_mysql_native -e "$*"
    else
        cx_runner_need_native "cx db shell" mysql
        _db_native_load
        local cnf; cnf=$(_db_native_cnf) rc=0
        # 互動式：不要吃掉 tty
        mysql --defaults-file="$cnf" "$_DBN_DATABASE" || rc=$?
        rm -f "$cnf"
        return "$rc"
    fi
}

_db_dump_native() {
    cx_runner_need_native "cx db dump" mysqldump
    _db_native_load
    local out=${1:-}
    if [[ -z $out ]]; then
        cx_ensure_host_dirs "$CX_ROOT/reports/db"
        out="$CX_ROOT/reports/db/native-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"
    else
        out=$(cx_resolve "$out")
    fi
    local cnf; cnf=$(_db_native_cnf) rc=0
    # 先寫 .part 再改名：中途失敗不會留下一個看起來完好的半截備份。
    mysqldump --defaults-file="$cnf" --single-transaction --quick \
              --routines --events --triggers --no-tablespaces \
              "$_DBN_DATABASE" 2>/dev/null | gzip -c > "$out.part" || rc=$?
    rm -f "$cnf"
    (( rc == 0 )) || { rm -f "$out.part"; cx_die "$EX_FAIL" "mysqldump 失敗（rc=$rc）"; }
    [[ -s $out.part ]] || { rm -f "$out.part"; cx_die "$EX_FAIL" "dump 是空的，已刪除"; }
    gzip -t "$out.part" || { rm -f "$out.part"; cx_die "$EX_FAIL" "gzip 完整性檢查失敗"; }
    mv -f "$out.part" "$out"
    cx_ok "已備份：$out（$(du -h "$out" | cut -f1)）"
}

# 原生的 fresh。閘門與容器路徑一致（紅線 2：任何刪除都要互動確認）。
# 額外把「目標是哪一台哪一個 schema」印出來 —— 原生路徑的目標可能是
# 一台真的伺服器，不像容器那樣一看模式就知道打到哪。
_db_fresh_native() {
    _db_native_load
    cx_confirm --danger "清空並重建資料庫（原生）" \
        "目標：$_DBN_USERNAME@$_DBN_HOST:$_DBN_PORT／$_DBN_DATABASE\n\n所有資料表會被丟棄後重建，資料不會保留。\n\n確定嗎？" \
        || return "$EX_ABORT"
    _db_artisan_native migrate:fresh --seed --force
}

cmd_db_main() {
    local sub=${1:-status}
    [[ $# -gt 0 ]] && shift
    case $sub in
        -h|--help|help) _db_usage; return 0 ;;
    esac

    # ── 原生路徑 ──────────────────────────────────────────────────────
    # 打的是 backend/.env 指到的那台 MySQL（Ansible 部署出來的就是這種），
    # 完全不碰 compose。刪除閘門在兩條路都一樣。
    if [[ $(cx_runner) == native ]]; then
        cx_runner_banner "host 工具 + .env／backend/.env 的連線設定"
        # 前置工具檢查要在這裡做，不能只放在各 helper 裡面：
        # helper 常常被包在 $(...) 或 pipeline 裡，那裡的 exit 只結束子 shell，
        # 於是流程照樣往下走，最後浮出來的是 127 command not found —— 
        # 完全看不出「其實只是沒裝 mysql client」。
        case $sub in
            status|shell|wait)  cx_runner_need_native "cx db $sub" mysql ;;
            dump)               cx_runner_need_native "cx db dump" mysqldump gzip ;;
            migrate|seed|admin|fresh) cx_runner_need_native "cx db $sub" php ;;
        esac
        case $sub in
            status)  _db_status_native ;;
            shell)   _db_shell_native "$@" ;;
            wait)    _db_wait_native ;;
            migrate) _db_artisan_native migrate --force ;;
            seed)    _db_artisan_native db:seed --force ;;
            admin)   _db_artisan_native make:filament-user ;;
            dump)    cx_lock db; _db_dump_native "${1:-}" ;;
            fresh)   cx_lock db; _db_fresh_native ;;
            restore) cx_die "$EX_USAGE" "restore 目前只有容器路徑；原生請自行 gunzip < 檔案 | mysql --defaults-file=... 並自行確認目標" ;;
            *) cx_error "未知的子指令：$sub"; _db_usage; return "$EX_USAGE" ;;
        esac
        return
    fi

    # ── 容器路徑 ──────────────────────────────────────────────────────
    cx_runner_need_docker "cx db（容器路徑）"
    cx_runner_banner "compose 的 mysql 容器"
    cx_compose_init "$CX_MODE"

    case $sub in
        status)  _db_status ;;
        shell)   _db_shell "$@" ;;
        wait)    _db_wait ;;
        migrate) cx_dc exec -T app php artisan migrate --force ;;
        seed)    cx_dc exec -T app php artisan db:seed --force ;;
        fresh)   cx_lock db; _db_fresh ;;
        dump)    cx_lock db; _db_dump "${1:-}" ;;
        restore) cx_lock db; _db_restore "${1:-}" ;;
        admin)   _db_admin "$@" ;;
        *) cx_error "未知的子指令：$sub"; _db_usage; return "$EX_USAGE" ;;
    esac
}
