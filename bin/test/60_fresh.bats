#!/usr/bin/env bats
# ⑦ fresh 的失敗與還原

setup() {
    load helpers/common
    load helpers/fixture
    make_repo fr >/dev/null
}

@test "--phase 只接受表上的名稱" {
    run cx_bin --yes fresh --phase nope
    assert_rc "$EX_USAGE"
    assert_out_has "preflight" "git-init"
}

@test "--resume-from 只接受 rebuild|verify|git-init" {
    # 更早的階段涉及備份與刪除，跳過它們就不是「接續」而是「從中間開始破壞」。
    run cx_bin --yes fresh --resume-from delete
    assert_rc "$EX_USAGE"
    run cx_bin --yes fresh --resume-from backup
    assert_rc "$EX_USAGE"
}

@test "--resume-from 比 --phase 還晚時要拒絕" {
    run cx_bin --yes fresh --resume-from git-init --phase rebuild
    assert_rc "$EX_USAGE"
}

@test "--phase migrate 是「跑到遷移為止」，會經過 preflight、備份與閘門" {
    # 舊語意是「只跑遷移」—— 那會跳過確認閘門直接複製檔案。
    run cx_bin --yes fresh --phase migrate
    assert_rc 0
    assert_out_has "Preflight" "封存主庫" "驗證封存"
    [ -e "$CX_TEST_ROOT/.git" ] || _fail_with "migrate 階段不該刪東西"
}

@test "--phase delete 之後留下麵包屑，重跑完整流程會被擋" {
    # 沒有這道保護的話，第二次執行會把**已經被刪掉的狀態**重新封存一次
    # 並覆寫 LATEST —— 原本救得回來的那份封存就找不到了。
    run cx_bin --yes fresh --phase delete
    assert_rc 0
    [ -f "$CX_TEST_ROOT/.cx/fresh.state" ] || _fail_with "沒有寫麵包屑"
    local latest_before; latest_before=$(cat "$CX_ARCHIVE_ROOT/LATEST")

    run cx_bin --yes fresh
    assert_rc "$EX_PRECOND"
    assert_out_has "--resume-from" "--rollback"

    local latest_after; latest_after=$(cat "$CX_ARCHIVE_ROOT/LATEST")
    [ "$latest_before" = "$latest_after" ] || _fail_with "LATEST 被覆寫了"
}

@test "刪除之後可以用 --rollback 回到原狀" {
    run cx_bin --yes fresh --phase delete
    assert_rc 0
    [ ! -e "$CX_TEST_ROOT/.git" ] || _fail_with "delete 沒有真的刪"

    run cx_bin --yes fresh --rollback
    assert_rc 0
    [ -e "$CX_TEST_ROOT/.git" ] || _fail_with "rollback 沒有把 .git 還原回來"
    [ -f "$CX_TEST_ROOT/backend/file.txt" ] || _fail_with "backend 的內容沒有還原"
    # 還原成功之後麵包屑與救援檔要清掉，否則下一次執行會被自己擋住
    [ ! -f "$CX_TEST_ROOT/.cx/fresh.state" ] || _fail_with "麵包屑沒有清除"
}

@test "backup-only 不刪任何東西" {
    local before; before=$(tree_digest)
    run cx_bin --yes fresh --mode backup-only
    assert_rc 0
    [ "$before" = "$(tree_digest)" ] || _fail_with "backup-only 動到了檔案樹"
}

@test "重建需要網路，沒開 CX_TEST_NETWORK 就明確跳過" {
    [ "${CX_TEST_NETWORK:-0}" = "1" ] || skip "需要網路（composer create-project / nuxi init）—— 設 CX_TEST_NETWORK=1 才跑"
    run cx_bin --yes fresh --mode scaffold
    assert_rc 0
    [ -f "$CX_TEST_ROOT/backend/artisan" ]
    [ -f "$CX_TEST_ROOT/frontend/nuxt.config.ts" ]
}
