#!/usr/bin/env bats
# ⑨ PASS / FAIL / SKIP 的語意
#
# 這個專案的核心原則是「沒跑過的就寫沒跑過」。SKIP 不等於 PASS，
# 而且 SKIP 不能讓退出碼變成成功以外的東西 —— 兩者都要測。

setup() {
    load helpers/common
    load helpers/fixture
    make_root vf >/dev/null
}

@test "cli / docs / tui 三個範圍在什麼都沒裝的樹上就跑得完" {
    # 這是那三個範圍存在的理由：全新 clone、沒有 .env、沒有 Docker。
    no_docker
    run cx_bin verify cli docs tui
    assert_rc 0
    assert_out_has "通過"
}

@test "報告會寫出來，而且區分三種結果" {
    local rep="$BATS_TEST_TMPDIR/r.md"
    run cx_bin verify cli --report "$rep"
    assert_rc 0
    [ -f "$rep" ] || _fail_with "沒有產生報告"
    run cat "$rep"
    assert_out_has "通過" "失敗" "未驗"
    # 報告的footer 必須寫明 SKIP 不等於通過
    assert_out_has "不等於通過"
}

@test "SKIP 不會讓 verify 失敗（環境不足不是缺陷）" {
    # runtime 需要容器；沒有容器時它應該 SKIP 而不是 FAIL。
    no_docker
    run cx_bin verify cli
    assert_rc 0
}

@test "未知範圍要拒絕，而不是安靜地什麼都不驗" {
    run cx_bin verify not-a-scope
    assert_rc "$EX_USAGE"
}

@test "有 FAIL 時退出碼是 EX_FAIL（正向對照：故意製造一個缺陷）" {
    # 不能只靠「fixture 缺東西」—— 缺東西的檢查會 SKIP 或空過，
    # 那樣測到的是「沒有東西可驗」而不是「驗出問題會失敗」。
    # 這裡刻意做出 GRD-wire 要抓的那個缺陷：防護檔案在，但 phpunit.xml
    # 沒有指向它（就是 cx fresh --mode carryover 會造成的那個狀態）。
    mkdir -p "$CX_TEST_ROOT/backend/tests"
    cat > "$CX_TEST_ROOT/backend/tests/bootstrap.php" <<'PHP'
<?php
require __DIR__ . '/../vendor/autoload.php';
require_once __DIR__ . '/DatabaseSafetyGuard.php';
Tests\DatabaseSafetyGuard::assertProcessEnv();
PHP
    : > "$CX_TEST_ROOT/backend/tests/DatabaseSafetyGuard.php"
    printf '<phpunit bootstrap="vendor/autoload.php"></phpunit>\n' \
        > "$CX_TEST_ROOT/backend/phpunit.xml"

    run cx_bin verify cli
    assert_rc "$EX_FAIL"
    assert_out_has "GRD-wire"
}

@test "同一個缺陷修好之後就 PASS（雙向）" {
    mkdir -p "$CX_TEST_ROOT/backend/tests"
    cat > "$CX_TEST_ROOT/backend/tests/bootstrap.php" <<'PHP'
<?php
require __DIR__ . '/../vendor/autoload.php';
require_once __DIR__ . '/DatabaseSafetyGuard.php';
Tests\DatabaseSafetyGuard::assertProcessEnv();
PHP
    : > "$CX_TEST_ROOT/backend/tests/DatabaseSafetyGuard.php"
    printf '<phpunit bootstrap="tests/bootstrap.php"></phpunit>\n' \
        > "$CX_TEST_ROOT/backend/phpunit.xml"
    printf 'public function createApplication()\nDatabaseSafetyGuard::assertResolvedConfig\n' \
        > "$CX_TEST_ROOT/backend/tests/TestCase.php"

    run cx_bin verify cli
    assert_out_has "GRD-wire"
    assert_out_lacks "✘ GRD-wire"
}

@test "verify 的三值是由 _vf 統一產生的（不是各寫各的）" {
    run grep -c "_vf \(PASS\|FAIL\|SKIP\)" "$CX_TEST_REAL_ROOT/bin/cmd/verify.sh"
    assert_rc 0
    [ "${output:-0}" -gt 20 ] || _fail_with "_vf 的呼叫點太少，可能有人繞過它"
}

@test "verify_meta.py 的輸出格式與 verify.sh 的解析一致（管線分隔）" {
    # 兩邊用不同分隔符是真實存在的陷阱：verify_meta 用 |，verify_checks 用 tab。
    run env CX_ROOT="$CX_TEST_REAL_ROOT" python3 \
        "$CX_TEST_REAL_ROOT/bin/lib/verify_meta.py" cli
    assert_rc 0
    # 每一行都要是 ST|id|title|note 四欄
    run bash -c "env CX_ROOT='$CX_TEST_REAL_ROOT' python3 \
        '$CX_TEST_REAL_ROOT/bin/lib/verify_meta.py' cli \
        | awk -F'|' 'NF<3 {print \"BAD:\" \$0}' | head -3"
    assert_out_lacks "BAD:"
}

# ── 「檢查那一列消失」是唯一不會變紅的失效形態 ─────────────────────────────
#
# cx verify 的退出碼只看 FAIL 的數量。所以必填文件被搬走之後，
# 如果檢查是寫成 `if read(...):` 就會整列從報告裡不見 —— 報告仍然全綠，
# 而「每個動詞都有文件」這件事不再被驗證。少一列比多一列紅難發現得多。

@test "必填文件被搬走時，DOC-cx-verbs 是 FAIL 而不是整列消失" {
    mkdir -p "$CX_TEST_ROOT/docs/cx"
    printf '# ref\n' > "$CX_TEST_ROOT/docs/cx-reference.md"
    run cx_bin verify docs
    assert_out_has "DOC-cx-verbs"

    mv "$CX_TEST_ROOT/docs/cx-reference.md" "$CX_TEST_ROOT/docs/cx/cx-reference.md"
    run cx_bin verify docs
    # 關鍵：那一列必須還在，而且是失敗的
    assert_out_has "DOC-cx-verbs"
    [[ $output == *"✘"*"DOC-cx-verbs"* ]] \
        || _fail_with "檔案搬走了，DOC-cx-verbs 卻沒有變紅：$output"
    # 而且要指出同名檔搬到哪裡去了 —— 「不見了」不夠，要能接著修
    [[ $output == *"docs/cx/cx-reference.md"* ]] \
        || _fail_with "沒有指出同名檔的新位置：$output"
}

@test "TPL-group 抓得到 inventory.py 把群組名寫死（三方一致，不是兩方）" {
    # cx rename 的改名清單裡沒有 inventory.py。它寫死 pm_servers 的話，
    # 改名後產生的 hosts.yml 會對不上 site.yml，而 ansible 對「比對不到
    # 任何主機」只印 warning 並回 0 —— cx deploy 靜默地什麼都不做卻成功。
    run grep -c 'SERVERS_GROUP' "$CX_TEST_REAL_ROOT/bin/lib/inventory.py"
    assert_rc 0
    run grep -E '^SERVERS_GROUP\s*=\s*f"\{PROJECT\}_servers"' \
        "$CX_TEST_REAL_ROOT/bin/lib/inventory.py"
    assert_rc 0
    # 反向：TPL-group 的訊息要提到 inventory.py，否則它沒有真的在看第三方
    run grep -q 'inventory.py' "$CX_TEST_REAL_ROOT/bin/lib/verify_meta.py"
    assert_rc 0
}
