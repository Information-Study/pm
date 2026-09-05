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
        return 0
    fi
    # ⚠ 明確指定的後端**必須存在**，不存在就要當場講清楚。
    #
    #   2026-09-05 實測：`cx --ui dialog tui` 在沒裝 dialog 的機器上
    #   **完全沒有輸出、而且 exit 0**。原因是 _cx_dlg 執行 `dialog` 得到 127，
    #   _tui_menu 的 `if _cx_dlg …; then` 為假 → 回傳 1 →
    #   cmd_tui_main 的 while 迴圈當成「使用者選了離開」→ 正常結束。
    #
    #   使用者看到的是一個什麼都不做、也不抱怨的指令 —— 於是合理地推論
    #   「選單裡沒有那些功能」。本專案回報的「沒有 acl 選單」「沒有 git pull」
    #   「執行錯誤時沒有錯誤訊息」三件事，根因都是這一個。
    case $CX_UI in
        whiptail|dialog)
            cx_have "$CX_UI" && return 0
            cx_error "指定了 --ui $CX_UI，但這台機器上找不到 $CX_UI"
            cx_dim "  安裝： sudo apt install $([[ $CX_UI == whiptail ]] && echo whiptail || echo dialog)"
            cx_dim "  或改用純文字介面： cx --ui plain <動詞>"
            return 1 ;;
        plain) return 0 ;;
        *)  cx_error "未知的 --ui 值：$CX_UI（可用：auto whiptail dialog plain）"
            return 1 ;;
    esac
}

cx_interactive() { [[ -t 8 ]] && [[ $CX_UI != plain ]]; }

# 沒有 *) 分支的話，非法的 CX_UI 會讓這個函式「什麼都不做並回傳 0」，
# 而回傳 0 在 cx_confirm 眼中就是「使用者按了 Yes」。
#
# ⚠ 退出碼有三種意義，混在一起就會變成「安靜地什麼都不做」：
#     0        使用者按了 OK / Yes
#     1        使用者按了 Cancel / No          ← 使用者的選擇
#     255      使用者按了 ESC                  ← 使用者的選擇
#     其他     **後端自己壞了**（127 = 沒安裝、其他 = 畫不出來）
#   最後那一類原本與 Cancel 無法區分，於是後端一壞，整個選單就變成
#   「按了取消」→ 迴圈結束 → exit 0 → 使用者面前一片空白。
_cx_dlg() {
    local rc=0
    case $CX_UI in
        whiptail) whiptail "$@" || rc=$? ;;
        dialog)   dialog "$@"   || rc=$? ;;
        *) cx_error "內部錯誤：_cx_dlg 在 CX_UI=$CX_UI 下被呼叫"; return 2 ;;
    esac
    if (( rc != 0 && rc != 1 && rc != 255 )); then
        cx_error "$CX_UI 執行失敗（exit $rc）—— 這不是「取消」，是介面後端壞了"
        if (( rc == 127 )); then
            cx_dim "  找不到 $CX_UI。安裝它，或改用純文字介面： cx --ui plain <動詞>"
        else
            cx_dim "  常見原因：終端機太小、TERM 設定不對、或在沒有 TTY 的環境"
            cx_dim "  改用純文字介面： cx --ui plain <動詞>"
        fi
        return 2                    # 2 = 後端壞掉，與 1（使用者取消）分開
    fi
    return "$rc"
}

# whiptail 的訊息裡用 \n 表示換行；純文字模式要自己解讀，
# 否則使用者會看到字面的 "\n" 而不是換行。
_cx_unescape() { printf '%b' "$1"; }

# 把對話框尺寸夾到終端機裝得下的範圍。
#
# 本檔與 tui.sh 原本把 24×92、20×90、16×92 這類尺寸寫死。80 欄的終端機
# （最常見的預設）根本放不下 92 欄，而 whiptail 畫不出來時回的不是 0/1/255，
# 於是 _cx_dlg 會判成「後端壞了」，使用者看到的是「選單畫不出來」。
# 寬度寫死比高度更危險：高度不夠通常只是擠，寬度不夠是直接失敗。
_cx_fit() {                         # _cx_fit <想要的高> <想要的寬> → "高 寬"
    local h=$1 w=$2 rows=24 cols=80 sz
    sz=$(stty size </dev/tty 2>/dev/null) && [[ $sz =~ ^[0-9]+\ [0-9]+$ ]] \
        && { rows=${sz% *}; cols=${sz#* }; }
    (( h > rows )) && h=$rows
    (( w > cols - 2 )) && w=$(( cols - 2 ))
    (( h < 7 ))  && h=7
    (( w < 40 )) && w=40
    printf '%d %d' "$h" "$w"
}

cx_msg() {
    if cx_interactive; then
        local _h _w; read -r _h _w < <(_cx_fit 20 78)
        _cx_dlg --title "$1" --msgbox "$2" "$_h" "$_w" 1>&8 2>&9
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
    local _h _w; read -r _h _w < <(_cx_fit 24 92)
    local -a args=(--title "$title" --yesno "$body" "$_h" "$_w")
    (( danger )) && args+=(--defaultno)
    local rc=0
    _cx_dlg "${args[@]}" 1>&8 2>&9 || rc=$?
    # rc=2 是「後端壞了」不是「使用者說不要」。對確認閘門來說兩者都該擋下
    #（fail closed），但訊息不能一樣 —— 否則使用者會以為是自己按錯。
    # _cx_dlg 已經印過原因，這裡補一句把它跟「取消」分開。
    if (( rc >= 2 )); then
        cx_error "無法顯示確認對話框 —— 當作「否」處理（這不是你按的）"
        return 1
    fi
    return "$rc"
}

# 取一行輸入。三段式降級與其他 cx_* 一致：whiptail/dialog → 純文字 → 失敗。
#
# 與 cx_ask_typed 的差別：那個是「打對字串才放行」的確認閘門，這個是單純問一個值。
# 與 tui.sh 的 _tui_ask 的差別：那支只在選單裡用得到（它直接寫 fd8），
# 而 cx git config 這種動詞在命令列與選單兩邊都會被呼叫。
#
# 回傳 0 並把值印到 stdout；使用者取消或沒有終端機則回傳 1。
cx_ask_line() {                     # cx_ask_line <標題> <提示> [預設值]
    local title=$1 body=$2 def=${3:-} got=''
    if ! cx_interactive; then
        if ! _cx_can_ask; then
            cx_error "沒有可用的終端機，無法輸入「$title」"
            return 1
        fi
        printf '\n=== %s ===\n' "$title" >&2
        _cx_unescape "$body" >&2
        [[ -n $def ]] && printf '（直接按 Enter 用預設值：%s）' "$def" >&2
        printf '\n> ' >&2
        _cx_read_tty got || return 1
        [[ -z $got && -n $def ]] && got=$def
    else
        local f rc=0; f=$(mktemp)
        local _h _w; read -r _h _w < <(_cx_fit 12 88)
        _cx_dlg --title "$title" --inputbox "$body" "$_h" "$_w" "$def" 2>"$f" 1>&8 || rc=$?
        if (( rc )); then
            rm -f "$f"
            # 與 cx_confirm 同一個理由：後端壞掉不是「使用者取消」。
            (( rc >= 2 )) && cx_error "無法顯示輸入框 —— 這不是你按了取消"
            return 1
        fi
        got=$(<"$f"); rm -f "$f"
    fi
    [[ -n $got ]] || return 1
    printf '%s' "$got"
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
        local _h _w; read -r _h _w < <(_cx_fit 16 92)
        _cx_dlg --title "$title" --inputbox "$body" "$_h" "$_w" "" 2>"$f" 1>&8 || { rm -f "$f"; return 1; }
        got=$(<"$f"); rm -f "$f"
    fi
    [[ $got == "$expect" ]] || { cx_error "確認字串不符（收到：${got:-<空>}）"; return 1; }
}

# ── 用系統的瀏覽器開一個網址 ───────────────────────────────────────────────
#
# 依序試：WSL 用 wslview（Windows 的預設瀏覽器）、Linux 用 xdg-open、
# macOS 用 open、最後才是直接叫 explorer.exe。
#
# 這段原本只長在 bin/cmd/pma.sh 裡。cx open 出現之後有兩個地方要開瀏覽器，
# 而「WSL 上怎麼開瀏覽器」不應該有兩份 —— 那種東西會各自演化然後只有一邊
# 支援新的啟動器。
#
# 回傳 0 = 開了（或至少叫到了啟動器）；非 0 = 找不到任何啟動器。
cx_browse() {                       # cx_browse <url>
    local url=${1:?cx_browse 需要網址} opener
    for opener in wslview xdg-open open explorer.exe; do
        if cx_have "$opener"; then
            cx_run "$opener" "$url" >/dev/null 2>&1 || true
            return 0
        fi
    done
    return 1
}
