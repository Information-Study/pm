#!/usr/bin/env bats
# ⑧ 專案識別：改名之後所有推導值都要跟著走

setup() {
    load helpers/common
    load helpers/fixture
}

@test "compose 專案名、網路名、sonar 專案都從 .cxroot 推導" {
    # docs/template.md 有一段手動的驗證 recipe，這裡把它自動化。
    make_root shop >/dev/null
    run env CX_ROOT="$CX_TEST_ROOT" bash -c "
        . '$CX_TEST_REAL_ROOT/bin/lib/common.sh'
        . '$CX_TEST_ROOT/.cxroot'
        echo \"P=\$(cx_project)\"
        echo \"DEV=\$(cx_project_for dev)\"
        echo \"SONAR=\$(cx_sonar_project)\"
        echo \"SONARNET=\$(cx_sonar_net)\""
    assert_rc 0
    assert_out_has "P=shop" "DEV=shop_dev" "SONAR=shop_devsecops" "SONARNET=shop_devsecops_net"
    assert_out_lacks "pm_dev" "pm_devsecops"
}

@test "python 子行程也讀得到專案名（它們看不到只被 source 的變數）" {
    # cx 會 export CX_PROJECT_NAME 就是為了這件事。曾經 waf_probe.py
    # 寫死 pm_test，於是專案改名之後探測會打到別的專案的堆疊。
    make_root shop2 >/dev/null
    run grep -l "CX_PROJECT_NAME" \
        "$CX_TEST_REAL_ROOT/bin/lib/waf_probe.py" \
        "$CX_TEST_REAL_ROOT/bin/lib/verify_checks.py"
    assert_rc 0
    run grep -c "export .*CX_PROJECT_NAME" "$CX_TEST_REAL_ROOT/cx"
    assert_rc 0
}

@test "fresh 的確認字串帶專案名（不是寫死 pm）" {
    make_root shop3 >/dev/null
    run grep -n "DESTROY" "$CX_TEST_REAL_ROOT/bin/cmd/fresh.sh"
    assert_rc 0
    assert_out_has "cx_project"
    assert_out_lacks "DESTROY pm\""
}

@test "push 白名單跟著改名走" {
    make_root shop4 >/dev/null
    run env CX_ROOT="$CX_TEST_ROOT" bash -c "
        . '$CX_TEST_REAL_ROOT/bin/lib/common.sh'
        . '$CX_TEST_ROOT/.cxroot'
        . '$CX_TEST_REAL_ROOT/bin/lib/guard.sh'
        cx_guard_allow_re"
    assert_rc 0
    assert_out_has "Bats-Org" "shop4" "shop4-backend" "shop4-frontend"
}

@test "archive 的 MANIFEST 記錄的是推導出來的專案名" {
    make_repo shop5 >/dev/null
    run cx_bin --yes fresh --mode backup-only
    assert_rc 0
    local arc; arc=$(cat "$CX_ARCHIVE_ROOT/LATEST")
    run grep "^project=" "$arc/MANIFEST.txt"
    assert_out_has "project=shop5"
}
