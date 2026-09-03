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

_cx_dlg() { case $CX_UI in whiptail) whiptail "$@" ;; dialog) dialog "$@" ;; esac; }

cx_msg() {
    if cx_interactive; then
        _cx_dlg --title "$1" --msgbox "$2" 20 78 1>&8 2>&9
    else
        printf '\n=== %s ===\n%s\n\n' "$1" "$2" >&2
    fi
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
        printf '\n=== %s ===\n%s\n' "$title" "$body" >&2
        printf '輸入 y 繼續，其他任意鍵取消: ' >&2
        local a; read -r a </dev/tty || return 1
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
        printf '\n=== %s ===\n%s\n' "$title" "$body" >&2
        printf '請輸入 %s 以確認: ' "$expect" >&2
        read -r got </dev/tty || return 1
    else
        local f; f=$(mktemp)
        _cx_dlg --title "$title" --inputbox "$body" 16 92 "" 2>"$f" 1>&8 || { rm -f "$f"; return 1; }
        got=$(<"$f"); rm -f "$f"
    fi
    [[ $got == "$expect" ]] || { cx_error "確認字串不符（收到：${got:-<空>}）"; return 1; }
}
