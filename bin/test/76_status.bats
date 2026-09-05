#!/usr/bin/env bats
# ⑪ cx status — 這棵樹現在是什麼狀態
#
# 這個動詞的契約與其他每一個都不同：**它從不失敗**。
# 沒有 Docker、沒有 .env、連 .git 都沒有，一樣要 rc=0 印出它知道的部分。
# 理由是它是接手專案的人打的第一個指令 —— 一個在半成品的樹上會失敗的
# 「現況一覽」等於沒有，而那正是最需要看現況的時刻。
# 要靠退出碼判斷「能不能用」是 cx doctor 的工作。

setup() {
    load helpers/common
    load helpers/fixture
    make_root st >/dev/null
}

@test "在什麼都沒有的樹上（無 Docker、無 .env、無 .git）仍然 rc=0" {
    no_docker
    run cx_bin status
    assert_rc 0
    assert_out_has "專案"
}

@test "--json 的輸出是合法 JSON，而且帶得出身分與模式" {
    no_docker
    run cx_bin status --json
    assert_rc 0
    printf '%s' "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["project"], "project 是空的"
assert d["mode"] in ("dev", "test", "prod"), d["mode"]
assert "resolved" in d["runner"], d["runner"]
assert set(d["containers"]) == {"dev", "test", "prod"}, d["containers"]
' || _fail_with "JSON 不合法或缺欄位：$output"
}

@test "--short 只印一行" {
    no_docker
    run cx_bin status --short
    assert_rc 0
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ] \
        || _fail_with "--short 印了不只一行：$output"
}

@test "gitlink 同步與否要說得出來（不同步時要指向 cx git commit）" {
    load helpers/fixture
    make_submodule_repo stg >/dev/null
    run cx_bin status
    assert_rc 0
    assert_out_has "同步"

    # 讓子模組前進一個 commit，主庫的 gitlink 就落後了
    local g=(-c user.email=b@b -c user.name=b)
    echo x > "$CX_TEST_ROOT/backend/x.txt"
    git -C "$CX_TEST_ROOT/backend" "${g[@]}" add -A
    git -C "$CX_TEST_ROOT/backend" "${g[@]}" commit -q -m x

    run cx_bin status
    assert_rc 0
    # git status 只會說「有未提交的變更」，看不出是哪一種 —— status 要說得更清楚
    assert_out_has "cx git commit"
}

@test "status 不因為未知旗標而安靜地什麼都不做" {
    run cx_bin status --nosuchflag
    assert_rc "$EX_USAGE"
}
