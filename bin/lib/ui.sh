#!/usr/bin/env bash
# cx 互動介面：whiptail / dialog / 純文字三段式降級。
#
# 關鍵：whiptail 把 UI 畫在 stdout（--infobox 實測回傳 597 bytes 逸出序列，
# 這正是 3>&1 1>&2 2>&3 慣用法存在的原因）。一旦 stdout 被 tee 接走，
# 對話框會被寫進 log 檔，操作者面對的是凍結的空白畫面。
# 因此 cx_ui_init 必須在任何重導之前把真 tty 存到 fd 8/9。

CX_UI=${CX_UI:-auto}

cx_ui_init() {
    if [[ -z ${_CX_TTY_SAVED:-} ]]; then
        exec 8>&1 9>&2
        _CX_TTY_SAVED=1
    fi
    if [[ $CX_UI == auto ]]; then
        if   [[ -t 8 ]] && cx_have whiptail; then CX_UI=whiptail
        elif [[ -t 8 ]] && cx_have dialog;   then CX_UI=dialog
        else CX_UI=plain
        fi
    fi
}

cx_interactive() { [[ -t 8 ]] && [[ $CX_UI != plain ]]; }

# 沒有 *) 分支的話，非法的 CX_UI 會讓這個函式「什麼都不做並回傳 0」，
# 而回傳 0 在 cx_confirm 眼中就是「使用者按了 Yes」。
_cx_dlg() {
    case $CX_UI in
        whiptail) whiptail "$@" ;;
        dialog)   dialog "$@" ;;
        *) cx_error "內部錯誤：_cx_dlg 在 CX_UI=$CX_UI 下被呼叫"; return 1 ;;
    esac
}

# whiptail 的訊息裡用 \n 表示換行；純文字模式要自己解讀，
# 否則使用者會看到字面的 "\n" 而不是換行。
_cx_unescape() { printf '%b' "$1"; }

cx_msg() {
    if cx_interactive; then
        _cx_dlg --title "$1" --msgbox "$2" 20 78 1>&8 2>&9
    else
        printf '\n=== %s ===\n' "$1" >&2
        _cx_unescape "$2" >&2; printf '\n\n' >&2
    fi
}

# 有沒有可讀的 tty 可以拿來問問題。
# 必須在子 shell 裡探測：直接 exec 7</dev/tty 失敗時，bash 會自己把
# "No such device or address" 印到 stderr，2>/dev/null 蓋不住（重導在錯誤發生前就套用了）。
# 「/dev/tty 開得起來」不等於「有人在那一端」。WSL 底下即使整個 session
# 完全非互動（例如 wsl.exe -- bash -s < script），/dev/tty 一樣開得起來，
# 於是 read </dev/tty 會**永遠卡住**而不是失敗 —— 沒有輸出、沒有錯誤，
# 看起來就像指令當掉了（實測：cx git push --force 卡了 6 分鐘無任何輸出）。
# 所以所有 read 都加逾時，把「無限等待」變成「明確取消」。
# 逾時往取消的方向倒，不會有「等太久就自動同意」這種事。
CX_ASK_TIMEOUT=${CX_ASK_TIMEOUT:-120}
_cx_can_ask() { ( exec </dev/tty ) >/dev/null 2>&1; }
_cx_read_tty() {  # _cx_read_tty <變數名>
    local __v=$1 __x
    if read -r -t "$CX_ASK_TIMEOUT" __x </dev/tty; then
        printf -v "$__v" %s "$__x"
        return 0
    fi
    printf '\n' >&2
    cx_error "等待輸入逾時（${CX_ASK_TIMEOUT}s）或讀不到終端機 —— 已取消"
    cx_dim "  非互動環境請加 --yes（僅在你確定要跳過確認時）"
    return 1
}

cx_confirm() {
    local danger=0
    [[ ${1:-} == --danger ]] && { danger=1; shift; }
    local title=$1 body=$2

    if (( ${CX_ASSUME_YES:-0} )); then
        cx_warn "[--yes] 自動確認：$title"
        return 0
    fi
    if ! cx_interactive; then
        printf '\n=== %s ===\n' "$title" >&2
        _cx_unescape "$body" >&2; printf '\n' >&2
        if ! _cx_can_ask; then
            cx_error "沒有可用的終端機，無法確認 —— 已取消"
            cx_dim "  非互動環境請加 --yes（僅在你確定要跳過確認時）"
            return 1
        fi
        printf '輸入 y 繼續，其他任意鍵取消: ' >&2
        local a; _cx_read_tty a || return 1
        [[ $a == [Yy]* ]]
        return
    fi
    local -a args=(--title "$title" --yesno "$body" 24 92)
    (( danger )) && args+=(--defaultno)
    _cx_dlg "${args[@]}" 1>&8 2>&9
}

cx_ask_typed() {
    local title=$1 body=$2 expect=$3 got=''
    if (( ${CX_ASSUME_YES:-0} )); then
        cx_warn "[--yes] 略過確認字串輸入（預期：$expect）"
        return 0
    fi
    if ! cx_interactive; then
        printf '\n=== %s ===\n' "$title" >&2
        _cx_unescape "$body" >&2; printf '\n' >&2
        if ! _cx_can_ask; then
            cx_error "沒有可用的終端機，無法輸入確認字串 —— 已取消"
            return 1
        fi
        printf '請輸入 %s 以確認: ' "$expect" >&2
        _cx_read_tty got || return 1
    else
        local f; f=$(mktemp)
        _cx_dlg --title "$title" --inputbox "$body" 16 92 "" 2>"$f" 1>&8 || { rm -f "$f"; return 1; }
        got=$(<"$f"); rm -f "$f"
    fi
    [[ $got == "$expect" ]] || { cx_error "確認字串不符（收到：${got:-<空>}）"; return 1; }
}
