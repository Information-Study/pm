#!/usr/bin/env bash
# cx open — 開啟這個專案的服務網址。
#
# 為什麼要有這個動詞：埠段是每個模式一組（env/docker/compose/<mode>.env），而且可以
# 被覆寫。要看前端在哪，得先知道自己在哪個模式、再去翻那個檔 —— 而人記不住
# dev 是 8080、test 是 18080，於是每次都去 docker ps 找。
#
# ⚠ 這支程式**刻意沒有自己的埠推導邏輯**給 pma 與 sonar：
#   * pma  → cmd_pma_main --url（那邊已經有從**合併後的 compose** 讀實際發布
#            埠的邏輯、prod 的刻意拒絕（D13）、以及容器沒跑時的指路）
#   * sonar → cmd_sonar_main url（那邊有 _sonar_port）
#   複製那兩段的代價是它們會各自演化：改了 pma.sh 的埠推導而沒改這裡，
#   cx pma 與 cx open pma 就會給出不同的網址，而且沒有人會發現。
#   bin/test/78_open.bats 有一條案例專門盯這件事（兩者輸出必須完全相同）。

_open_usage() {
    cat >&2 <<'TXT'
用法：cx open [目標] [--url] [--no-open]

  目標（不給就是 list）
    front         前端入口（edge）
    back          Filament 後台（/admin）
    api           Laravel 健康檢查（/up）
    pma           phpMyAdmin（dev 與 test；prod 刻意沒有）
    sonar         SonarQube（常駐服務，見 cx sonar）
    list          全部印出來，不開瀏覽器

  旗標
    --url         只印網址，不開瀏覽器（給腳本用）
    --no-open     印出網址與說明，但不開瀏覽器

網址依目前的模式決定 —— 埠段來自 env/docker/compose/<模式>.env。
要看別的模式：cx --mode test open front（模式是全域旗標，不是這個動詞的參數）。
TXT
}

# edge 的 host 埠。來源與 cx verify 的 ep-* 檢查、cx dev up 的埠摘要同一個檔。
_open_edge_port() {
    local f="$CX_ROOT/env/docker/compose/${CX_MODE}.env" p
    p=$(grep -E '^EDGE_HTTP_PORT=' "$f" 2>/dev/null | cut -d= -f2)
    printf '%s' "${p:-80}"
}

_open_base_url() { printf 'http://localhost:%s' "$(_open_edge_port)"; }

# 目標 → 網址。pma 與 sonar 委派給既有的動詞，不自己算。
_open_url_of() {                    # _open_url_of <目標>
    case $1 in
        front) _open_base_url; printf '\n' ;;
        back)  printf '%s/admin\n' "$(_open_base_url)" ;;
        api)   printf '%s/up\n'    "$(_open_base_url)" ;;
        pma)   . "$CX_ROOT/bin/cmd/pma.sh";   cmd_pma_main --url ;;
        sonar) . "$CX_ROOT/bin/cmd/sonar.sh"; cmd_sonar_main url ;;
        *)     return "$EX_USAGE" ;;
    esac
}

_open_list() {
    cx_step "服務網址（模式：$CX_MODE）"
    local t url
    for t in front back api; do
        url=$(_open_url_of "$t")
        printf '  %-7s %s\n' "$t" "$url"
    done
    # pma 在 prod 會拒絕、sonar 可能沒起來 —— 兩者都不該讓整份清單失敗。
    if url=$(_open_url_of pma 2>/dev/null) && [[ -n $url ]]; then
        printf '  %-7s %s\n' pma "$url"
    else
        printf '  %-7s %s\n' pma "（$CX_MODE 模式沒有；prod 刻意不放管理介面，D13）"
    fi
    if url=$(_open_url_of sonar 2>/dev/null) && [[ -n $url ]]; then
        printf '  %-7s %s（要先 cx sonar up）\n' sonar "$url"
    fi
}

cmd_open_main() {
    local target='' open=1 url_only=0
    while (( $# )); do
        case $1 in
            -h|--help) _open_usage; return 0 ;;
            --url)     url_only=1; open=0; shift ;;
            --no-open) open=0; shift ;;
            front|back|api|pma|sonar|list) target=$1; shift ;;
            -*) cx_die "$EX_USAGE" "open: 未知旗標 $1（試試 cx open --help）" ;;
            *)  cx_die "$EX_USAGE" "open: 未知目標 $1（front|back|api|pma|sonar|list）" ;;
        esac
    done
    target=${target:-list}

    if [[ $target == list ]]; then _open_list; return 0; fi

    # pma 有自己的前置檢查（prod 拒絕、容器沒跑時指路），要讓它的退出碼傳出來。
    if [[ $target == pma && $url_only -eq 0 ]]; then
        . "$CX_ROOT/bin/cmd/pma.sh"
        local -a a=(); (( open )) || a+=(--no-open)
        cmd_pma_main "${a[@]+"${a[@]}"}"
        return $?
    fi

    local url; url=$(_open_url_of "$target") \
        || cx_die "$EX_USAGE" "open: 未知目標 $target"
    [[ -n $url ]] || cx_die "$EX_PRECOND" "$target 目前沒有網址（服務可能沒起來）"

    if (( url_only )); then printf '%s\n' "$url"; return 0; fi
    cx_ok "$target：$url"
    (( open )) || return 0
    cx_browse "$url" \
        || cx_dim "  找不到瀏覽器啟動器（wslview / xdg-open / open），請自行開啟上面的網址"
}
