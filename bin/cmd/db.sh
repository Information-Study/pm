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
    # 這樣 docker/env/<mode>.env 的覆寫才會被算進去。
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
    cx_info "等待 pm_${CX_DC_MODE} 的 MySQL 就緒"
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
    cx_step "pm_${CX_DC_MODE} 資料庫"
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
目標  ：pm_${CX_DC_MODE} 的 $dbname

還原會**覆蓋**目標資料庫的現有內容。這個動作不可逆。
建議先跑 cx db dump 留一份現況。" || return "$EX_ABORT"

    cx_ask_typed "確認還原" \
"這會覆蓋 pm_${CX_DC_MODE} 的 $dbname。

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
"這會對 pm_${CX_DC_MODE} 執行：

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

cmd_db_main() {
    local sub=${1:-status}
    [[ $# -gt 0 ]] && shift
    case $sub in
        -h|--help|help) _db_usage; return 0 ;;
    esac

    cx_docker_need
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
