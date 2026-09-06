#!/usr/bin/env bats
# ⑬ TUI 的執行期行為 —— 選單真的畫得出來嗎
#
# TUI-resolve 與 TUI-coverage 是**靜態 regex 剖析**。它們證明得了
# 「選單項目指得到真的動詞」與「三個模式的聯集涵蓋每個動詞」，
# 但證明不了「這個選單真的畫得出來」——
# 2026-09-05 的 commit 16d28ba（對話框尺寸寫死）就是一個所有靜態檢查
# 都全綠、而選單畫不出來的缺陷。
#
# 這個檔補的就是那一半：在真 pty 裡把選單跑起來，比對畫面上的文字。

setup() {
    load helpers/common
    load helpers/fixture
    make_root tuirun >/dev/null
    command -v whiptail >/dev/null || skip "需要 whiptail"
    command -v script   >/dev/null || skip "需要 script（util-linux）"
}

@test "主選單畫得出來，而且 ESC 之後乾淨離開" {
    tui_screen
    [ "$TUI_RC" -eq 0 ] || _fail_with "選單沒有正常離開（rc=$TUI_RC）"
    [[ $TUI_TEXT == *"專案管理"* ]]   || _fail_with "畫面上沒有標題：$TUI_TEXT"
    [[ $TUI_TEXT == *"選擇一項"* ]]   || _fail_with "畫面上沒有選單提示"
    [[ $TUI_TEXT == *"現況一覽"* ]]   || _fail_with "畫面上沒有第一個項目"
}

# ── 模式門檻：靜態剖析證明不了的那一半 ────────────────────────────────────
#
# check_tui 看不到 $_TUI_MODE，所以它只能驗「三個模式的聯集」。
# 「dev 模式下實際畫出來的選單裡有沒有掃描」只有真的畫一次才知道。

@test "dev 模式的主選單**沒有**測試、掃描與部署" {
    tui_screen --mode dev
    [ "$TUI_RC" -eq 0 ]
    [[ $TUI_TEXT == *"DevSecOps"* ]] \
        && _fail_with "dev 模式不該有 DevSecOps（掃描）"
    [[ $TUI_TEXT == *"部署：Ansible"* ]] \
        && _fail_with "dev 模式不該有部署"
    # 但要說得出去哪裡找 —— 藏起來卻不說，使用者只會以為壞了
    [[ $TUI_TEXT == *"test 模式"* ]] || _fail_with "沒有提示測試／掃描在哪個模式"
    return 0
}

@test "test 模式的主選單**有**測試與掃描，但沒有部署" {
    tui_screen --mode test
    [ "$TUI_RC" -eq 0 ]
    [[ $TUI_TEXT == *"DevSecOps"* ]] || _fail_with "test 模式應該要有掃描"
    [[ $TUI_TEXT == *"部署：Ansible"* ]] \
        && _fail_with "test 模式不該有部署"
    return 0
}

@test "prod 模式的主選單**有**部署，但沒有測試與掃描" {
    tui_screen --mode prod
    [ "$TUI_RC" -eq 0 ]
    [[ $TUI_TEXT == *"部署：Ansible"* ]] || _fail_with "prod 模式應該要有部署"
    [[ $TUI_TEXT == *"DevSecOps"* ]] \
        && _fail_with "prod 模式不該有掃描"
    return 0
}

@test "標題列帶得出目前的模式與 runner" {
    tui_screen --mode test --runner native
    [ "$TUI_RC" -eq 0 ]
    [[ $TUI_TEXT == *"模式：test"* ]]     || _fail_with "標題沒有帶出模式"
    [[ $TUI_TEXT == *"runner：native"* ]] || _fail_with "標題沒有帶出 runner"
}

# ── 在選單裡切換模式，選單必須跟著重建 ────────────────────────────────────
#
# 上面那三條驗的是「**啟動時**就是這個模式」的畫面，走不到「在選單裡切換」
# 這條路。2026-09-06 使用者回報：切到 test / prod 之後選單完全沒變。
#
# 原因是 items 陣列建在 while 迴圈**外面**，只算一次。
# 而標題字串是在 _tui_menu 的參數位置求值的，每次迭代都重算 ——
# 所以「[模式：test]」**會**跟著變，只有底下的項目沒變。
# 使用者看到的是一個說自己在 test 模式、卻沒有測試與掃描的選單。
#
# 按鍵：主選單第 1 項是 status、第 2 項是 mode → 下+Enter 進切換模式；
#       切換模式選單是 dev/test/prod → 下+Enter 選 test、下下+Enter 選 prod。

@test "在選單裡切到 test：測試與掃描要出現" {
    tui_screen_keys '\033[B\r
\033[B\r'
    [ "$TUI_RC" -eq 0 ] || _fail_with "選單沒有正常離開（rc=$TUI_RC）"
    [[ $TUI_TEXT == *"模式：test"* ]] \
        || _fail_with "標題沒有切到 test —— 按鍵序列可能沒走到：$TUI_TEXT"
    [[ $TUI_TEXT == *"DevSecOps"* ]] \
        || _fail_with "切到 test 之後選單沒有重建（掃描沒出現）"
    [[ $TUI_TEXT == *"測試：後端"* ]] \
        || _fail_with "切到 test 之後選單沒有重建（測試沒出現）"
}

@test "在選單裡切到 prod：部署要出現、測試與掃描不要" {
    tui_screen_keys '\033[B\r
\033[B\033[B\r'
    [ "$TUI_RC" -eq 0 ] || _fail_with "選單沒有正常離開（rc=$TUI_RC）"
    [[ $TUI_TEXT == *"模式：prod"* ]] \
        || _fail_with "標題沒有切到 prod：$TUI_TEXT"
    [[ $TUI_TEXT == *"部署：Ansible"* ]] \
        || _fail_with "切到 prod 之後選單沒有重建（部署沒出現）"
}

@test "切換模式之後提示文字也要跟著換（藏起來的東西要說去哪找）" {
    tui_screen_keys '\033[B\r
\033[B\r'
    [ "$TUI_RC" -eq 0 ]
    # dev 的提示提到 test 與 prod 兩個模式；切到 test 之後只該剩 prod
    [[ $TUI_TEXT == *"部署在 prod 模式"* ]] \
        || _fail_with "切到 test 之後提示沒有更新：$TUI_TEXT"
}
