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
    mkdir -p "$CX_TEST_ROOT/src/backend/tests"
    cat > "$CX_TEST_ROOT/src/backend/tests/bootstrap.php" <<'PHP'
<?php
require __DIR__ . '/../vendor/autoload.php';
require_once __DIR__ . '/DatabaseSafetyGuard.php';
Tests\DatabaseSafetyGuard::assertProcessEnv();
PHP
    : > "$CX_TEST_ROOT/src/backend/tests/DatabaseSafetyGuard.php"
    printf '<phpunit bootstrap="vendor/autoload.php"></phpunit>\n' \
        > "$CX_TEST_ROOT/src/backend/phpunit.xml"

    run cx_bin verify cli
    assert_rc "$EX_FAIL"
    assert_out_has "GRD-wire"
}

@test "同一個缺陷修好之後就 PASS（雙向）" {
    mkdir -p "$CX_TEST_ROOT/src/backend/tests"
    cat > "$CX_TEST_ROOT/src/backend/tests/bootstrap.php" <<'PHP'
<?php
require __DIR__ . '/../vendor/autoload.php';
require_once __DIR__ . '/DatabaseSafetyGuard.php';
Tests\DatabaseSafetyGuard::assertProcessEnv();
PHP
    : > "$CX_TEST_ROOT/src/backend/tests/DatabaseSafetyGuard.php"
    printf '<phpunit bootstrap="tests/bootstrap.php"></phpunit>\n' \
        > "$CX_TEST_ROOT/src/backend/phpunit.xml"
    printf 'public function createApplication()\nDatabaseSafetyGuard::assertResolvedConfig\n' \
        > "$CX_TEST_ROOT/src/backend/tests/TestCase.php"

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
    mkdir -p "$CX_TEST_ROOT/docs/cx" "$CX_TEST_ROOT/docs/moved"
    printf "# ref\n" > "$CX_TEST_ROOT/docs/cx/cx-reference.md"
    run cx_bin verify docs
    assert_out_has "DOC-cx-verbs"

    # 搬到一個沒有人在讀的位置
    mv "$CX_TEST_ROOT/docs/cx/cx-reference.md" "$CX_TEST_ROOT/docs/moved/cx-reference.md"
    run cx_bin verify docs
    # 關鍵：那一列必須還在，而且是失敗的
    assert_out_has "DOC-cx-verbs"
    [[ $output == *"✘"*"DOC-cx-verbs"* ]] \
        || _fail_with "檔案搬走了，DOC-cx-verbs 卻沒有變紅：$output"
    # 而且要指出同名檔搬到哪裡去了 —— 「不見了」不夠，要能接著修
    [[ $output == *"docs/moved/cx-reference.md"* ]] \
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

# ── TUI-coverage 在模式門檻之下必須仍然證明得了東西 ────────────────────────
#
# 主選單開始依模式隱藏項目之後，靜態 regex 看不到 $_TUI_MODE ——
# 舊的算法（「整份 tui.sh 出現過哪些動詞」）會**照樣 PASS 但不再證明任何事**：
# 它會宣稱每個動詞都到得了，而 dev 模式下 scan 一個都到不了。
# 那比檢查變紅糟得多，因為沒有人會發現。所以這兩條案例盯的是「它真的會紅」。

@test "TUI-coverage：某動詞三個模式都到不了時要 FAIL" {
    cp "$CX_TEST_REAL_ROOT/bin/cmd/tui.sh" "$BATS_TEST_TMPDIR/tui.sh"
    # 把 test 模式那一段改成一個不存在的模式 —— scan 的唯一入口因此消失
    sed -i '0,/# @tui-mode: test/s//# @tui-mode: nosuchmode/' "$BATS_TEST_TMPDIR/tui.sh"
    mkdir -p "$CX_TEST_ROOT/bin/cmd"
    run bash -c "
        cd '$CX_TEST_REAL_ROOT'
        tmp=\$(mktemp -d); cp -r bin \"\$tmp/\"
        cp '$BATS_TEST_TMPDIR/tui.sh' \"\$tmp/bin/cmd/tui.sh\"
        cp .cxroot \"\$tmp/\" 2>/dev/null || true
        CX_ROOT=\"\$tmp\" CX_PROJECT_NAME=pm python3 bin/lib/verify_meta.py tui
        rm -rf \"\$tmp\"
    "
    [[ $output == *"FAIL|TUI-coverage"* ]] \
        || _fail_with "三個模式都到不了卻沒有變紅：$output"
    [[ $output == *"scan"* ]] || _fail_with "沒有指出是哪個動詞：$output"
}

@test "TUI-coverage：@tui-mode 標記不見時要 FAIL（不可以退回舊語意）" {
    run bash -c "
        cd '$CX_TEST_REAL_ROOT'
        tmp=\$(mktemp -d); cp -r bin \"\$tmp/\"
        sed -i 's/# @tui-mode: [a-z,]*//' \"\$tmp/bin/cmd/tui.sh\"
        cp .cxroot \"\$tmp/\" 2>/dev/null || true
        CX_ROOT=\"\$tmp\" CX_PROJECT_NAME=pm python3 bin/lib/verify_meta.py tui
        rm -rf \"\$tmp\"
    "
    [[ $output == *"FAIL|TUI-coverage"* ]] \
        || _fail_with "標記不見了卻沒有變紅：$output"
}

# ── cx fresh 用的範本也要擋得住祕密 ────────────────────────────────────────
#
# LAY-ignore 原本只驗 **live** 的 .gitignore，而 _fresh_git_init 會用
# templates/gitignore/main **覆蓋**它再 git add -A + commit。
# 也就是說 cx fresh（任何模式）／cx init／cx re-init 之後，真正生效的是範本。
#
# 2026-09-06 的安全審查實證重現：範本停在 v2（/ansible/…）而且從來沒有
# authorized_keys 那一條，套用之後三個祕密檔全部進索引 ——
# 而 cx git push 的祕密掃描擋不住它們（檔名與內容都不匹配任何 pattern），
# 三個 repo 都是 PUBLIC。

@test "LAY-ignore 會驗 cx fresh 用的 .gitignore 範本（不只 live 那一份）" {
    run bash -c "
        cd '$CX_TEST_REAL_ROOT'
        tmp=\$(mktemp -d); cp -r bin templates \"\$tmp/\"; cp .cxroot .gitignore \"\$tmp/\"
        git -C \"\$tmp\" init -q 2>/dev/null
        # 拿掉範本裡的 authorized_keys 那一條
        sed -i '/ansible-target\/authorized_keys/d' \"\$tmp/templates/gitignore/main\"
        CX_ROOT=\"\$tmp\" CX_PROJECT_NAME=pm python3 bin/lib/verify_meta.py cli
        rm -rf \"\$tmp\"
    "
    [[ $output == *"FAIL|LAY-ignore"* ]] \
        || _fail_with "範本少了祕密規則卻沒有變紅：$output"
    [[ $output == *"templates/gitignore/main"* ]] \
        || _fail_with "沒有指出是範本的問題：$output"
}

@test "範本套用之後，三個祕密檔都不會進索引（端到端重現）" {
    local t="$BATS_TEST_TMPDIR/tplrepro"
    mkdir -p "$t/env/ansible/inventory" "$t/env/docker/ansible-target"
    git -C "$t" init -q -b main
    printf 'ssh-ed25519 AAAA FAKE\n' > "$t/env/docker/ansible-target/authorized_keys"
    printf 'secret\n'                > "$t/env/ansible/vault_pass_backup"
    printf 'h: 1\n'                  > "$t/env/ansible/inventory/hosts.yml"

    # _fresh_git_init 做的就是這一步
    cp "$CX_TEST_REAL_ROOT/templates/gitignore/main" "$t/.gitignore"
    git -C "$t" add -A 2>/dev/null || true

    local staged
    staged=$(git -C "$t" diff --cached --name-only | grep -v '^\.gitignore$' || true)
    [ -z "$staged" ] \
        || _fail_with "範本擋不住這些祕密檔（cx git push 也掃不到它們）：
$staged"
}

# ── LAY-scaffold：cx fresh 重建骨架的目標路徑 ─────────────────────────────
#
# 2026-09-06 的實測結果：v3 遷移時四條重建路徑只改到一條，另外三條還在寫
# 裸的子模組名字。而重建排在 _fresh_delete **之後**，所以 cx init 會先把
# .git / .gitmodules / src/ / README.md 刪光，再死在
# `env -C "$CX_ROOT/src/backend"` 的 No such file or directory —— 樹毀了才失敗。
#
# 這個缺陷在「全綠」的狀態下存在了整個 v3 週期，原因有二：
#   ① LAY-legacy 認的是「路徑字面值」與「用裸名字組路徑」，
#      而這裡的裸名字是 composer / nuxi 的**位置參數**，沒有被拿去組路徑。
#   ② 唯一會踩到它的 80_init.bats 完整 init 平常被 CX_TEST_NETWORK 擋著。
#
# 所以這條檢查是靜態的、永遠會跑的那一道。

@test "LAY-scaffold 抓得到重建目標退回 v2 裸名字" {
    run bash -c "
        cd '$CX_TEST_REAL_ROOT'
        tmp=\$(mktemp -d); mkdir -p \"\$tmp/bin/cmd\" \"\$tmp/bin/lib\"
        cp -r bin/lib \"\$tmp/bin/\"; cp .cxroot \"\$tmp/\"
        cp bin/cmd/fresh.sh \"\$tmp/bin/cmd/fresh.sh\"
        # 把 backend 的產生器目標退回裸名字（v2）
        sed -i 's|composer create-project laravel/laravel \"\\\$rel\"|composer create-project laravel/laravel backend|' \\
            \"\$tmp/bin/cmd/fresh.sh\"
        CX_ROOT=\"\$tmp\" CX_PROJECT_NAME=pm python3 bin/lib/verify_meta.py cli
        rm -rf \"\$tmp\"
    "
    [[ $output == *"FAIL|LAY-scaffold"* ]] \
        || _fail_with "重建目標退回 v2 卻沒有變紅：$output"
    [[ $output == *"_fresh_rebuild_backend"* ]] \
        || _fail_with "沒有指出是哪一個函式：$output"
}

@test "LAY-scaffold 也抓得到 docker 的 workdir 退回 v2" {
    run bash -c "
        cd '$CX_TEST_REAL_ROOT'
        tmp=\$(mktemp -d); mkdir -p \"\$tmp/bin/cmd\"
        cp -r bin/lib \"\$tmp/bin/\"; cp .cxroot \"\$tmp/\"
        cp bin/cmd/fresh.sh \"\$tmp/bin/cmd/fresh.sh\"
        sed -i 's|-w \"/w/\\\$rel\"|-w /w/backend|' \"\$tmp/bin/cmd/fresh.sh\"
        CX_ROOT=\"\$tmp\" CX_PROJECT_NAME=pm python3 bin/lib/verify_meta.py cli
        rm -rf \"\$tmp\"
    "
    [[ $output == *"FAIL|LAY-scaffold"* ]] \
        || _fail_with "docker workdir 退回 v2 卻沒有變紅：$output"
}

@test "LAY-scaffold 在 regex 與 fresh.sh 對不上時要 FAIL（不可以安靜地什麼都不驗）" {
    # 「抓到 0 個目標」與「0 個目標有問題」在輸出上長得一模一樣。
    # 這條案例釘住的是：前者必須是 FAIL，不是 PASS。
    run bash -c "
        cd '$CX_TEST_REAL_ROOT'
        tmp=\$(mktemp -d); mkdir -p \"\$tmp/bin/cmd\"
        cp -r bin/lib \"\$tmp/bin/\"; cp .cxroot \"\$tmp/\"
        # 把兩個重建函式整個換掉，讓 regex 一個都抓不到
        printf '_fresh_rebuild_backend() {\n    :\n}\n_fresh_rebuild_frontend() {\n    :\n}\n' \\
            > \"\$tmp/bin/cmd/fresh.sh\"
        CX_ROOT=\"\$tmp\" CX_PROJECT_NAME=pm python3 bin/lib/verify_meta.py cli
        rm -rf \"\$tmp\"
    "
    [[ $output == *"FAIL|LAY-scaffold"* ]] \
        || _fail_with "一個目標都沒抓到卻 PASS —— 檢查已停止驗證：$output"
    [[ $output == *"停止驗證"* ]] \
        || _fail_with "訊息沒有說明這是「檢查壞了」而不是「程式碼壞了」：$output"
}

# ── ANS-dbname：應用程式資料庫不可與要被清掉的 test schema 撞名 ──────────
#
# roles/mysql 的 mysql_test_db_name 預設寫死是 test，而 mysql_app_db_name
# 來自 group_vars 的 db_name（= 專案名）。專案叫 test 的話兩者相同，
# 同一支 databases.yml 會先建立應用程式資料庫、稍後又對它下 state: absent。
#
# 第一次部署必然踩到：migration 在 deploy_backend 裡跑、排在 mysql 之後，
# 所以此刻 table_count 是 0 —— 「空的才准刪」那道 gate **會通過**。
#
# 但撞名本身無害，危險的是「撞名 **且** 允許 DROP」。所以這是三態，
# 而不是「撞名就紅」—— 後者會讓一個正當地叫 test 的專案連部署都做不了。

_dbname_fixture() {                 # _dbname_fixture <專案名> <drop:true|false>
    local n=$1 drop=$2 t="$BATS_TEST_TMPDIR/dbn-$n-$drop"
    mkdir -p "$t/env/ansible/inventory/group_vars/all" \
             "$t/env/ansible/roles/mysql/defaults" "$t/bin"
    cp -r "$CX_TEST_REAL_ROOT/bin/lib" "$t/bin/"
    cp "$CX_TEST_REAL_ROOT/.cxroot" "$t/"
    cp "$CX_TEST_REAL_ROOT/env/ansible/roles/mysql/defaults/main.yml" \
       "$t/env/ansible/roles/mysql/defaults/"
    sed -e "s|^db_name: &db_name \"pm\"|db_name: \&db_name \"$n\"|" \
        -e "s|^mysql_drop_test_db: .*|mysql_drop_test_db: $drop|" \
        "$CX_TEST_REAL_ROOT/env/ansible/inventory/group_vars/all/main.yml" \
        > "$t/env/ansible/inventory/group_vars/all/main.yml"
    printf '%s' "$t"
}

@test "ANS-dbname：撞名且 drop 打開 → FAIL" {
    local t; t=$(_dbname_fixture test true)
    run bash -c "CX_ROOT='$t' python3 '$CX_TEST_REAL_ROOT/bin/lib/verify_meta.py' docs"
    [[ $output == *"FAIL|ANS-dbname"* ]] \
        || _fail_with "撞名又允許 DROP 卻沒有變紅：$(grep -i dbname <<<"$output")"
}

@test "ANS-dbname：撞名但 drop 關著 → PASS，而且備註要講出這顆地雷" {
    local t; t=$(_dbname_fixture test false)
    run bash -c "CX_ROOT='$t' python3 '$CX_TEST_REAL_ROOT/bin/lib/verify_meta.py' docs"
    [[ $output == *"PASS|ANS-dbname"* ]] \
        || _fail_with "drop 關著卻擋下一個正當的專案名：$(grep -i dbname <<<"$output")"
    [[ $output == *"mysql_drop_test_db 關著所以無害"* ]] \
        || _fail_with "PASS 了但沒說明地雷還在：$(grep -i dbname <<<"$output")"
}

@test "ANS-dbname：沒撞名時就算 drop 打開也不該紅" {
    local t; t=$(_dbname_fixture shop true)
    run bash -c "CX_ROOT='$t' python3 '$CX_TEST_REAL_ROOT/bin/lib/verify_meta.py' docs"
    [[ $output == *"PASS|ANS-dbname"* ]] \
        || _fail_with "沒撞名卻紅了：$(grep -i dbname <<<"$output")"
}

@test "ANS-dbname：抓不到值時要 FAIL（不可以安靜地什麼都不驗）" {
    local t; t=$(_dbname_fixture shop false)
    sed -i '/^mysql_test_db_name:/d' "$t/env/ansible/roles/mysql/defaults/main.yml"
    run bash -c "CX_ROOT='$t' python3 '$CX_TEST_REAL_ROOT/bin/lib/verify_meta.py' docs"
    [[ $output == *"FAIL|ANS-dbname"* && $output == *"停止驗證"* ]] \
        || _fail_with "值不見了卻沒說檢查壞掉：$(grep -i dbname <<<"$output")"
}

# ── ANS-assert-ref：指路有沒有斷 ─────────────────────────────────────────
#
# ⚠ 這條檢查的能力邊界要一起釘住：它抓「指到不存在的檔」與「編號不在那個檔裡」，
#   但**抓不到「指到同一個檔裡的錯編號」**。2026-09-06 真正發生的就是後者
#   （寫 A16、該寫 A22，而 A16 在那個檔裡真的存在），是人讀輸出發現的。
#   第三條案例就是把這個邊界寫成測試 —— 免得有人以為全綠代表交叉引用都對。
#
# ⚠ fixture 必須含 env/ansible/site.yml：bin/lib/inventory.py 有一處正當的
#   「site.yml 的 A15」引用。少了它，前兩條案例會因為**那個**引用而變紅 ——
#   看起來過了，其實驗的不是自己要驗的東西。這個坑實際踩過。
_assertref_fixture() {              # _assertref_fixture → 印出 tmp 路徑
    local t; t=$(mktemp -d "$BATS_TEST_TMPDIR/aref-XXXX")
    mkdir -p "$t/bin/cmd" "$t/env/ansible/roles/m/tasks"
    cp -r "$CX_TEST_REAL_ROOT/bin/lib" "$t/bin/"
    cp "$CX_TEST_REAL_ROOT/.cxroot" "$t/"
    printf -- '- name: A15 —— 讓 inventory.py 那處正當引用解得開\n' > "$t/env/ansible/site.yml"
    printf -- '- name: A16 —— 上傳上限\n- name: A22 —— 資料庫撞名\n' \
        > "$t/env/ansible/roles/m/tasks/assert.yml"
    printf '%s' "$t"
}

@test "ANS-assert-ref：指到不存在的檔要 FAIL" {
    local t; t=$(_assertref_fixture)
    printf 'x() { : ; }\n# 見 roles/nope/tasks/assert.yml 的 A22\n' > "$t/bin/cmd/x.sh"
    run bash -c "CX_ROOT='$t' python3 '$CX_TEST_REAL_ROOT/bin/lib/verify_meta.py' docs"
    [[ $output == *"FAIL|ANS-assert-ref"* ]] \
        || _fail_with "指到不存在的檔卻沒紅：$(grep -i assert-ref <<<"$output")"
    # 必須是**我們造的**那一處，不是別的引用順便讓它紅
    [[ $output == *"roles/nope/tasks/assert.yml"* ]] \
        || _fail_with "紅的不是我們造的那一處：$(grep -i assert-ref <<<"$output")"
}

@test "ANS-assert-ref：編號不在被指名的檔裡要 FAIL" {
    local t; t=$(_assertref_fixture)
    printf 'x() { : ; }\n# 見 roles/m/tasks/assert.yml 的 A99\n' > "$t/bin/cmd/x.sh"
    run bash -c "CX_ROOT='$t' python3 '$CX_TEST_REAL_ROOT/bin/lib/verify_meta.py' docs"
    [[ $output == *"FAIL|ANS-assert-ref"* && $output == *"沒有 A99"* ]] \
        || _fail_with "編號不在那個檔裡卻沒紅：$(grep -i assert-ref <<<"$output")"
}

@test "ANS-assert-ref：同檔錯編號抓不到 —— 這是已知邊界，不是缺陷" {
    local t; t=$(_assertref_fixture)
    # 指到 A16，但該指的是 A22 —— 兩個都在同一個檔裡，所以這條檢查看不出來
    printf 'x() { : ; }\n# 見 roles/m/tasks/assert.yml 的 A16\n' > "$t/bin/cmd/x.sh"
    run bash -c "CX_ROOT='$t' python3 '$CX_TEST_REAL_ROOT/bin/lib/verify_meta.py' docs"
    [[ $output == *"PASS|ANS-assert-ref"* ]] \
        || _fail_with "這條案例的用途是釘住能力邊界，它應該 PASS：$(grep -i assert-ref <<<"$output")"
}
