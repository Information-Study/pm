#!/usr/bin/env bash
# cx pma — 開啟 phpMyAdmin。
#
# phpMyAdmin 在 dev 與 test 兩個模式的 compose 裡；prod 刻意沒有（D13）。
# 這個動詞負責三件事，缺一個都會讓人卡住：
#   1. 擋掉 prod（在那裡打這個指令要講清楚為什麼沒有）
#   2. 確認容器真的在跑（沒跑就給出啟動指令，而不是叫使用者自己看 docker ps）
#   3. 從**合併後**的 compose 設定讀出實際發布的埠，而不是寫死 8891
#      —— docker/env/dev.env 可以覆寫，寫死就會給出錯的網址

_pma_usage() {
    cat >&2 <<'TXT'
用法：cx pma [--no-open] [--url]

  （無參數）    確認容器在跑，印出網址並嘗試用瀏覽器開啟
  --url         只印出網址（給腳本用，不開瀏覽器）
  --no-open     印出網址與狀態，但不開瀏覽器

phpMyAdmin 只在 dev 模式提供（test / prod 刻意不放管理介面）。
登入資訊來自 .env 的 DB_USERNAME / DB_PASSWORD。
TXT
}

# 從合併後的 compose 設定撈 phpmyadmin 實際發布的 host 埠。
_pma_port() {
    cx_dc_q config --format json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
svc = (d.get("services") or {}).get("phpmyadmin") or {}
for p in (svc.get("ports") or []):
    pub = p.get("published") if isinstance(p, dict) else None
    if pub:
        print(pub); break
'
}

cmd_pma_main() {
    local open=1 url_only=0
    while (( $# )); do
        case $1 in
            -h|--help) _pma_usage; return 0 ;;
            --url)     url_only=1; open=0; shift ;;
            --no-open) open=0; shift ;;
            *) cx_die "$EX_USAGE" "pma: 未知參數 $1" ;;
        esac
    done

    # dev 與 test 都有 phpMyAdmin；prod 刻意沒有（D13）。
    # test 那一份是 2026-09-05 補的 —— 原始規格本來就要求，只是 service
    # 一直沒被寫出來（而 docker/env/test.env 的 PHPMYADMIN_PORT 早就預留著）。
    if [[ $CX_MODE == prod ]]; then
        cx_error "prod 刻意不提供 phpMyAdmin"
        cx_dim "  管理介面是額外的攻擊面，而且 prod 的 MySQL 根本不發布埠。"
        cx_dim "  要看 prod 的資料庫請用： cx --mode prod db shell"
        return "$EX_USAGE"
    fi

    cx_runner_need_docker "cx pma"
    cx_compose_init "$CX_MODE"

    local port; port=$(_pma_port)
    [[ -n ${port:-} ]] || { [[ $CX_MODE == test ]] && port=18891 || port=8891; }
    local url="http://127.0.0.1:${port}"

    if (( url_only )); then printf '%s\n' "$url"; return 0; fi

    # 容器沒跑就講清楚怎麼起，不要只丟一個開不起來的網址
    if ! cx_dc_q ps --status running --services 2>/dev/null | grep -qx phpmyadmin; then
        cx_warn "phpmyadmin 容器沒在跑"
        cx_dim "  啟動： cx dev up -d"
        cx_dim "  只起這一個： cx dev dc up -d phpmyadmin"
        cx_dim "  起來之後的網址： $url"
        return "$EX_PRECOND"
    fi

    cx_ok "phpMyAdmin：$url"
    local u p
    u=$(sed -n 's/^[[:space:]]*DB_USERNAME[[:space:]]*=[[:space:]]*//p' "$CX_ROOT/.env" 2>/dev/null | tail -1)
    p=$(sed -n 's/^[[:space:]]*DB_PASSWORD[[:space:]]*=[[:space:]]*//p' "$CX_ROOT/.env" 2>/dev/null | tail -1)
    cx_dim "  帳號： ${u:-<看 .env 的 DB_USERNAME>}"
    # 密碼不直接印出來 —— 終端機會留在 scrollback 與 tmux buffer 裡。
    cx_dim "  密碼： .env 的 DB_PASSWORD（${#p} 字元）；要看： grep ^DB_PASSWORD= .env"
    cx_dim "  root： root / .env 的 MYSQL_ROOT_PASSWORD"

    (( open )) || return 0
    # 依序試：WSL 用 Windows 的 explorer，Linux 用 xdg-open，macOS 用 open。
    local opener
    for opener in wslview xdg-open open explorer.exe; do
        if cx_have "$opener"; then
            cx_run "$opener" "$url" >/dev/null 2>&1 || true
            return 0
        fi
    done
    cx_dim "  找不到瀏覽器啟動器（wslview / xdg-open / open），請自行開啟上面的網址"
}
