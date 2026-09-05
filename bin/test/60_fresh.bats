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
    [ -f "$CX_TEST_ROOT/src/backend/file.txt" ] || _fail_with "backend 的內容沒有還原"
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
    [ -f "$CX_TEST_ROOT/src/backend/artisan" ]
    [ -f "$CX_TEST_ROOT/src/frontend/nuxt.config.ts" ]
}

# ── git-only：只抹 git 紀錄，程式碼原封不動 ────────────────────────────────
#
# 這個模式的全部價值就在「原封不動」四個字。所以第一條案例比對的是
# **除了 git 以外的整棵樹**的指紋 —— 少了它，一個把 backend/ 也刪掉的
# 實作照樣會通過「有沒有重新 init」那種檢查。

@test "git-only 不動任何非 git 基礎設施的檔案（使用者的程式碼原封不動）" {
    # 先放一些「使用者的程式碼」進去
    mkdir -p "$CX_TEST_ROOT/src/backend/app" "$CX_TEST_ROOT/src/frontend/pages"
    echo 'my business logic' > "$CX_TEST_ROOT/src/backend/app/Service.php"
    echo 'my page'           > "$CX_TEST_ROOT/src/frontend/pages/index.vue"
    echo 'my infra'          > "$CX_TEST_ROOT/docker-compose.yml"
    local g=(-c user.email=b@b -c user.name=b)
    git -C "$CX_TEST_ROOT" "${g[@]}" add -A 2>/dev/null || true
    git -C "$CX_TEST_ROOT" "${g[@]}" commit -q -m 'user code' 2>/dev/null || true

    # ⚠ 排除的三類都是 git 基礎設施，重新 init 本來就會重建它們：
    #     .git/            物件庫
    #     .gitmodules      submodule add 重新產生
    #     */.gitignore     從 templates/gitignore/ 複製（子模組是 PUBLIC repo）
    #   還有 .cx/ —— 那是 cx 自己的執行期狀態（鎖檔、fresh 麵包屑）。
    #   把它們算進「不動」的定義，測到的就不是這個模式的承諾了。
    local snap
    snap() {
        (cd "$CX_TEST_ROOT" && find . \
            -path ./.git -prune -o -path './*/.git' -prune -o -path ./.cx -prune -o \
            -name .gitignore -prune -o -name .gitmodules -prune -o \
            -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null)
    }
    local before; before=$(snap)

    run cx_bin --yes fresh --mode git-only
    assert_rc 0

    local after; after=$(snap)
    if [ "$before" != "$after" ]; then
        _fail_with "git-only 動到了非 git 基礎設施的檔案：
$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true)"
    fi
    [ "$(cat "$CX_TEST_ROOT/src/backend/app/Service.php")" = 'my business logic' ] \
        || _fail_with "使用者的後端程式碼被動過"
    [ "$(cat "$CX_TEST_ROOT/src/frontend/pages/index.vue")" = 'my page' ] \
        || _fail_with "使用者的前端程式碼被動過"
    [ "$(cat "$CX_TEST_ROOT/docker-compose.yml")" = 'my infra' ] \
        || _fail_with "基礎設施檔被重建了（那是 scaffold 才該做的事）"
}

@test "git-only 之後三個 repo 都是全新的（歷史只有一個 commit）" {
    run cx_bin --yes fresh --mode git-only
    assert_rc 0
    local r n
    for r in "" /src/backend /src/frontend; do
        [ -e "$CX_TEST_ROOT$r/.git" ] || _fail_with "$r 沒有重新 init"
        n=$(git -C "$CX_TEST_ROOT$r" rev-list --count HEAD 2>/dev/null || echo 0)
        [ "$n" = "1" ] || _fail_with "$r 的歷史有 $n 個 commit，不是全新的"
    done
}

@test "git-only 之後兩條線都在（flow-init 的拓撲）" {
    run cx_bin --yes fresh --mode git-only
    assert_rc 0
    local r
    for r in "" /src/backend /src/frontend; do
        git -C "$CX_TEST_ROOT$r" show-ref --verify --quiet refs/heads/main \
            || _fail_with "$r 沒有 main"
        git -C "$CX_TEST_ROOT$r" show-ref --verify --quiet refs/heads/dev \
            || _fail_with "$r 沒有 dev"
    done
}

@test "git-only 的 dry-run 什麼都不動" {
    local before; before=$(tree_digest)
    run cx_bin --dry-run --yes fresh --mode git-only
    [ "$before" = "$(tree_digest)" ] || _fail_with "dry-run 動到了檔案樹"
}
