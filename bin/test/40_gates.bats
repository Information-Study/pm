#!/usr/bin/env bats
# ④ 破壞性操作的確認閘門

setup() {
    load helpers/common
    load helpers/fixture
}

@test "fresh 的刪除閘門：沒有 --yes 且無 TTY 時要中止，且一個檔案都不能動" {
    # 這是「訊息說謊比動到檔案更糟」那個缺陷的直接回歸測試：
    # 曾經畫面印「使用者取消，未變更任何檔案」，git status 卻多出三個 M。
    make_repo gate >/dev/null
    local before; before=$(tree_digest)
    CX_ASK_TIMEOUT=2 run cx_bin fresh
    assert_rc "$EX_ABORT"
    [ "$before" = "$(tree_digest)" ] || _fail_with "取消之後檔案樹卻變了"
    [ -e "$CX_TEST_ROOT/.git" ] || _fail_with ".git 被刪了"
}

@test "fresh 的閘門在無 TTY 下給的是可行動訊息，不是靜默失敗" {
    make_repo gate2 >/dev/null
    CX_ASK_TIMEOUT=2 run cx_bin fresh
    assert_rc "$EX_ABORT"
    # 閘門會先把「會刪什麼、保留什麼、封存在哪」全部印出來，再要求確認。
    assert_out_has "此操作不可逆" "封存位置" "保留不動" "--yes"
    assert_out_lacks "command not found" "Traceback"
}

@test "刪除確認是打字型的（DESTROY <專案>），不是按 Enter" {
    # 無 TTY 時流程會停在第一道 cx_confirm，走不到打字那一關 ——
    # 所以這一項用結構斷言：閘門必須呼叫 cx_ask_typed 且字串是 DESTROY。
    # 沒有它的話，一次手滑的 Enter 就會刪掉 .git 與前後端。
    run grep -n -A2 "cx_ask_typed" "$CX_TEST_REAL_ROOT/bin/cmd/fresh.sh"
    assert_rc 0
    assert_out_has "DESTROY" "cx_project"
}

@test "acl user rm 拒絕移除 web/dev 身分" {
    need_cmd setfacl getfacl
    make_root aclg >/dev/null
    run cx_bin acl user rm "$(id -un)"
    assert_rc "$EX_USAGE"
    assert_out_has "acl drop" "acl apply"
}

@test "acl 未知子指令回 EX_USAGE" {
    make_root acl2 >/dev/null
    run cx_bin acl definitely-not-a-subcommand
    assert_rc "$EX_USAGE"
}

@test "push 的白名單跟著 .cxroot 走，黑名單則是永久的" {
    # 白名單由 CX_GH_ORG / CX_REPO_* 產生，所以改名之後會自動跟上；
    # 黑名單是寫死的常數，不接受任何覆寫旗標。
    make_root pushg >/dev/null
    run env CX_ROOT="$CX_TEST_ROOT" bash -c "
        . '$CX_TEST_REAL_ROOT/bin/lib/common.sh'
        . '$CX_TEST_ROOT/.cxroot'
        . '$CX_TEST_REAL_ROOT/bin/lib/guard.sh'
        echo \"ALLOW_RE=\$(cx_guard_allow_re)\"
        echo \"DENY_RE=\$CX_DENIED_REMOTE_RE\""
    assert_rc 0
    # fixture 的 .cxroot 用 Bats-Org / pushg，白名單必須反映它
    assert_out_has "Bats-Org" "pushg"
    # 黑名單是永久的常數
    assert_out_has "team-of-P"
}

@test "被列入黑名單的遠端會被 hook 擋下" {
    make_root pushg2 >/dev/null
    run env CX_ROOT="$CX_TEST_ROOT" bash -c "
        . '$CX_TEST_REAL_ROOT/bin/lib/common.sh'
        . '$CX_TEST_REAL_ROOT/bin/lib/guard.sh'
        u='git@github.com:team-of-P/anything.git'
        printf '%s' \"\$u\" | grep -qE \"\$CX_DENIED_REMOTE_RE\" && echo DENIED || echo ALLOWED
        u2='git@github.com:Bats-Org/pushg.git'
        printf '%s' \"\$u2\" | grep -qE \"\$CX_DENIED_REMOTE_RE\" && echo DENIED2 || echo ALLOWED2"
    assert_out_has "DENIED" "ALLOWED2"
}

@test "deploy apply 不接受 --yes 當第一個位置參數" {
    # ansible 對「比對不到任何主機」的 pattern 只給 warning 然後 exit 0，
    # 於是 apply 會安靜地什麼都沒做卻回報成功。
    make_root dep >/dev/null
    run cx_bin deploy apply --yes
    assert_rc "$EX_USAGE"
}
