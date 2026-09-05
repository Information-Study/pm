#!/usr/bin/env bats
# ⑥ 封存的失效模式

setup() {
    load helpers/common
    load helpers/fixture
    make_repo arc >/dev/null
    run cx_bin --yes fresh --mode backup-only
    [ "$status" -eq 0 ] || skip "備份本身失敗，後面的案例沒有意義"
    ARC=$(cat "$CX_ARCHIVE_ROOT/LATEST")
    export ARC
}

@test "備份會產出 MANIFEST、bundle、gitdir tar 與 SHA256SUMS" {
    [ -f "$ARC/MANIFEST.txt" ]
    [ -s "$ARC/git-main.bundle" ]
    [ -s "$ARC/gitdir-main.tar.gz" ]
    [ -f "$ARC/SHA256SUMS" ]
}

@test "被截斷的 bundle 必須驗不過" {
    # git bundle verify 只讀 header，對截斷過的 bundle 照樣回 0 ——
    # 所以驗證是真的把它解進一個 bare repo。這一項就是那段程式碼的回歸測試。
    head -c 200 "$ARC/git-main.bundle" > "$ARC/git-main.bundle.tmp"
    mv "$ARC/git-main.bundle.tmp" "$ARC/git-main.bundle"
    run cx_bin --yes fresh --rollback --from "$ARC"
    [ "$status" -ne 0 ] || _fail_with "截斷的 bundle 竟然通過驗證"
}

@test "MANIFEST 說有、實際卻缺檔，必須驗不過" {
    # 舊版把「檔案不存在」當成「沒事可驗」而不是「封存不完整」，
    # 而 SHA256SUMS 也救不了（缺檔根本不在清單裡）。
    rm -f "$ARC/src-backend.tar.gz"
    run cx_bin --yes fresh --rollback --from "$ARC"
    [ "$status" -ne 0 ] || _fail_with "缺檔的封存竟然通過驗證"
    assert_out_has "MANIFEST"
}

@test "還原之後要與 MANIFEST 對帳（HEAD 與 commit 數）" {
    local want; want=$(sed -n 's/^main_head=//p' "$ARC/MANIFEST.txt" | head -1)
    rm -rf "$CX_TEST_ROOT/.git" "$CX_TEST_ROOT/src/backend" "$CX_TEST_ROOT/src/frontend"
    run cx_bin --yes fresh --rollback --from "$ARC"
    assert_rc 0
    local got; got=$(git -C "$CX_TEST_ROOT" rev-parse HEAD)
    [ "$got" = "$want" ] || _fail_with "還原後的 HEAD 與 MANIFEST 不符"
}

@test "還原是冪等的（連跑兩次都要成功）" {
    run cx_bin --yes fresh --rollback --from "$ARC"; assert_rc 0
    run cx_bin --yes fresh --rollback --from "$ARC"; assert_rc 0
}

@test "還原不會直接刪掉被覆蓋的內容（先搬到 .cx-restore-backup/）" {
    run cx_bin --yes fresh --rollback --from "$ARC"
    assert_rc 0
    [ -d "$CX_TEST_ROOT/.cx-restore-backup" ] \
        || _fail_with "被覆蓋的內容沒有留下備份"
}
