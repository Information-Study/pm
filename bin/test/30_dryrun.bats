#!/usr/bin/env bats
# ⑤ --dry-run 不得改變任何狀態

setup() {
    load helpers/common
    load helpers/fixture
}

@test "dry-run 跑完整個 fresh 流程之後，樹的指紋不變" {
    # 這一項比逐指令斷言更貼近真正的契約：跑完之後這棵樹必須一模一樣。
    make_repo dryrun >/dev/null
    local before after
    before=$(tree_digest)
    run cx_bin --dry-run --yes fresh
    assert_rc 0
    after=$(tree_digest)
    [ "$before" = "$after" ] || _fail_with "dry-run 改動了檔案樹"
}

@test "dry-run 不建立封存目錄，也不寫 MANIFEST" {
    make_repo dryarc >/dev/null
    run cx_bin --dry-run --yes fresh --phase backup
    assert_rc 0
    [ ! -e "$CX_ARCHIVE_ROOT" ] || _fail_with "dry-run 建立了 $CX_ARCHIVE_ROOT"
}

@test "dry-run 的 --phase delete 要跑得完（不能死在刪除後的斷言）" {
    # 刪除走 cx_run（dry-run 不執行），而後置斷言原本是無條件的 ——
    # 於是最需要 dry-run 的動詞，dry-run 是壞的。
    make_repo drydel >/dev/null
    run cx_bin --dry-run --yes fresh --phase delete
    assert_rc 0
    [ -e "$CX_TEST_ROOT/.git" ] || _fail_with "dry-run 真的刪了 .git"
    [ -e "$CX_TEST_ROOT/src/backend" ] || _fail_with "dry-run 真的刪了 backend"
}

@test "dry-run 的 migrate 不會產生 docker/legacy 的副本" {
    make_repo drymig >/dev/null
    run cx_bin --dry-run --yes fresh --phase migrate
    assert_rc 0
    [ ! -e "$CX_TEST_ROOT/env/docker/legacy/docker-compose.yml.orig" ] \
        || _fail_with "dry-run 真的複製了檔案"
}
