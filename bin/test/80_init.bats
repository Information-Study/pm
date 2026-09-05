#!/usr/bin/env bats
# ⑧ cx init 與抹除路徑的安全性
#
# 這一支蓋的是 2026-09-05 稽核抓到的三個缺陷，每一個都曾經「成功地做錯事」：
#   A  worktree 之下封存不含主庫歷史，而驗證回報通過
#   B  刪除中途失敗會毀掉 rollback 路徑（麵包屑寫太晚 + symlink 只是略過）
#   C  cx init 產出缺 Filament 面板與 API 路由的專案
#
# ⚠ 這裡刻意用 make_submodule_repo 而不是 make_repo：後者建的是三個各自獨立的
#   巢狀 plain repo，而真實專案是 submodule（指標檔 + .git/modules/）。
#   archive.sh 處理指標檔的那一整段在 make_repo 底下是死碼。

setup() {
    load helpers/common
    load helpers/fixture
}

# ── A：worktree ────────────────────────────────────────────────────────────

@test "worktree 之下 cx fresh 必須拒絕，而且什麼都不建" {
    make_submodule_repo wt >/dev/null
    # 從 fixture 再長出一個 worktree —— 那裡的 .git 是檔案，不是目錄
    local wt="$BATS_TEST_TMPDIR/wt-checkout"
    git -C "$CX_TEST_ROOT" worktree add -q --detach "$wt" HEAD
    # fixture 的 bin / cx symlink 已經被 commit 進去了，所以 worktree checkout
    # 本來就有；只補缺的那些。
    [ -e "$wt/.cxroot" ] || cp "$CX_TEST_ROOT/.cxroot" "$wt/.cxroot"
    [ -e "$wt/bin" ] || ln -s "$CX_TEST_REAL_ROOT/bin" "$wt/bin"
    [ -e "$wt/cx" ]  || ln -s "$CX_TEST_REAL_ROOT/cx"  "$wt/cx"
    [ -f "$wt/.git" ] || skip "這個 git 版本的 worktree .git 不是檔案"

    local arc="$BATS_TEST_TMPDIR/arc-wt"
    run env CX_ARCHIVE_ROOT="$arc" "$wt/cx" --root "$wt" --yes fresh --phase backup
    assert_rc "$EX_PRECOND"
    assert_out_has "PF-10" "worktree"
    # 「完全不動任何東西」是 preflight 的合約
    [ ! -d "$arc" ] || _fail_with "被擋下了卻還是建出封存目錄 $arc"
    [ -e "$wt/.git" ] || _fail_with "worktree 的 .git 指標被動到了"
}

@test "MANIFEST 缺少主庫記載時，封存驗證必須失敗（不可以因為缺鍵就放行）" {
    make_submodule_repo mf >/dev/null
    run cx_bin --yes fresh --mode backup-only
    assert_rc 0
    local A; A=$(cat "$CX_ARCHIVE_ROOT/LATEST")

    # 完整的 MANIFEST 應該通過
    run cx_verify_in_fixture "$A"
    assert_rc 0

    # 拿掉 main_state 與 main_head —— 這正是 worktree 缺陷產出的形狀。
    # 舊版的 expect 清單是從 MANIFEST 推導的，少了鍵就什麼都不驗 → 回報通過。
    grep -vE '^main_(state|head)=' "$A/MANIFEST.txt" > "$A/MANIFEST.new"
    mv "$A/MANIFEST.new" "$A/MANIFEST.txt"
    run cx_verify_in_fixture "$A"
    [ "$status" -ne 0 ] || _fail_with "缺少主庫記載的封存竟然通過驗證"
}

@test "只缺 main_state 的舊封存仍然驗得過（相容性）" {
    make_submodule_repo mo >/dev/null
    run cx_bin --yes fresh --mode backup-only
    assert_rc 0
    local A; A=$(cat "$CX_ARCHIVE_ROOT/LATEST")
    grep -v '^main_state=' "$A/MANIFEST.txt" > "$A/MANIFEST.new"
    mv "$A/MANIFEST.new" "$A/MANIFEST.txt"
    run cx_verify_in_fixture "$A"
    assert_rc 0
}

# ── B：刪除中途失敗 ────────────────────────────────────────────────────────

@test "symlink 的 .git 會中止整個刪除，而不是略過之後繼續刪別的" {
    make_submodule_repo sl >/dev/null
    # 把 .git 換成指向樹外的 symlink
    mv "$CX_TEST_ROOT/.git" "$BATS_TEST_TMPDIR/real-git-sl"
    ln -s "$BATS_TEST_TMPDIR/real-git-sl" "$CX_TEST_ROOT/.git"

    run cx_bin --yes fresh --phase delete
    [ "$status" -ne 0 ] || _fail_with "symlink 的 .git 竟然讓刪除成功了"
    assert_out_has "symlink"

    # 舊行為：.git 被略過，然後 backend/ frontend/ README.md .gitmodules 全被刪掉，
    # 最後才由斷言 cx_die —— 而 cx_die 會 exit，麵包屑與救援指引都來不及寫。
    [ -e "$CX_TEST_ROOT/src/backend" ]     || _fail_with "backend/ 被刪掉了"
    [ -e "$CX_TEST_ROOT/src/frontend" ]    || _fail_with "frontend/ 被刪掉了"
    [ -e "$CX_TEST_ROOT/README.md" ]   || _fail_with "README.md 被刪掉了"
    [ -e "$CX_TEST_ROOT/.gitmodules" ] || _fail_with ".gitmodules 被刪掉了"
}

@test "麵包屑寫在刪除之前 —— 刪到一半失敗也保得住 LATEST" {
    make_submodule_repo bc >/dev/null
    mv "$CX_TEST_ROOT/.git" "$BATS_TEST_TMPDIR/real-git-bc"
    ln -s "$BATS_TEST_TMPDIR/real-git-bc" "$CX_TEST_ROOT/.git"

    run cx_bin --yes fresh --phase delete
    [ "$status" -ne 0 ] || _fail_with "應該要失敗"

    # 關鍵：狀態要是 delete（進入即寫），不是 migrate（完成才寫）。
    # 寫成後者的話，下一次執行的守門 pidx>=3 不成立，
    # 會對著毀掉的樹重新封存並覆寫 LATEST —— 唯一的安全網被自己蓋掉。
    local ph; ph=$(sed -n 's/^phase=//p' "$CX_TEST_ROOT/.cx/fresh.state" 2>/dev/null)
    [ "$ph" = delete ] || _fail_with "麵包屑是「$ph」，應該是 delete"
    [ -f "$CX_TEST_ROOT/CX-RECOVERY.md" ] || _fail_with "沒有留下救援指引"

    local latest_before; latest_before=$(cat "$CX_ARCHIVE_ROOT/LATEST")
    run cx_bin --yes fresh
    assert_rc "$EX_PRECOND"
    local latest_after; latest_after=$(cat "$CX_ARCHIVE_ROOT/LATEST")
    [ "$latest_before" = "$latest_after" ] || _fail_with "LATEST 被覆寫了"
}

# ── C：cx init 的介面與閘門 ────────────────────────────────────────────────

@test "cx init 需要新名字，cx re-init 不需要" {
    make_root ini >/dev/null
    run cx_bin init
    assert_rc "$EX_USAGE"
    run cx_bin init --help
    assert_rc 0
}

@test "cx init --help 放在名字後面也要是 0" {
    make_root inh >/dev/null
    run cx_bin init shop --help
    assert_rc 0
}

@test "cx init 的預設模式是 carryover，不是 scaffold" {
    # scaffold 當預設會產出一個**缺零件**的專案：範本自己接的 Filament 面板、
    # routes/api.php 與 Sanctum migration 都不在框架骨架裡，
    # 而 _fresh_rebuild_backend 從不跑 filament:install --panels。
    make_root ind >/dev/null
    run cx_bin --dry-run init shop
    assert_rc 0
    assert_out_has "carryover"
}

@test "cx init 在沒有終端機時被閘門擋下，且不動任何檔案" {
    make_submodule_repo ing >/dev/null
    local before; before=$(tree_digest)
    run cx_bin init shop </dev/null
    assert_rc "$EX_ABORT"
    local after; after=$(tree_digest)
    [ "$before" = "$after" ] || _fail_with "被取消了卻動到檔案"
    [ -e "$CX_TEST_ROOT/.git" ] || _fail_with ".git 不見了"
}

@test "cx --dry-run init 不動任何檔案" {
    make_submodule_repo idr >/dev/null
    local before; before=$(tree_digest)
    run cx_bin --dry-run --yes init shop
    assert_rc 0
    local after; after=$(tree_digest)
    [ "$before" = "$after" ] || _fail_with "dry-run 動到了檔案"
}

@test "cx git remote-init 沒有終端機時 fail-closed，不會建立任何 GitHub repo" {
    make_submodule_repo gri >/dev/null
    run cx_bin git remote-init </dev/null
    # 沒有 gh 就是 EX_PRECOND，有 gh 但沒終端機就是 EX_ABORT —— 兩者都不可以是 0
    [ "$status" -ne 0 ] || _fail_with "remote-init 在非互動下竟然通過了（會建出真的 public repo）"
}

# ── 完整破壞性流程：需要網路，預設跳過 ─────────────────────────────────────

@test "完整的 cx init 會抹掉三個 repo 的歷史並重建（需要網路）" {
    if [ "${CX_TEST_NETWORK:-0}" != 1 ]; then
        skip "需要網路（composer create-project / nuxi init）—— 設 CX_TEST_NETWORK=1 才跑"
    fi
    make_submodule_repo full >/dev/null
    local mh bh fh
    mh=$(git -C "$CX_TEST_ROOT" rev-parse HEAD)
    bh=$(git -C "$CX_TEST_ROOT/src/backend" rev-parse HEAD)
    fh=$(git -C "$CX_TEST_ROOT/src/frontend" rev-parse HEAD)

    run cx_bin --yes init shop
    assert_rc 0

    # ⚠ 不可以斷言「.git/modules 不存在」。_fresh_git_init 收尾會跑
    #   submodule absorbgitdirs，所以新專案**會**有 .git/modules —— 那是刻意的
    #   （收斂成跟任何人 clone 下來一樣的標準佈局）。真正的不變量是
    #   「舊歷史一個都不可達」，那由下面三條斷言負責。
    ! git -C "$CX_TEST_ROOT" cat-file -e "$mh^{commit}" 2>/dev/null \
        || _fail_with "主庫的舊 commit 還在"
    ! git -C "$CX_TEST_ROOT/src/backend" cat-file -e "$bh^{commit}" 2>/dev/null \
        || _fail_with "backend 的舊 commit 還在"
    ! git -C "$CX_TEST_ROOT/src/frontend" cat-file -e "$fh^{commit}" 2>/dev/null \
        || _fail_with "frontend 的舊 commit 還在"

    [ "$(git -C "$CX_TEST_ROOT" rev-list --count HEAD)" = 1 ] \
        || _fail_with "主庫不是全新歷史"
    [ "$(git -C "$CX_TEST_ROOT/src/backend" rev-list --count HEAD)" = 1 ] \
        || _fail_with "backend 不是全新歷史"
    # 標準佈局：指標檔 + .git/modules（與 clone 下來的一致）
    [ -f "$CX_TEST_ROOT/src/backend/.git" ] \
        || _fail_with "src/backend/.git 不是指標檔 —— absorbgitdirs 沒生效"
    grep -q '^CX_PROJECT_NAME=shop$' "$CX_TEST_ROOT/.cxroot" \
        || _fail_with ".cxroot 沒有改名"

    # 範本自己的系統接線必須活下來 —— 這是 scaffold 曾經整組弄丟的東西
    [ -f "$CX_TEST_ROOT/src/backend/app/Providers/Filament/AdminPanelProvider.php" ] \
        || _fail_with "缺少 Filament 面板"
    grep -q AdminPanelProvider "$CX_TEST_ROOT/src/backend/bootstrap/providers.php" \
        || _fail_with "面板沒有被註冊到 bootstrap/providers.php"
    [ -f "$CX_TEST_ROOT/src/backend/routes/api.php" ] || _fail_with "缺少 routes/api.php"
    ls "$CX_TEST_ROOT/src/backend/database/migrations/" | grep -q personal_access_tokens \
        || _fail_with "缺少 Sanctum 的 migration"
}
