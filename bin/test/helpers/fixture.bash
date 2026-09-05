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
    mkdir -p "$CX_TEST_ROOT"/{docker/legacy,docs,reports,ansible,.vscode}
    : > "$CX_TEST_ROOT/claude.md"; : > "$CX_TEST_ROOT/.gitignore"
    : > "$CX_TEST_ROOT/.env"; : > "$CX_TEST_ROOT/.env.example"
    : > "$CX_TEST_ROOT/.semgrepignore"; : > "$CX_TEST_ROOT/sonar-project.properties"
    : > "$CX_TEST_ROOT/README.md"; : > "$CX_TEST_ROOT/.dockerignore"
    # ⚠ 下面兩樣是 2026-09-05 補的，因為「重建」那個案例平常會 skip，
    #   一旦真的用 CX_TEST_NETWORK=1 跑就會失敗 —— 而失敗的是 fixture 不完整，
    #   不是產品缺陷。skip 讓這件事藏了很久，正好是本專案 SKIP≠PASS 教條在講的。
    #
    #   _fresh_verify_rebuild 會斷言根目錄的基礎設施還在，而且 docker-compose.yml
    #   必須是**現行版面**（引用 docker/compose/）—— 空檔過不了。
    mkdir -p "$CX_TEST_ROOT/docker/compose"
    printf 'include:\n  - docker/compose/dev.yml\nservices: {}\n' \
        > "$CX_TEST_ROOT/docker-compose.yml"
    local _m
    for _m in dev test prod; do printf 'services: {}\n' > "$CX_TEST_ROOT/docker/compose/$_m.yml"; done
    #   templates/ 指到真的那一份：scaffold_patch.py 要從那裡把範本自己的接線
    #  （Filament 面板、routes/api.php、Sanctum migration、測試防護、ESLint）裝回去。
    #   自己 mkdir 一個空的等於那一整段不執行，重建後系統是否完整就驗不到。
    ln -s "$CX_TEST_REAL_ROOT/templates" "$CX_TEST_ROOT/templates"

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

# 真 submodule 的 fixture。
#
# ⚠ make_repo 建的是**三個各自獨立的巢狀 plain repo**，不是 submodule ——
#   backend/.git 是目錄、沒有 .git/modules/、gitlink 也不存在。
#   於是 archive.sh 處理指標檔的那一整段（rev-parse --absolute-git-dir、
#   MANIFEST 的 <c>_gitdir=、cx_restore 的還原分支）在測試套件底下是**死碼**，
#   而那正是真實專案的佈局。這個 fixture 就是為了把那條路蓋起來。
#
# 產出的拓撲（與 cx init 應該產生的一致）：
#   主庫      main, dev, dev-frontend, dev-backend   HEAD=dev
#   backend   main, dev                              HEAD=dev
#   frontend  main, dev                              HEAD=dev
#   .gitmodules 的 branch = dev
#
# --legacy-cxroot：不寫 CX_GIT_* 系列，用來測「舊專案原樣可用」的相容路徑。
make_submodule_repo() {             # make_submodule_repo [專案名] [--legacy-cxroot]
    local name=${1:-bats$RANDOM} legacy=0
    [[ ${2:-} == --legacy-cxroot ]] && legacy=1
    CX_TEST_ROOT="$BATS_TEST_TMPDIR/sub-$name"
    _assert_disposable "$CX_TEST_ROOT" || return 1
    mkdir -p "$CX_TEST_ROOT"
    {
        printf 'CX_PROJECT_NAME=%s\nCX_LAYOUT_VERSION=2\nCX_GH_ORG=Bats-Org\n' "$name"
        printf 'CX_REPO_MAIN=%s\nCX_REPO_BACKEND=%s-backend\nCX_REPO_FRONTEND=%s-frontend\n' \
            "$name" "$name" "$name"
        (( legacy )) || printf 'CX_GIT_MAIN_BRANCH=main\nCX_GIT_DEV_BRANCH=dev\n'
    } > "$CX_TEST_ROOT/.cxroot"
    ln -s "$CX_TEST_REAL_ROOT/bin" "$CX_TEST_ROOT/bin"
    ln -s "$CX_TEST_REAL_ROOT/cx"  "$CX_TEST_ROOT/cx"
    mkdir -p "$CX_TEST_ROOT"/{docker/legacy,docs,reports,ansible,.vscode}
    # templates/ 用 symlink 指到真的那一份 —— scaffold_patch.py 要從這裡把
    # 範本自己的接線（Filament 面板、routes/api.php、Sanctum migration、
    # tests/ 的防護、ESLint）裝回去。自己 mkdir 一個空的會讓那一整段變成
    # 「沒有來源所以什麼都不做」，測試就驗不到重建後系統是否完整。
    # templates 在 FRESH_PRESERVE 裡，不會被刪，所以 symlink 是安全的。
    ln -s "$CX_TEST_REAL_ROOT/templates" "$CX_TEST_ROOT/templates"
    : > "$CX_TEST_ROOT/claude.md";   : > "$CX_TEST_ROOT/.gitignore"
    : > "$CX_TEST_ROOT/.env";        : > "$CX_TEST_ROOT/.env.example"
    : > "$CX_TEST_ROOT/.semgrepignore"; : > "$CX_TEST_ROOT/sonar-project.properties"
    : > "$CX_TEST_ROOT/README.md";   : > "$CX_TEST_ROOT/.dockerignore"
    # _fresh_verify_rebuild 會斷言根目錄的基礎設施還在，而且 docker-compose.yml
    # 必須是**現行版面**（引用 docker/compose/）—— 空檔會讓重建後的驗證失敗，
    # 那是 fixture 不完整，不是產品缺陷。
    mkdir -p "$CX_TEST_ROOT/docker/compose"
    printf 'include:\n  - docker/compose/dev.yml\nservices: {}\n' \
        > "$CX_TEST_ROOT/docker-compose.yml"
    local m
    for m in dev test prod; do printf 'services: {}\n' > "$CX_TEST_ROOT/docker/compose/$m.yml"; done

    local g=(-c user.email=b@b -c user.name=b) c
    # 子模組要先是完整的 repo（有 commit），submodule add 才加得上去 ——
    # 對著沒有 commit 的 repo 會得到 "does not have a commit checked out"。
    for c in backend frontend; do
        mkdir -p "$CX_TEST_ROOT/$c"
        echo "content-$c" > "$CX_TEST_ROOT/$c/file.txt"
        git -C "$CX_TEST_ROOT/$c" init -q -b main
        git -C "$CX_TEST_ROOT/$c" "${g[@]}" add -A
        git -C "$CX_TEST_ROOT/$c" "${g[@]}" commit -q -m "init $c"
        git -C "$CX_TEST_ROOT/$c" branch dev
        git -C "$CX_TEST_ROOT/$c" switch -q dev
    done

    git -C "$CX_TEST_ROOT" init -q -b main
    echo root > "$CX_TEST_ROOT/file.txt"
    # ⚠ 第一個 commit **只能**放 file.txt，不可以 add -A。
    # 此刻 backend/ 與 frontend/ 已經各自是 repo，add -A 會把它們當成
    # 「embedded git repository」直接塞進索引，之後 submodule add 就會失敗
    # （路徑已在索引裡），而且它只是 warning，測試會安靜地拿到錯的佈局。
    # _fresh_git_init 的順序也是這樣：先 init，再 submodule add，最後才 add -A。
    git -C "$CX_TEST_ROOT" "${g[@]}" add file.txt .cxroot
    git -C "$CX_TEST_ROOT" "${g[@]}" commit -q -m "init main"
    # protocol.file.allow=always 是必要的：CVE-2022-39253 之後 file:// 的
    # 子模組預設被擋（fatal: transport 'file' not allowed）。fresh.sh:785 同理。
    for c in backend frontend; do
        git -C "$CX_TEST_ROOT" -c protocol.file.allow=always "${g[@]}" \
            submodule add --force -q -b dev "./$c" "$c" >/dev/null
    done
    # submodule add 對已經是 repo 的目錄不會 absorb gitdir（它只說
    # "Adding existing repo ... to the index"）—— 少了這一步，fixture 的佈局
    # 會退化成 make_repo 那種各自獨立的 .git 目錄，而這支 fixture 存在的理由
    # 正是要蓋到指標檔 + .git/modules/ 這條路。
    git -C "$CX_TEST_ROOT" submodule absorbgitdirs >/dev/null 2>&1
    git -C "$CX_TEST_ROOT" "${g[@]}" add -A
    git -C "$CX_TEST_ROOT" "${g[@]}" commit -q -m "add submodules"
    # 主庫的分支拓撲。用 git branch 不是 switch -c —— branch 只寫 ref、
    # 不動工作區，所以不會觸發 submodule.recurse 把子模組打成 detached（實測）。
    git -C "$CX_TEST_ROOT" branch dev main
    git -C "$CX_TEST_ROOT" branch dev-frontend dev
    git -C "$CX_TEST_ROOT" branch dev-backend dev
    git -C "$CX_TEST_ROOT" config submodule.recurse true
    git -C "$CX_TEST_ROOT" -c submodule.recurse=false switch -q dev

    # fixture 壞掉要當場看得出來，不可以安靜地退化成 make_repo 的佈局
    [[ -f $CX_TEST_ROOT/backend/.git ]] || {
        printf 'FIXTURE BROKEN: backend/.git 不是指標檔（submodule add 沒成功）\n' >&2
        return 1; }
    [[ -d $CX_TEST_ROOT/.git/modules/backend ]] || {
        printf 'FIXTURE BROKEN: 缺少 .git/modules/backend\n' >&2; return 1; }

    export CX_TEST_ROOT
    export CX_ARCHIVE_ROOT="$BATS_TEST_TMPDIR/arc-$name"
    printf '%s' "$CX_TEST_ROOT"
}

# 主庫某個分支上記錄的 gitlink（子模組指標）。
# 兩條開發線的測試幾乎每一條都在比這個值，不要每次重打。
line_sha() {                        # line_sha <repo> <分支或 ref> <子模組路徑>
    git -C "$1" ls-tree "$2" "$3" | awk '{print $3}'
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
