#!/usr/bin/env bash
# cx code — 用 VS Code 開啟專案。
#
# 為什麼需要一個動詞而不是叫大家自己打 `code .`：
#   1. 從子目錄執行時 `code .` 開的是子目錄，不是專案根。cx 一律開 $CX_ROOT。
#   2. WSL 裡的 `code` 是 Windows 那支透過 wslpath 轉出來的 shim，
#      不一定在 PATH 上；找不到時要給出可行動的訊息，而不是 command not found。
#   3. 順手支援開單一檔案／子目錄，路徑以「呼叫者的 cwd」解析。

_code_usage() {
    cat >&2 <<'TXT'
用法：cx code [路徑] [--] [VS Code 參數...]

  （無參數）      開啟專案根目錄
  <路徑>          開啟指定檔案或目錄（相對路徑以你所在的位置解析）
  -n, --new-window  開新視窗
  -r, --reuse-window 重用現有視窗
  -w, --wait      等到視窗關閉才返回

例
  cx code                       # 開專案根
  cx code backend               # 開 backend/
  cx code docs/manual.md        # 開單一檔案
  cx code -n                    # 開新視窗
TXT
}

# VS Code 的執行檔在不同環境名字不一樣。依序找：
#   code        一般 Linux／WSL（有裝 Remote 擴充時 Windows 會注入這支）
#   code-insiders
#   codium      VSCodium
_code_bin() {
    local b
    for b in "${CX_CODE_BIN:-}" code code-insiders codium; do
        [[ -n $b ]] && cx_have "$b" && { printf '%s\n' "$b"; return 0; }
    done
    return 1
}

cmd_code_main() {
    local target='' passthru=()
    while (( $# )); do
        case $1 in
            -h|--help) _code_usage; return 0 ;;
            --) shift; passthru+=("$@"); break ;;
            -*) passthru+=("$1"); shift ;;
            *)  [[ -z $target ]] && { target=$1; shift; } || { passthru+=("$1"); shift; } ;;
        esac
    done

    local bin
    if ! bin=$(_code_bin); then
        cx_error "找不到 VS Code 的執行檔（試過 code / code-insiders / codium）"
        cx_dim "  WSL：在 Windows 端的 VS Code 安裝「WSL」擴充，之後 code 會自動出現在 PATH"
        cx_dim "  Linux：安裝 VS Code，或用 CX_CODE_BIN 指定執行檔名稱"
        cx_dim "  也可以直接開： $CX_ROOT"
        return "$EX_PRECOND"
    fi

    # 沒給路徑就開專案根；給了相對路徑則以「呼叫者的 cwd」解析，
    # 不是以 CX_ROOT 解析 —— cd 到 backend/ 之後打 cx code . 應該開 backend/。
    local path
    if [[ -z $target ]]; then
        path=$CX_ROOT
    else
        path=$(cx_resolve "$target")
        [[ -e $path ]] || cx_die "$EX_USAGE" "路徑不存在：$target"
    fi

    cx_info "$bin $path"
    # VS Code 會 fork 到背景；不要等它，也不要讓它的輸出污染終端機。
    cx_run "$bin" "${passthru[@]}" "$path" >/dev/null 2>&1 || {
        cx_error "$bin 啟動失敗"
        return "$EX_FAIL"
    }
    cx_ok "已開啟 $path"
}
