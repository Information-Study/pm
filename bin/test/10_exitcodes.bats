#!/usr/bin/env bats
# ② 退出碼契約
#
# 這些數字是**對外的**契約：CI 會拿去分支判斷「掃描器有意見」與「掃描器當掉」。
# 所以要有恰好一個地方硬編碼它們，而那個地方應該是測試，不是文件。

setup() {
    load helpers/common
    load helpers/fixture
    make_root >/dev/null
}

@test "EX_* 的數值就是契約本身" {
    [ "$EX_OK" -eq 0 ]
    [ "$EX_FAIL" -eq 1 ]
    [ "$EX_USAGE" -eq 2 ]
    [ "$EX_PRECOND" -eq 3 ]
    [ "$EX_ABORT" -eq 4 ]
    [ "$EX_SCAN_QUALITY" -eq 20 ]
    [ "$EX_SCAN_SAST" -eq 21 ]
    [ "$EX_SCAN_SCA" -eq 22 ]
    [ "$EX_SCAN_DAST" -eq 23 ]
}

@test "四個 scan 退出碼互不相同" {
    local n; n=$(printf '%s\n' "$EX_SCAN_QUALITY" "$EX_SCAN_SAST" \
                 "$EX_SCAN_SCA" "$EX_SCAN_DAST" | sort -u | wc -l)
    [ "$n" -eq 4 ]
}

@test "EX_USAGE：打錯的子指令" {
    run cx_bin scan bogus;            assert_rc "$EX_USAGE"
    run cx_bin verify bogus-scope;    assert_rc "$EX_USAGE"
    run cx_bin test bogus-sub;        assert_rc "$EX_USAGE"
    run cx_bin fresh --phase bogus;   assert_rc "$EX_USAGE"
    run cx_bin fresh --mode bogus;    assert_rc "$EX_USAGE"
    run cx_bin acl bogus;             assert_rc "$EX_USAGE"
}

@test "EX_USAGE：usage 沒宣傳的旗標要被拒絕" {
    run cx_bin scan --fail-on-findings
    assert_rc "$EX_USAGE"
}

@test "EX_PRECOND：--runner docker 但 daemon 不通時硬失敗，不偷偷退回原生" {
    no_docker
    run cx_bin --runner docker php -v
    assert_rc "$EX_PRECOND"
    assert_out_has "--runner native"
}

@test "EX_PRECOND：同一個專案不能有兩個 cx 同時跑（flock）" {
    need_cmd flock
    mkdir -p "$CX_TEST_ROOT/.cx"
    # 背景持有鎖，前景應該取不到
    flock -x "$CX_TEST_ROOT/.cx/lock.fresh" -c 'sleep 5' &
    local holder=$!
    sleep 0.3
    run cx_bin --yes fresh --phase preflight
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    assert_rc "$EX_PRECOND"
    assert_out_has "另一個 cx"
}
