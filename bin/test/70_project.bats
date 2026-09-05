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

# ── cx rename ────────────────────────────────────────────────────────────────
#
# rename 會改寫專案身分。fixture 用完整的檔案集（不是 symlink 到真的樹），
# 否則 sed -i 會改到真正的專案。_rename_fixture 只造出 rename 會碰的那幾個檔。
_rename_fixture() {                 # _rename_fixture <目前的名字>
    local n=${1:?}
    make_root "$n" >/dev/null
    printf 'PROJECT_SLUG=%s\nIMAGE_PREFIX=%s\n' "$n" "$n" > "$CX_TEST_ROOT/.env"
    cp "$CX_TEST_ROOT/.env" "$CX_TEST_ROOT/.env.example"
    printf 'sonar.projectKey=%s\nsonar.projectName=%s\n' "$n" "$n" \
        > "$CX_TEST_ROOT/sonar-project.properties"
    mkdir -p "$CX_TEST_ROOT/env/ansible/inventory/group_vars/all" \
             "$CX_TEST_ROOT/env/ansible/roles/demo/defaults" \
             "$CX_TEST_ROOT/env/ansible/playbooks"
    cat > "$CX_TEST_ROOT/env/ansible/inventory/group_vars/all/main.yml" <<YML
ansible_managed: "來源：$n 專案的 ansible/"
app_name: "$n"
app_slug: "$n"
db_name: &db_name "$n"
db_user: &db_user "$n"
app_repo: "https://github.com/Org/$n.git"
backend_repo: "https://github.com/Org/$n-backend.git"
YML
    printf -- '- name: %s | 部署\n  hosts: %s_servers\n' "$n" "$n" \
        > "$CX_TEST_ROOT/env/ansible/site.yml"
    printf 'app_slug: "%s"\n' "$n" > "$CX_TEST_ROOT/env/ansible/roles/demo/defaults/main.yml"
    # deploy.sh 是 symlink 進來的真檔，rename 會想改它 —— 換成本地副本，
    # 否則測試會 sed 到真正的 bin/cmd/deploy.sh。
    rm -f "$CX_TEST_ROOT/bin"
    mkdir -p "$CX_TEST_ROOT/bin/cmd"
    cp -r "$CX_TEST_REAL_ROOT/bin/lib" "$CX_TEST_REAL_ROOT/bin/completion" "$CX_TEST_ROOT/bin/"
    cp "$CX_TEST_REAL_ROOT"/bin/cmd/*.sh "$CX_TEST_ROOT/bin/cmd/"
    printf 'cmd_deploy_main() { : ; }\n# --list-hosts %s_servers\n' "$n" \
        > "$CX_TEST_ROOT/bin/cmd/deploy.sh"
}

@test "rename 拒絕不合法的名稱（會被拼成網路名與 MySQL 帳號名）" {
    _rename_fixture old1
    for bad in "Shop" "9shop" "a" "sh op" "shop!" ""; do
        run cx_raw --root "$CX_TEST_ROOT" --yes rename "$bad"
        [[ $status -eq 2 ]] || {
            printf '名稱 %q 應被拒絕（EX_USAGE=2），實際 rc=%s\n' "$bad" "$status" >&2
            return 1; }
    done
}

@test "rename 拒絕改成同一個名字" {
    _rename_fixture old2
    run cx_raw --root "$CX_TEST_ROOT" --yes rename old2
    assert_rc 2
}

@test "rename 的 dry-run 列出變更點但一個位元組都不改" {
    _rename_fixture old3
    local before after
    before=$(find "$CX_TEST_ROOT" -type f ! -path '*/bin/*' -printf '%p %s\n' | sort | sha256sum)
    run cx_raw --root "$CX_TEST_ROOT" --dry-run rename shop
    assert_rc 0
    assert_out_has ".cxroot" ".env" "sonar-project.properties" "dry-run"
    after=$(find "$CX_TEST_ROOT" -type f ! -path '*/bin/*' -printf '%p %s\n' | sort | sha256sum)
    [[ $before == "$after" ]] || { echo "dry-run 改到檔案了" >&2; return 1; }
}

@test "rename 真的改名之後，每一個身分來源都跟著走" {
    _rename_fixture old4
    run cx_raw --root "$CX_TEST_ROOT" --yes rename shop
    assert_rc 0
    run grep -h '^CX_PROJECT_NAME=' "$CX_TEST_ROOT/.cxroot"
    assert_out_has "CX_PROJECT_NAME=shop"
    run grep -h '^CX_REPO_BACKEND=' "$CX_TEST_ROOT/.cxroot"
    assert_out_has "shop-backend"
    run cat "$CX_TEST_ROOT/.env"
    assert_out_has "PROJECT_SLUG=shop" "IMAGE_PREFIX=shop"
    assert_out_lacks "=old4"
    run cat "$CX_TEST_ROOT/sonar-project.properties"
    assert_out_has "sonar.projectKey=shop"
    run cat "$CX_TEST_ROOT/env/ansible/inventory/group_vars/all/main.yml"
    assert_out_has 'app_slug: "shop"' 'db_name: &db_name "shop"' "Org/shop-backend.git" "來源：shop 專案的"
    assert_out_lacks "old4"
    run cat "$CX_TEST_ROOT/env/ansible/site.yml"
    assert_out_has "hosts: shop_servers" "name: shop |"
    run cat "$CX_TEST_ROOT/env/ansible/roles/demo/defaults/main.yml"
    assert_out_has 'app_slug: "shop"'
}

@test "rename 不碰 .git" {
    _rename_fixture old5
    mkdir -p "$CX_TEST_ROOT/.git"
    printf 'sentinel\n' > "$CX_TEST_ROOT/.git/HEAD"
    run cx_raw --root "$CX_TEST_ROOT" --yes rename shop
    assert_rc 0
    [[ -f $CX_TEST_ROOT/.git/HEAD ]] || { echo ".git 被動到了" >&2; return 1; }
    run cat "$CX_TEST_ROOT/.git/HEAD"
    assert_out_has "sentinel"
}

@test "setup env 的身分只認 .cxroot，不認 .env.example 裡的現值" {
    # _setup_env 原本比對整行字面值（'PROJECT_SLUG=pm'），等於把「範本裡目前
    # 的值」變成第二事實來源：只要有人改過 .env.example（cx rename 就會改），
    # 那兩個 case 就再也比不到，產生出來的 .env 會靜默沿用範本裡的舊值。
    make_root drifted >/dev/null
    printf 'PROJECT_SLUG=someoneelse\nIMAGE_PREFIX=someoneelse\nAPP_UID=1000\n' \
        > "$CX_TEST_ROOT/.env.example"
    run cx_raw --root "$CX_TEST_ROOT" setup env
    assert_rc 0
    run cat "$CX_TEST_ROOT/.env"
    assert_out_has "PROJECT_SLUG=drifted" "IMAGE_PREFIX=drifted"
    assert_out_lacks "someoneelse"
}

@test "branch new 預設從 dev 開，不是從你剛好在的地方" {
    # usage 與 cx-reference 都寫「預設從 dev 開」，而實作原本是裸的
    # `switch -c <名稱>` —— 也就是從 HEAD 開。文件與實作相反，
    # 而且只有在 dev 落後 main 的時候才看得出來。
    make_root gitflow >/dev/null
    rm -f "$CX_TEST_ROOT/bin"
    mkdir -p "$CX_TEST_ROOT/bin"
    cp -r "$CX_TEST_REAL_ROOT/bin/lib" "$CX_TEST_REAL_ROOT/bin/completion" "$CX_TEST_ROOT/bin/"
    mkdir -p "$CX_TEST_ROOT/bin/cmd"
    cp "$CX_TEST_REAL_ROOT"/bin/cmd/*.sh "$CX_TEST_ROOT/bin/cmd/"
    printf 'bin\ncx\n.cxroot\nbackend\nfrontend\n' > "$CX_TEST_ROOT/.gitignore"
    local d
    for d in . backend frontend; do
        git -C "$CX_TEST_ROOT/$d" init -q -b main
        git -C "$CX_TEST_ROOT/$d" config user.name t
        git -C "$CX_TEST_ROOT/$d" config user.email t@t.co
        [[ $d == . ]] || cp "$CX_TEST_ROOT/.gitignore" "$CX_TEST_ROOT/$d/.gitignore"
        echo a > "$CX_TEST_ROOT/$d/f"
        git -C "$CX_TEST_ROOT/$d" add -A
        git -C "$CX_TEST_ROOT/$d" commit -qm base
        git -C "$CX_TEST_ROOT/$d" branch dev
        # 讓 main 前進，這樣 HEAD 與 dev 才分得出來
        echo b > "$CX_TEST_ROOT/$d/f"
        git -C "$CX_TEST_ROOT/$d" add -A
        git -C "$CX_TEST_ROOT/$d" commit -qm "main 又前進了"
    done
    run cx_raw --root "$CX_TEST_ROOT" --yes git branch new fix/from-dev
    assert_rc 0
    local dev_sha new_sha main_sha
    dev_sha=$(git -C "$CX_TEST_ROOT" rev-parse dev)
    new_sha=$(git -C "$CX_TEST_ROOT" rev-parse fix/from-dev)
    main_sha=$(git -C "$CX_TEST_ROOT" rev-parse main)
    [[ $new_sha == "$dev_sha" ]] || {
        echo "新分支指向 $new_sha，dev 是 $dev_sha，main 是 $main_sha" >&2
        echo "→ 沒有從 dev 開" >&2; return 1; }
}

@test "branch new 的 --from 覆蓋 dev 這個預設" {
    make_root gitflow2 >/dev/null
    rm -f "$CX_TEST_ROOT/bin"
    mkdir -p "$CX_TEST_ROOT/bin/cmd"
    cp -r "$CX_TEST_REAL_ROOT/bin/lib" "$CX_TEST_REAL_ROOT/bin/completion" "$CX_TEST_ROOT/bin/"
    cp "$CX_TEST_REAL_ROOT"/bin/cmd/*.sh "$CX_TEST_ROOT/bin/cmd/"
    printf 'bin\ncx\n.cxroot\nbackend\nfrontend\n' > "$CX_TEST_ROOT/.gitignore"
    local d
    for d in . backend frontend; do
        git -C "$CX_TEST_ROOT/$d" init -q -b main
        git -C "$CX_TEST_ROOT/$d" config user.name t
        git -C "$CX_TEST_ROOT/$d" config user.email t@t.co
        [[ $d == . ]] || cp "$CX_TEST_ROOT/.gitignore" "$CX_TEST_ROOT/$d/.gitignore"
        echo a > "$CX_TEST_ROOT/$d/f"
        git -C "$CX_TEST_ROOT/$d" add -A
        git -C "$CX_TEST_ROOT/$d" commit -qm base
        git -C "$CX_TEST_ROOT/$d" branch dev
        echo b > "$CX_TEST_ROOT/$d/f"
        git -C "$CX_TEST_ROOT/$d" add -A
        git -C "$CX_TEST_ROOT/$d" commit -qm advance
    done
    # ⚠ 分支名刻意用 chore/ 而不是 hotfix/。2026-09-06 加入 cx git hotfix 之後，
    #   hotfix/* 與 feature/* 一樣在主庫被拒絕（finish 只看子模組，在主庫開等於
    #   永遠合不回去）。這條案例測的是 --from，不是那個防護 ——
    #   拿受保護的前綴來當「隨便一個分支名」會讓它測到別的東西。
    #   防護本身由 72_gitflow.bats 的「branch new hotfix/* 在主庫要被拒絕」蓋。
    run cx_raw --root "$CX_TEST_ROOT" --yes git branch new chore/x --from main
    assert_rc 0
    [[ $(git -C "$CX_TEST_ROOT" rev-parse chore/x) == $(git -C "$CX_TEST_ROOT" rev-parse main) ]] \
        || { echo "--from main 沒有生效" >&2; return 1; }
}

# ── deploy hosts：前後端分機的群組模型 ────────────────────────────────────
#
# bin/lib/inventory.py 編碼了全部的部署拓撲不變式（db_primary 剛好一台、
# 必須在 web_backend 裡、web 是兩個子群組的聯集），但在 2026-09-06 之前
# **零測試覆蓋**。這些是純函式，不需要 ansible 也不需要主機。

_inv() {                            # _inv <子指令...>
    CX_PROJECT_NAME=pm python3 "$CX_TEST_REAL_ROOT/bin/lib/inventory.py" \
        --path "$BATS_TEST_TMPDIR/hosts.yml" "$@"
}
# add 做完會自己跑一次 check，而「只加了一台前端」這種**中間狀態**本來就不合法
#（web_backend 是空的）。那個非 0 是對的行為，不是這幾條案例要測的東西 ——
# 所以建構拓撲的步驟用這個，最後才明確 run _inv check。
_inv_q() { _inv "$@" >/dev/null 2>&1 || true; }

@test "deploy hosts：單機拓撲預設一台同時跑前端、後端與資料庫" {
    _inv_q init --env production
    _inv_q add solo --ip 10.0.0.1 --user ubuntu
    run _inv check
    assert_rc 0
    run cat "$BATS_TEST_TMPDIR/hosts.yml"
    assert_out_has "web_frontend" "web_backend" "db_primary"
}

@test "deploy hosts：web 是兩個子群組的 children 聯集（不是自己列 hosts）" {
    # 這是整個拆分能成立的關鍵 —— site.yml 裡既有的 groups['web'] gate
    #（nginx / certbot / healthcheck）因此完全不用改。
    _inv_q init --env production
    _inv_q add fe1 --ip 10.0.0.1 --no-be --no-db
    _inv_q add be1 --ip 10.0.0.2 --no-fe --be --db
    run python3 -c "
import yaml, sys
d = yaml.safe_load(open('$BATS_TEST_TMPDIR/hosts.yml'))
web = d['all']['children']['web']
assert 'children' in web, 'web 應該用 children，實際是：%r' % web
assert set(web['children']) == {'web_frontend', 'web_backend'}, web['children']
assert 'hosts' not in web, 'web 不應該自己列 hosts'
print('OK')
"
    assert_rc 0
}

@test "deploy hosts：db_primary 不在 web_backend 裡要回非 0（A15）" {
    # migration 在 deploy_backend role 內、用 db_primary gate；
    # deploy_backend 只在 web_backend 跑。對不上就等於沒人跑 migration，
    # 而且 ansible 全綠。
    _inv_q init --env production
    _inv_q add fe1 --ip 10.0.0.1 --no-be --db
    run _inv check
    [ "$status" -ne 0 ] || _fail_with "db_primary 不在 web_backend，check 卻通過了"
    assert_out_has "web_backend"
}

@test "deploy hosts：真的分機時要警告兩個會讓拓撲不會動的預設值" {
    _inv_q init --env production
    _inv_q add fe1 --ip 10.0.0.1 --no-be --no-db
    _inv_q add be1 --ip 10.0.0.2 --no-fe --be --db
    run _inv check
    assert_rc 0
    # 不警告的話，症狀會是「部署全綠、網站 502」，而原因在兩個沒人動過的預設值上
    assert_out_has "php_fpm_listen"
    assert_out_has "frontend_host"
}

@test "deploy hosts：讀得懂只有 web 的舊格式（向後相容）" {
    # hosts.yml 不進版控，沒有 diff 會提醒，也沒有還原點 ——
    # 一個讀不懂舊檔的 load() 會把使用者的主機清單靜默改形狀。
    cat > "$BATS_TEST_TMPDIR/hosts.yml" <<'YML'
---
all:
  children:
    production:
      hosts:
        old1:
          ansible_host: 10.0.0.9
          ansible_user: ubuntu
    pm_servers:
      children:
        production: {}
    web:
      hosts:
        old1: {}
    db_primary:
      hosts:
        old1: {}
YML
    run _inv show
    assert_rc 0
    # 只有 web 的舊檔讀作「前後端都是」
    assert_out_has "old1"
    run _inv check
    assert_rc 0
}

@test "deploy hosts：--web 是「兩邊一起」的捷徑，--no-be 仍然覆寫得掉" {
    _inv_q init --env production
    _inv_q add h1 --ip 10.0.0.1 --web --no-be --no-db
    run python3 -c "
import yaml
d = yaml.safe_load(open('$BATS_TEST_TMPDIR/hosts.yml'))['all']['children']
fe = (d.get('web_frontend') or {}).get('hosts') or {}
be = (d.get('web_backend')  or {}).get('hosts') or {}
assert 'h1' in fe, '--web 沒有讓它進 web_frontend'
assert 'h1' not in be, '--no-be 沒有覆寫掉 --web'
print('OK')
"
    assert_rc 0
}
