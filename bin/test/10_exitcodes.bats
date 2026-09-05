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

# ── 模式覆寫檔缺席必須硬失敗，不可以靜默略過 ───────────────────────────────
#
# 原本 .env 與 <mode>.env 共用同一個 `[[ -f $f ]] && ...` 迴圈，於是路徑寫錯
# 一個字，compose 只是少一個 --env-file 而不會失敗：EDGE_HTTP_PORT /
# PHPMYADMIN_PORT / APP_TARGET / MODSEC_RULE_ENGINE 全部落回 compose 裡的
# ${VAR:-預設}，三個模式搶同一組埠，或更糟 —— test 的 WAF 引擎值變成別的。
# 兩個檔的缺席語意不一樣，所以不可以共用同一個判斷。

@test "缺少 env/docker/compose/<mode>.env 時 compose 動作硬失敗（EX_PRECOND）" {
    add_compose_skeleton
    rm -f "$CX_TEST_ROOT/env/docker/compose/dev.env"
    run cx_bin --dry-run ps
    assert_rc "$EX_PRECOND"
    assert_out_has "模式覆寫檔"
    # 訊息要說明**為什麼**這是致命的，否則下一個人會以為補個空檔就好
    assert_out_has "搶埠"
}

@test "缺少根 .env 不算錯（cx setup env 之前它合法不存在）" {
    add_compose_skeleton
    rm -f "$CX_TEST_ROOT/.env"
    run cx_bin --dry-run ps
    assert_rc 0
}
