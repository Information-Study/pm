#!/usr/bin/env bash
# 拋棄式的 CX_ROOT。
#
# cx --root <目錄> 只要求該目錄有 .cxroot（cx:73-79），其餘全部從
# $CX_ROOT/bin/ 載入。所以把真的 bin/ 與 cx symlink 進來，
# 跑的就是**真正的程式碼**，對的是一棵假的樹。
#
# _fresh_nuke 拒絕 symlink（fresh.sh 的護欄），而 bin 又在 FRESH_PRESERVE 裡，
# 所以那兩個 symlink 不會有被刪掉的風險。

# 每一個會動到檔案的測試都要先過這一關。
# 沒有它的話，一個寫錯的 CX_TEST_ROOT 會讓破壞性測試打到真的專案樹。
_assert_disposable() {
    local r=${1:?}
    case $r in
        "$BATS_TEST_TMPDIR"/*|"$BATS_FILE_TMPDIR"/*|"$BATS_RUN_TMPDIR"/*) : ;;
        *) printf 'REFUSING: CX_TEST_ROOT 不在 bats 的臨時目錄底下：%s\n' "$r" >&2
           return 1 ;;
    esac
    [[ $r != "$CX_TEST_REAL_ROOT" ]] || {
        printf 'REFUSING: CX_TEST_ROOT 等於真正的專案樹\n' >&2; return 1; }
}

# 最小 fixture：能跑不動檔案的動詞（help / doctor / 旗標解析 / 補全）
make_root() {                       # make_root [專案名]
    local name=${1:-bats$RANDOM}
    CX_TEST_ROOT="$BATS_TEST_TMPDIR/root-$name"
    _assert_disposable "$CX_TEST_ROOT" || return 1
    mkdir -p "$CX_TEST_ROOT"
    cat > "$CX_TEST_ROOT/.cxroot" <<CXR
CX_PROJECT_NAME=$name
CX_LAYOUT_VERSION=2
CX_GH_ORG=Bats-Org
CX_REPO_MAIN=$name
CX_REPO_BACKEND=$name-backend
CX_REPO_FRONTEND=$name-frontend
CXR
    ln -s "$CX_TEST_REAL_ROOT/bin" "$CX_TEST_ROOT/bin"
    ln -s "$CX_TEST_REAL_ROOT/cx"  "$CX_TEST_ROOT/cx"
    # 最小的前後端骨架。沒有它們的話，art / composer / npm 會在**前置檢查**
    # 就結束（「找不到 backend/composer.json」），根本走不到 runner 判斷 ——
    # 於是測 runner 的案例會因為完全無關的理由失敗。
    mkdir -p "$CX_TEST_ROOT/backend" "$CX_TEST_ROOT/frontend"
    printf '{"name":"bats/backend"}\n'  > "$CX_TEST_ROOT/backend/composer.json"
    printf '{"name":"bats-frontend"}\n' > "$CX_TEST_ROOT/frontend/package.json"
    : > "$CX_TEST_ROOT/backend/artisan"
    export CX_TEST_ROOT
    printf '%s' "$CX_TEST_ROOT"
}

# 完整 fixture：真的 git repo，給破壞性測試（fresh / archive）用。
# 這個要用真的目錄而不是 symlink，因為 fresh 會刪它。
make_repo() {                       # make_repo [專案名]
    local name=${1:-bats$RANDOM}
    CX_TEST_ROOT="$BATS_TEST_TMPDIR/repo-$name"
    _assert_disposable "$CX_TEST_ROOT" || return 1
    mkdir -p "$CX_TEST_ROOT"
    cat > "$CX_TEST_ROOT/.cxroot" <<CXR
CX_PROJECT_NAME=$name
CX_LAYOUT_VERSION=2
CX_GH_ORG=Bats-Org
CX_REPO_MAIN=$name
CX_REPO_BACKEND=$name-backend
CX_REPO_FRONTEND=$name-frontend
CXR
    ln -s "$CX_TEST_REAL_ROOT/bin" "$CX_TEST_ROOT/bin"
    ln -s "$CX_TEST_REAL_ROOT/cx"  "$CX_TEST_ROOT/cx"
    # fresh 會找這些
    mkdir -p "$CX_TEST_ROOT"/{docker/legacy,templates/gitignore,docs,reports,ansible,.vscode}
    : > "$CX_TEST_ROOT/claude.md"; : > "$CX_TEST_ROOT/.gitignore"
    : > "$CX_TEST_ROOT/.env"; : > "$CX_TEST_ROOT/.env.example"
    : > "$CX_TEST_ROOT/.semgrepignore"; : > "$CX_TEST_ROOT/sonar-project.properties"
    : > "$CX_TEST_ROOT/README.md"; : > "$CX_TEST_ROOT/docker-compose.yml"
    : > "$CX_TEST_ROOT/.dockerignore"

    local c
    for c in . backend frontend; do
        mkdir -p "$CX_TEST_ROOT/$c"
        echo "content-$c" > "$CX_TEST_ROOT/$c/file.txt"
        git -C "$CX_TEST_ROOT/$c" init -q -b main
        git -C "$CX_TEST_ROOT/$c" -c user.email=b@b -c user.name=b add -A
        git -C "$CX_TEST_ROOT/$c" -c user.email=b@b -c user.name=b commit -q -m "init $c"
    done
    export CX_TEST_ROOT
    export CX_ARCHIVE_ROOT="$BATS_TEST_TMPDIR/arc-$name"
    printf '%s' "$CX_TEST_ROOT"
}

# 整棵樹的指紋（路徑 + 大小）。dry-run 的契約用這個驗：
# 「跑完之後這個值必須一模一樣」比逐項斷言更貼近真正要保證的事。
# .git 與 .cx 排除：前者有 gc/索引的無關變動，後者是 cx 的執行期狀態（鎖）。
tree_digest() {                     # tree_digest [目錄]
    local r=${1:-$CX_TEST_ROOT}
    # 排除**所有**的 .git（不只頂層）與 .cx：
    #   .git —— preflight 會跑 git status / rev-parse，那會刷新索引，
    #           於是 backend/.git/index 的大小與 mtime 會變。那不是
    #           「dry-run 改動了檔案樹」，是 git 的正常行為。
    #           第一版只排除頂層的 .git，這個測試就為了錯的理由紅了。
    #   .cx  —— cx 的執行期狀態（鎖檔）。取鎖在 dry-run 下也是真的。
    #
    # 目錄只記路徑、不記大小：目錄的 inode 大小會隨著「裡面多了一個項目」而變，
    # 即使那個項目本身被 -prune 掉了。實測到的症狀是整棵樹只有根目錄
    # 從 480 變成 500 —— 因為 cx 取鎖時建了 .cx/。那不是內容變化。
    {
        find "$r" \( -name .git -o -name .cx \) -prune -o -type d -printf 'd %p\n' 2>/dev/null
        find "$r" \( -name .git -o -name .cx \) -prune -o ! -type d -printf 'f %p %s\n' 2>/dev/null
    } | sort | sha256sum | cut -d' ' -f1
}
