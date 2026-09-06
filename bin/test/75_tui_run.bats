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

# ── 部署選單的形狀與可達性 ────────────────────────────────────────────────
#
# 2026-09-06 使用者回報「deploy 內選單跟功能皆不正常」。當時是 11 個平鋪的
# 項目（hosts / syntax / lint / galaxy / ping / check / vars / facts / apply /
# app / rollback），把「設定」與「執行」混在同一層，而且**沒有任何群組的入口**：
# hosts → add 只問名稱與 IP，於是從選單加的主機永遠吃預設值（三個群組全開），
# 前後端分機從選單根本做不到。
#
# 靜態檢查對這件事完全無感 —— TUI-resolve 只問「tag 指得到真的動詞嗎」，
# 而 hosts / syntax / lint 全都指得到。所以這幾條要真的把選單畫出來看。
#
# 按鍵：prod 主選單第 7 項是 deploy（status/mode/project/env/docker/tools/deploy）
#       → 下 6 次 + Enter。

@test "部署選單是四個大項：主機／群組／部署／撤回" {
    tui_screen_keys '\033[B\033[B\033[B\033[B\033[B\033[B\r' --mode prod
    [ "$TUI_RC" -eq 0 ] || _fail_with "選單沒有正常離開（rc=$TUI_RC）"
    [[ $TUI_TEXT == *"部署（Ansible）"* ]] || _fail_with "沒有進到部署選單：$TUI_TEXT"
    [[ $TUI_TEXT == *"主機設定"* ]] || _fail_with "缺「主機設定」"
    [[ $TUI_TEXT == *"群組設定"* ]] || _fail_with "缺「群組設定」—— 這正是使用者回報的缺口"
    [[ $TUI_TEXT == *"部署開始"* ]] || _fail_with "缺「部署開始」"
    [[ $TUI_TEXT == *"撤回部署"* ]] || _fail_with "缺「撤回部署」"
    # 執行階梯要收在「部署開始」底下，不可以再平鋪回這一層
    [[ $TUI_TEXT == *"ansible-lint"* ]] \
        && _fail_with "lint 又回到部署選單第一層了（應該在「部署開始」裡）"
    return 0
}

@test "部署 → 主機設定：新增主機會問群組，而且有 set 可以改" {
    # ⚠ 最後那個 \033 不可省：tui_screen_keys 固定只送兩個 ESC，
    #   剛好夠關掉「部署」與主選單。多進一層就要自己多關一層，
    #   否則主選單會停在那裡等輸入，整個 pty 被 timeout 殺掉（status 124）。
    tui_screen_keys '\033[B\033[B\033[B\033[B\033[B\033[B\r
\r
\033' --mode prod
    [ "$TUI_RC" -eq 0 ] || _fail_with "選單沒有正常離開（rc=$TUI_RC）"
    [[ $TUI_TEXT == *"hosts.yml"* ]] || _fail_with "沒有進到主機設定：$TUI_TEXT"
    [[ $TUI_TEXT == *"會問要跑哪些群組"* ]] \
        || _fail_with "新增主機沒有群組的入口 —— 那樣加出來的主機永遠是預設值"
    [[ $TUI_TEXT == *"改一台主機的位址"* ]] || _fail_with "缺 set（只能 rm 再 add 的話會弄丟 port/key）"
    # A15 的說明必須指向 web_backend；分群之後還寫「在 web 裡」是錯的
    [[ $TUI_TEXT == *"web_backend"* ]] || _fail_with "A15 的說明沒有指向 web_backend"
    return 0
}

@test "部署 → 群組設定：改得到某一台的群組歸屬" {
    tui_screen_keys '\033[B\033[B\033[B\033[B\033[B\033[B\r
\033[B\r
\033' --mode prod
    [ "$TUI_RC" -eq 0 ] || _fail_with "選單沒有正常離開（rc=$TUI_RC）"
    [[ $TUI_TEXT == *"群組歸屬"* ]] \
        || _fail_with "群組設定裡沒有「改某一台的群組歸屬」：$TUI_TEXT"
    [[ $TUI_TEXT == *"拆機還要改什麼"* ]] \
        || _fail_with "沒有說明拆機還要動 php_fpm_listen / frontend_host"
    return 0
}
