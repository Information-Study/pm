#!/usr/bin/env bats
# ⑩ 對話框尺寸：不可以寫死，必須夾到終端機裝得下的範圍
#
# 2026-09-06 使用者回報：TUI 的 deploy 選單出現「選單畫不出來」兩次。
# 根因是尺寸全部寫死：
#   * _tui_menu 固定 `22 76 12` —— 不看項目數也不看終端機。
#     Git 選單這一輪加到 13 項（超過清單高度 12），deploy 正好 12 項卡在邊界，
#     而終端機只要低於 22 列，22 列的對話框就畫不出來。
#   * msgbox / yesno / inputbox 有 24×92、20×90、16×92 —— 80 欄的終端機
#     （最常見的預設）根本放不下 92 欄。
#
# whiptail 畫不出來時回的不是 0/1/255，於是 _cx_dlg 判成「後端壞了」（rc=2），
# 使用者看到的就是「選單畫不出來 —— 這不是『你按了離開』」。而回到上一層選單時
# 往往再壞一次 —— 這正是那則訊息出現兩次的原因。
#
# 沒有 tty 時 _cx_fit / _tui_menu_geom 會退回保守的 24×80，所以這些案例
# 在 bats 裡是確定性的。

setup() {
    load helpers/common
    load helpers/fixture
}

# ⚠ 不可以直接 source 進 bats：common.sh 用 readonly 定義 EX_*，
#   而 helpers/common 已經載過一次 —— 重複 source 會在第 4 行就失敗。
#   改成在子行程裡跑，順便確保拿到的是「沒有 tty」的那條退路（24×80）。
geom() {                            # geom <函式名> <參數...>
    env -u BATS_TEST_NAME CX_ROOT="$CX_TEST_REAL_ROOT" bash -c '
        set -uo pipefail
        . "$CX_ROOT/bin/lib/common.sh"
        . "$CX_ROOT/bin/lib/ui.sh"
        . "$CX_ROOT/bin/cmd/tui.sh"
        f=$1; shift; "$f" "$@"
    ' _ "$@" 2>/dev/null
}

@test "_cx_fit 把超過終端機寬度的對話框夾回來" {
    # 沒有 tty → 退回 24×80；92 欄放不下，要被夾到 78（留 2 欄邊界）
    run geom _cx_fit 24 92
    assert_rc 0
    [ "$output" = "24 78" ] || _fail_with "期望 '24 78'，得到 '$output'"
}

@test "_cx_fit 不會把裝得下的尺寸改小" {
    run geom _cx_fit 20 76
    assert_rc 0
    [ "$output" = "20 76" ] || _fail_with "期望 '20 76'，得到 '$output'"
}

@test "_cx_fit 有下限 —— 不會算出畫不出來的尺寸" {
    run geom _cx_fit 1 1
    assert_rc 0
    local h w; read -r h w <<< "$output"
    [ "$h" -ge 7 ]  || _fail_with "高度 $h 太小"
    [ "$w" -ge 40 ] || _fail_with "寬度 $w 太小"
}

@test "_tui_menu_geom 的清單高度會跟著項目數長，不再固定 12" {
    # 這是 Git 選單（13 項）原本畫不出全部的原因
    run geom _tui_menu_geom 13
    assert_rc 0
    local h w listh; read -r h w listh <<< "$output"
    [ "$listh" -eq 13 ] || _fail_with "13 項的清單高度應該是 13，得到 $listh"
    [ "$h" -gt 13 ]     || _fail_with "對話框高度 $h 必須大於清單高度"
}

@test "_tui_menu_geom 不會要求超過終端機的高度" {
    # 沒有 tty → 24 列。對話框高度不可以超過它（原本固定 22，終端機 20 列就爆）
    local n
    for n in 4 11 12 13 30; do
        run geom _tui_menu_geom "$n"
        assert_rc 0
        local h w listh; read -r h w listh <<< "$output"
        [ "$h" -le 24 ] || _fail_with "$n 項時算出高度 $h，超過終端機的 24 列"
        [ "$w" -le 78 ] || _fail_with "$n 項時算出寬度 $w，超過 80 欄終端機能給的 78"
        [ "$listh" -ge 3 ] || _fail_with "$n 項時清單高度 $listh 太小"
    done
}

@test "選單項目再多也不會超過終端機 —— 多的用捲動" {
    run geom _tui_menu_geom 40
    assert_rc 0
    local h w listh; read -r h w listh <<< "$output"
    [ "$h" -le 24 ]     || _fail_with "高度 $h 超過終端機"
    [ "$listh" -lt 40 ] || _fail_with "40 項不可能全部塞進 24 列，清單高度應被夾小"
}

@test "程式碼裡不可以再出現寫死、且超過 80 欄的對話框尺寸" {
    # 這一條是防止復發：寬度寫死比高度更危險 —— 高度不夠只是擠，
    # 寬度不夠是 whiptail 直接畫不出來。
    local hits
    hits=$(grep -rnE -- '--(menu|msgbox|yesno|inputbox)[^0-9]*"? [0-9]+ (8[1-9]|9[0-9]|[0-9]{3})' \
        "$CX_TEST_REAL_ROOT/bin/cmd/tui.sh" "$CX_TEST_REAL_ROOT/bin/lib/ui.sh" || true)
    [ -z "$hits" ] || _fail_with "還有寫死且超過 80 欄的尺寸：$hits"
}
