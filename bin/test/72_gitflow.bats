#!/usr/bin/env bats
# ⑨ gitflow：功能分支只在子模組，主庫的 dev 跟著 gitlink 走
#
# 分支模型（2026-09-05 依實測定案）：
#   主庫       main ← dev              **沒有 feature/***
#   backend    main ← dev ← feature/*
#   frontend   main ← dev ← feature/*
#
# 為什麼不是「主庫也開 feature」或「主庫拆成 dev-frontend / dev-backend」：
# 實測過前後端各自推進自己那一顆 gitlink 再合回同一條 dev —— 兩次合併都 rc=0，
# 零衝突，因為那是不同路徑。真正會衝突的是共用基礎設施（實測 CONFLICT），
# 而拆成兩條長期線只會讓後者更難合。

setup() {
    load helpers/common
    load helpers/fixture
    make_submodule_repo gf >/dev/null
}

# ── 拓撲 ───────────────────────────────────────────────────────────────────

@test "flow-init 會補齊三個 repo 的 dev，而且可以重複跑" {
    # fixture 已經有 dev；把 backend 的砍掉來製造「舊專案」的狀態
    git -C "$CX_TEST_ROOT/backend" switch -q main
    git -C "$CX_TEST_ROOT/backend" branch -D dev
    run cx_bin --yes git flow-init
    assert_rc 0
    git -C "$CX_TEST_ROOT/backend" show-ref --verify --quiet refs/heads/dev \
        || _fail_with "backend 的 dev 沒有被補回來"

    # 第二次應該什麼都不做
    run cx_bin --yes git flow-init
    assert_rc 0
    assert_out_has "已經是完整的"
}

@test "flow-init 會設定 submodule.recurse —— 那個值原本從來沒有被設過" {
    git -C "$CX_TEST_ROOT" config --unset submodule.recurse || true
    run cx_bin --yes git flow-init
    assert_rc 0
    [ "$(git -C "$CX_TEST_ROOT" config --get submodule.recurse)" = true ] \
        || _fail_with "submodule.recurse 沒有被設成 true"
}

# ── feature start ─────────────────────────────────────────────────────────

@test "feature start 只在指定的子模組建分支，主庫與另一側完全不動" {
    run cx_bin --yes git feature start login --repo frontend
    assert_rc 0
    git -C "$CX_TEST_ROOT/frontend" show-ref --verify --quiet refs/heads/feature/login \
        || _fail_with "frontend 沒有 feature/login"
    ! git -C "$CX_TEST_ROOT" show-ref --verify --quiet refs/heads/feature/login \
        || _fail_with "主庫竟然也有 feature/login —— 主庫不該有 feature 分支"
    ! git -C "$CX_TEST_ROOT/backend" show-ref --verify --quiet refs/heads/feature/login \
        || _fail_with "backend 竟然也有 feature/login —— 它不屬於這次的側別"
}

@test "feature start 的起點是該子模組的 dev，不是剛好所在的位置" {
    # 讓 backend 的 main 比 dev 前面，並停在 main 上
    git -C "$CX_TEST_ROOT/backend" switch -q main
    echo ahead > "$CX_TEST_ROOT/backend/ahead.txt"
    git -C "$CX_TEST_ROOT/backend" -c user.email=b@b -c user.name=b add -A
    git -C "$CX_TEST_ROOT/backend" -c user.email=b@b -c user.name=b commit -q -m ahead

    run cx_bin --yes git feature start api --repo backend
    assert_rc 0
    local got want
    got=$(git -C "$CX_TEST_ROOT/backend" rev-parse feature/api)
    want=$(git -C "$CX_TEST_ROOT/backend" rev-parse dev)
    [ "$got" = "$want" ] || _fail_with "feature/api 不是從 dev 開的（got=$got want=$want）"
}

@test "feature start 沒給 --repo 又不在子模組裡時要問清楚，不可以亂猜" {
    run cx_bin --yes git feature start login
    assert_rc "$EX_USAGE"
    assert_out_has "--repo backend|frontend"
}

@test "feature start 的 --repo 不接受 main 或 all" {
    run cx_bin --yes git feature start login --repo main
    assert_rc "$EX_USAGE"
    run cx_bin --yes git feature start login --repo all
    assert_rc "$EX_USAGE"
}

@test "主庫不可以用 branch new 繞過去開 feature/*" {
    run cx_bin --yes git branch new feature/sneaky --repo main
    assert_rc "$EX_USAGE"
    assert_out_has "主庫不開 feature 分支"
    ! git -C "$CX_TEST_ROOT" show-ref --verify --quiet refs/heads/feature/sneaky \
        || _fail_with "分支還是被建出來了"
}

# ── feature finish ────────────────────────────────────────────────────────

@test "feature finish 合回子模組的 dev，並讓主庫的 dev gitlink 跟上" {
    run cx_bin --yes git feature start login --repo frontend
    assert_rc 0
    echo work > "$CX_TEST_ROOT/frontend/work.txt"
    git -C "$CX_TEST_ROOT/frontend" -c user.email=b@b -c user.name=b add -A
    git -C "$CX_TEST_ROOT/frontend" -c user.email=b@b -c user.name=b commit -q -m work

    run cx_bin --yes git feature finish login --repo frontend
    assert_rc 0

    # 子模組：dev 上要有那個 merge
    git -C "$CX_TEST_ROOT/frontend" merge-base --is-ancestor feature/login dev \
        || _fail_with "feature/login 沒有被合進 frontend 的 dev"

    # 主庫：dev 的 frontend gitlink 必須等於 frontend 的 dev tip。
    # ⚠ 這一條是關鍵：主庫如果是用 merge 帶進 gitlink，記到的會是 feature 的
    #   tip 而不是子模組新的 --no-ff merge commit（實測確認），於是永遠差一步。
    local gl fe_dev
    gl=$(line_sha "$CX_TEST_ROOT" dev frontend)
    fe_dev=$(git -C "$CX_TEST_ROOT/frontend" rev-parse dev)
    [ "$gl" = "$fe_dev" ] || _fail_with "主庫的 gitlink（$gl）沒有跟上 frontend 的 dev（$fe_dev）"
}

@test "feature finish 不會把另一側的髒 gitlink 掃進同一個 commit" {
    run cx_bin --yes git feature start login --repo frontend
    assert_rc 0
    echo w > "$CX_TEST_ROOT/frontend/w.txt"
    git -C "$CX_TEST_ROOT/frontend" -c user.email=b@b -c user.name=b add -A
    git -C "$CX_TEST_ROOT/frontend" -c user.email=b@b -c user.name=b commit -q -m w

    # 讓 backend 的 gitlink 也變髒（模擬另一個人正在推進後端）
    git -C "$CX_TEST_ROOT/backend" switch -q dev
    echo b > "$CX_TEST_ROOT/backend/b.txt"
    git -C "$CX_TEST_ROOT/backend" -c user.email=b@b -c user.name=b add -A
    git -C "$CX_TEST_ROOT/backend" -c user.email=b@b -c user.name=b commit -q -m b
    local be_before; be_before=$(line_sha "$CX_TEST_ROOT" dev backend)

    run cx_bin --yes git feature finish login --repo frontend
    assert_rc 0

    local be_after; be_after=$(line_sha "$CX_TEST_ROOT" dev backend)
    [ "$be_before" = "$be_after" ] \
        || _fail_with "backend 的 gitlink 被順手改了：$be_before → $be_after"
    assert_out_has "backend"   # 應該有提醒它被排除
}

@test "feature list 只列子模組的 feature 分支" {
    run cx_bin --yes git feature start a --repo backend
    assert_rc 0
    run cx_bin --yes git feature start b --repo frontend
    assert_rc 0
    run cx_bin git feature list
    assert_rc 0
    assert_out_has "feature/a" "feature/b"
}

# ── 四個原本被丟掉的旗標 ────────────────────────────────────────────────────

@test "branch new --repo main 不會因為子模組是 detached 就回報失敗" {
    # 子模組被 gitlink 釘住而 detached 是正常狀態，不該讓主庫的操作失敗
    git -C "$CX_TEST_ROOT/backend"  checkout -q --detach HEAD
    git -C "$CX_TEST_ROOT/frontend" checkout -q --detach HEAD
    run cx_bin --yes git branch new chore/x --repo main
    assert_rc 0
    git -C "$CX_TEST_ROOT" show-ref --verify --quiet refs/heads/chore/x \
        || _fail_with "主庫沒有建出 chore/x"
}

@test "branch switch --repo 只切指定的那一個" {
    git -C "$CX_TEST_ROOT/frontend" branch tmp/x dev
    run cx_bin --yes git branch switch tmp/x --repo frontend
    assert_rc 0
    [ "$(git -C "$CX_TEST_ROOT/frontend" branch --show-current)" = tmp/x ] \
        || _fail_with "frontend 沒有切過去"
    [ "$(git -C "$CX_TEST_ROOT" branch --show-current)" = dev ] \
        || _fail_with "主庫不該被切走"
}

@test "branch delete --repo 只刪指定的那一個" {
    git -C "$CX_TEST_ROOT/backend"  branch tmp/y dev
    git -C "$CX_TEST_ROOT/frontend" branch tmp/y dev
    run cx_bin --yes git branch delete tmp/y --repo backend
    assert_rc 0
    ! git -C "$CX_TEST_ROOT/backend" show-ref --verify --quiet refs/heads/tmp/y \
        || _fail_with "backend 的 tmp/y 沒被刪掉"
    git -C "$CX_TEST_ROOT/frontend" show-ref --verify --quiet refs/heads/tmp/y \
        || _fail_with "frontend 的 tmp/y 不該被刪"
}

@test "branch switch 與 delete 對 --from 要報錯，而不是安靜地忽略" {
    run cx_bin --yes git branch switch dev --from main
    assert_rc "$EX_USAGE"
    assert_out_has "--from"
    run cx_bin --yes git branch delete tmp/z --from main
    assert_rc "$EX_USAGE"
}

@test "受保護的分支不可刪除" {
    run cx_bin --yes git branch delete dev
    assert_rc "$EX_USAGE"
    run cx_bin --yes git branch delete main
    assert_rc "$EX_USAGE"
}

# ── sync 不可以倒退子模組的分支 ────────────────────────────────────────────

@test "sync 不會把子模組的 dev 倒退到落後的 gitlink" {
    # 讓 frontend 的 dev 前進兩個 commit，然後把工作區停在舊的 gitlink 上
    # （這就是「站在別條線記錄的舊指標上」的樣子）
    local old_tip; old_tip=$(git -C "$CX_TEST_ROOT/frontend" rev-parse HEAD)
    local g=(-c user.email=b@b -c user.name=b)
    git -C "$CX_TEST_ROOT/frontend" switch -q dev
    echo a > "$CX_TEST_ROOT/frontend/a.txt"
    git -C "$CX_TEST_ROOT/frontend" "${g[@]}" add -A
    git -C "$CX_TEST_ROOT/frontend" "${g[@]}" commit -q -m a
    echo b > "$CX_TEST_ROOT/frontend/b.txt"
    git -C "$CX_TEST_ROOT/frontend" "${g[@]}" add -A
    git -C "$CX_TEST_ROOT/frontend" "${g[@]}" commit -q -m b
    local dev_tip; dev_tip=$(git -C "$CX_TEST_ROOT/frontend" rev-parse dev)
    git -C "$CX_TEST_ROOT/frontend" checkout -q --detach "$old_tip"

    run cx_bin --yes git sync
    # 關鍵：dev 不可以被倒退。實測 checkout -B 會無聲丟掉那兩個 commit，
    # 而且輸出還說 "Your branch is ahead of ... by 2 commits"。
    local after; after=$(git -C "$CX_TEST_ROOT/frontend" rev-parse dev)
    [ "$after" = "$dev_tip" ] \
        || _fail_with "frontend 的 dev 被倒退了：$dev_tip → $after"
    assert_out_has "保持 detached"
}

@test "sync 在 detached HEAD 領先分支時會把分支快轉過來，不丟 commit" {
    local g=(-c user.email=b@b -c user.name=b)
    git -C "$CX_TEST_ROOT/backend" switch -q dev
    git -C "$CX_TEST_ROOT/backend" checkout -q --detach HEAD
    echo ahead > "$CX_TEST_ROOT/backend/ahead.txt"
    git -C "$CX_TEST_ROOT/backend" "${g[@]}" add -A
    git -C "$CX_TEST_ROOT/backend" "${g[@]}" commit -q -m ahead
    local head; head=$(git -C "$CX_TEST_ROOT/backend" rev-parse HEAD)

    run cx_bin --yes git sync
    assert_rc 0
    [ "$(git -C "$CX_TEST_ROOT/backend" rev-parse dev)" = "$head" ] \
        || _fail_with "detached 期間的 commit 沒有被帶進 dev"
    [ "$(git -C "$CX_TEST_ROOT/backend" branch --show-current)" = dev ] \
        || _fail_with "沒有接回 dev"
}

# ── 子模組該站哪一條線：依主庫當前分支，不是 .gitmodules 的單一值 ──────────
#
# .gitmodules 的 branch 只能寫一個值，而主庫有 main 與 dev 兩條線。
# 2026-09-06 實測：flow-init 之後跑 sync，兩個子模組都被接到 main，
# 即使工作正在 dev 線上 —— 症狀是 git status 說子模組有未提交變更，
# 實際上只是它站錯了線。

@test "sync 依主庫當前分支決定子模組的線（主庫在 dev → 子模組到 dev）" {
    git -C "$CX_TEST_ROOT" config -f .gitmodules submodule.backend.branch main
    git -C "$CX_TEST_ROOT" switch -q dev
    git -C "$CX_TEST_ROOT/backend" switch -q main

    run cx_bin --yes git sync
    [ "$(git -C "$CX_TEST_ROOT/backend" branch --show-current)" = dev ] \
        || _fail_with "主庫在 dev，backend 卻在 $(git -C "$CX_TEST_ROOT/backend" branch --show-current)"
}

@test "sync 依主庫當前分支決定子模組的線（主庫在 main → 子模組到 main）" {
    git -C "$CX_TEST_ROOT" config -f .gitmodules submodule.backend.branch dev
    git -C "$CX_TEST_ROOT" switch -q main
    git -C "$CX_TEST_ROOT/backend" switch -q dev

    run cx_bin --yes git sync
    [ "$(git -C "$CX_TEST_ROOT/backend" branch --show-current)" = main ] \
        || _fail_with "主庫在 main，backend 卻在 $(git -C "$CX_TEST_ROOT/backend" branch --show-current)"
}

@test "sync 不動正在被使用的工作分支（feature/* 不會被拉回 dev）" {
    git -C "$CX_TEST_ROOT" switch -q dev
    git -C "$CX_TEST_ROOT/backend" switch -q -c feature/wip

    run cx_bin --yes git sync
    [ "$(git -C "$CX_TEST_ROOT/backend" branch --show-current)" = feature/wip ] \
        || _fail_with "sync 把正在用的 feature/wip 拉走了"
}

@test "sync 在子模組髒的時候不切線（切過去會把改動帶走）" {
    git -C "$CX_TEST_ROOT" switch -q dev
    git -C "$CX_TEST_ROOT/backend" switch -q main
    echo dirty > "$CX_TEST_ROOT/backend/dirty.txt"

    run cx_bin --yes git sync
    [ "$(git -C "$CX_TEST_ROOT/backend" branch --show-current)" = main ] \
        || _fail_with "工作區不乾淨卻還是切線了"
    [[ $output == *"不乾淨"* ]] || _fail_with "沒有說明為什麼不切：$output"
}
