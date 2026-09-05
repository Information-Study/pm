#!/usr/bin/env bash
# cx 共用函式庫：日誌、錯誤處理、根目錄探測、鎖、dry-run。

readonly EX_OK=0 EX_FAIL=1 EX_USAGE=2 EX_PRECOND=3 EX_ABORT=4
readonly EX_SCAN_QUALITY=20 EX_SCAN_SAST=21 EX_SCAN_SCA=22 EX_SCAN_DAST=23

# ── 外部映像的單一事實來源 ────────────────────────────────────────────────────
# 每一個都**釘住明確版本**，沒有 latest、沒有無版本 tag。
# 這些原本散在 scan.sh / fresh.sh / compose.sh 的 `${VAR:-預設}` 裡，
# 要改版本得先找齊所有出現處 —— 集中在這裡之後，釘版是一次編輯，
# 而 cx verify static 的 check_version_pins 也有一張表可以對。
#
# 為什麼掃描器也釘版本，卻不會因此漏掉新的 CVE：
#   trivy 的漏洞資料庫、semgrep 的規則集都是**執行期下載**的，不烘在映像裡。
#   釘住的是掃描器程式本身的版本，不是它的情資。反過來說，讓掃描器版本浮動
#   代表 CI 可能在沒有任何 commit 的情況下，突然多出或少掉一批 finding，
#   而沒有人說得出為什麼。
#
# 每一個都可以用同名環境變數覆寫，例如：
#   CX_IMG_TRIVY=aquasec/trivy:0.75.0 cx scan sca
CX_IMG_ALPINE="${CX_IMG_ALPINE:-alpine:3.22}"
CX_IMG_NODE="${CX_IMG_NODE:-node:24.20-alpine}"
CX_IMG_COMPOSER="${CX_IMG_COMPOSER:-composer:2.10.3}"
CX_IMG_SEMGREP="${CX_IMG_SEMGREP:-semgrep/semgrep:1.175.0}"
CX_IMG_TRIVY="${CX_IMG_TRIVY:-aquasec/trivy:0.74.0}"
CX_IMG_ZAP="${CX_IMG_ZAP:-ghcr.io/zaproxy/zaproxy:2.17.0}"
CX_IMG_SONAR_SCANNER="${CX_IMG_SONAR_SCANNER:-sonarsource/sonar-scanner-cli:12.1.0.3233_8.0.1}"
CX_IMG_CURL="${CX_IMG_CURL:-curlimages/curl:8.11.1}"
# npm.sh 用的 glibc 變體：backend 的部分 npm 相依有原生模組，musl 上會編不起來。
CX_IMG_NODE_GLIBC="${CX_IMG_NODE_GLIBC:-node:24.20-bookworm-slim}"

# scaffold 用的 npm 套件也要釘版本，否則 cx fresh --mode scaffold 產出的骨架
# 會隨上游變動 —— 「重建一次」就不再是可重現的動作。
CX_NUXI_VERSION="${CX_NUXI_VERSION:-3.37.0}"

if [[ -t 2 ]]; then
    readonly C_RED=$'\033[31m' C_GRN=$'\033[32m' C_YLW=$'\033[33m'
    readonly C_BLU=$'\033[34m' C_DIM=$'\033[2m' C_RST=$'\033[0m'
else
    readonly C_RED='' C_GRN='' C_YLW='' C_BLU='' C_DIM='' C_RST=''
fi

cx_info()  { printf '%s▸%s %s\n'  "$C_BLU" "$C_RST" "$*" >&2; }
cx_ok()    { printf '%s✔%s %s\n'  "$C_GRN" "$C_RST" "$*" >&2; }
cx_warn()  { printf '%s⚠%s %s\n'  "$C_YLW" "$C_RST" "$*" >&2; }
cx_error() { printf '%s✘%s %s\n'  "$C_RED" "$C_RST" "$*" >&2; }
cx_step()  { printf '\n%s══ %s ══%s\n' "$C_BLU" "$*" "$C_RST" >&2; }
cx_dim()   { printf '%s  %s%s\n'  "$C_DIM" "$*" "$C_RST" >&2; }

cx_die() {
    local code=$EX_FAIL
    [[ ${1:-} =~ ^[0-9]+$ ]] && { code=$1; shift; }
    cx_error "$*"
    exit "$code"
}

cx_on_err() {
    local rc=$? cmd=$BASH_COMMAND
    cx_error "指令失敗 (exit $rc)：$cmd"
    local i
    # FUNCNAME[0] 是 cx_on_err 自己，所以從 1 開始；但上界不能減 1，
    # 否則最外層的呼叫者永遠不會被印出來。
    for ((i = 1; i < ${#FUNCNAME[@]}; i++)); do
        cx_dim "  於 ${FUNCNAME[i]}() ${BASH_SOURCE[i]}:${BASH_LINENO[i-1]}"
    done
    exit "$rc"
}

CX_INVOKE_PWD="${CX_INVOKE_PWD:-$PWD}"

cx_find_root() {
    local d="${1:-$PWD}"
    d=$(cd "$d" 2>/dev/null && pwd -P) || return 1
    while [[ $d != / ]]; do
        [[ -f $d/.cxroot ]] && { printf '%s\n' "$d"; return 0; }
        d=$(dirname "$d")
    done
    [[ -f /.cxroot ]] && { printf '%s\n' /; return 0; }
    return 1
}

cx_resolve() {
    local p=$1
    [[ $p == /* ]] && { printf '%s\n' "$p"; return; }
    printf '%s\n' "$CX_INVOKE_PWD/$p"
}

cx_lock() {
    [[ -n ${_CX_LOCK_FD:-} ]] && return 0
    local f="${CX_ROOT}/.cx/lock.${1:-global}"
    mkdir -p "$(dirname "$f")"
    exec {_CX_LOCK_FD}>"$f" || cx_die "$EX_PRECOND" "無法建立鎖檔 $f"
    flock -n "$_CX_LOCK_FD" || cx_die "$EX_PRECOND" "另一個 cx 正在執行（鎖：$f）"
}

CX_DRY_RUN=${CX_DRY_RUN:-0}
cx_run() {
    if (( CX_DRY_RUN )); then
        printf '%s[dry-run]%s %s\n' "$C_DIM" "$C_RST" "$(cx_q "$@")" >&2
        return 0
    fi
    "$@"
}
cx_q() { local a out=(); for a in "$@"; do printf -v a '%q' "$a"; out+=("$a"); done; printf '%s' "${out[*]}"; }

cx_have() { command -v "$1" >/dev/null 2>&1; }

# ── WSL interop：PATH 上的 Windows 執行檔不是「原生工具鏈」 ───────────────────
#
# WSL 預設把 Windows 的 PATH 併進來，所以 /mnt/c/Program Files/nodejs/npm 會被
# command -v 找到。裝在 ~/.local/bin 的 Linux node 一旦不在 PATH 上（例如
# ~/.profile 沒被 source 的非登入 shell），npm 就會**靜默**解析到 Windows 那支。
#
# 那支不是「比較舊的 npm」，是根本不能用：Windows 的 CMD.EXE 不支援 UNC 路徑
# 當工作目錄，在 WSL 的專案目錄裡跑會得到
#
#   '\\wsl.localhost\Ubuntu-26.04\home\sixtou\pm\backend'
#   CMD.EXE 不支援 UNC 路徑作為目前工作目錄
#   ✗ Build failed in 111ms
#
# 而 npm ci 會「成功」地留下一棵殘缺的 node_modules（實測 24 KB）。
# 也就是說：不擋的話，錯誤會以「vite build 壞了」的樣子出現在完全無關的地方。
#
# 2026-09-04 實測就是這樣炸的 —— 所以原生路徑一律用 cx_have_native。
cx_is_win_interop() {
    local p=$1
    [[ $p == /mnt/[a-z]/* ]] && return 0     # /mnt/c/... 的 Windows 磁碟
    [[ ${p,,} == *.exe ]]    && return 0
    return 1
}

# 跟 cx_have 一樣，但「解析到 Windows 執行檔」算沒有。
# 只用在原生工具鏈的判斷上 —— cx pma 要開瀏覽器時反而**需要** explorer.exe，
# 那裡仍然用 cx_have。
cx_have_native() {
    local p; p=$(command -v "$1" 2>/dev/null) || return 1
    cx_is_win_interop "$p" && return 1
    return 0
}

# 給錯誤訊息用：這個工具是不是「有，但有的是 Windows 那支」？
cx_win_interop_path() {
    local p; p=$(command -v "$1" 2>/dev/null) || return 1
    cx_is_win_interop "$p" || return 1
    printf '%s' "$p"
}
# 記憶化：一次 cx doctor 會問 4 次，daemon 掛在無回應的 TCP socket 上時
# 每次都要等 timeout。command -v docker 不能拿來判斷（WSL 上 CLI 在 PATH 但 daemon 不通）。
cx_docker_ok() {
    if [[ -z ${_CX_DOCKER_OK:-} ]]; then
        if cx_have docker && docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
            _CX_DOCKER_OK=0
        else
            _CX_DOCKER_OK=1
        fi
    fi
    return "$_CX_DOCKER_OK"
}

# ── runner：docker 還是原生 ───────────────────────────────────────────────────
# 專案的每一個功能都要能「完全用 Docker」或「完全用原生工具鏈」跑完，
# 兩條路各自獨立、不互相依賴。
#
# 預設 auto（有 Docker 就用 Docker），但一定要能**強制**：
#   cx --runner native composer install
#   cx --runner docker  npm ci
#
# ⚠ 被強制的那一邊如果不可用，一律**硬失敗**，絕不偷偷退回另一邊。
# 這是整件事的重點：只要允許靜默 fallback，「原生路徑可以獨立運作」
# 就永遠無法被驗證 —— 你以為在測原生，實際上跑的是容器。
cx_runner() {
    case ${CX_RUNNER:-auto} in
        docker) printf 'docker\n' ;;
        native) printf 'native\n' ;;
        *)      cx_docker_ok && printf 'docker\n' || printf 'native\n' ;;
    esac
}

# 這個動詞是不是被使用者「明確指定」了 runner？
# auto 之下允許降級，明確指定之下不允許。
cx_runner_forced() { [[ ${CX_RUNNER:-auto} != auto ]]; }

# docker runner 的前置條件。訊息要講清楚是「被指定」還是「自動選到」的。
cx_runner_need_docker() {
    local what=${1:-這個動作}
    cx_docker_ok || {
        cx_error "$what 需要 Docker，但 Docker daemon 不可用"
        if cx_runner_forced; then
            cx_dim "  你指定了 --runner docker。要改用原生工具鏈： --runner native"
        else
            cx_dim "  1) systemctl is-active docker"
            cx_dim "  2) id -nG | grep -q docker（沒有就 sudo usermod -aG docker \$USER）"
            cx_dim "  3) 加完群組後必須 wsl --shutdown（Windows 端）再重開"
        fi
        exit "$EX_PRECOND"
    }
    [[ -f $CX_ROOT/docker-compose.yml ]] || cx_die "$EX_PRECOND" \
        "$what 需要 docker-compose.yml，但檔案不存在"
}

# native runner 的前置條件：逐一檢查必要指令，一次列出全部缺的，
# 而不是讓使用者修一個再撞下一個。
# cx_runner_need_native <什麼動作> <指令>...
cx_runner_need_native() {
    local what=$1; shift
    local t missing=()
    for t in "$@"; do cx_have_native "$t" || missing+=("$t"); done
    (( ${#missing[@]} == 0 )) && return 0
    cx_error "$what 的原生路徑缺少：${missing[*]}"
    # 「找得到但那是 Windows 那支」要單獨講清楚，否則使用者會盯著
    # 一個 which 找得到的 npm 看「明明就有為什麼說缺」。
    local winp
    for t in "${missing[@]}"; do
        if winp=$(cx_win_interop_path "$t"); then
            cx_warn "  $t 在 PATH 上找得到，但那是 Windows 的：$winp"
            cx_dim  "    WSL 的專案目錄是 UNC 路徑，Windows 執行檔在這裡跑會壞（見 troubleshooting.md）"
        fi
    done
    cx_dim "  PATH 有沒有 ~/.local/bin？ echo \$PATH | tr : '\\n' | grep .local/bin"
    for t in "${missing[@]}"; do
        case $t in
            composer) cx_dim "  composer → cx setup tools composer" ;;
            node|npm) cx_dim "  $t → cx setup tools node" ;;
            # php / mysql 需要 root，所以走 setup system 而不是 setup tools。
            # cx 仍然不會偷偷 sudo：sudo 不可用時 setup system 只把指令印出來。
            php)      cx_dim "  php → cx setup system php（需要 root；sudo 不可用時只印指令）" ;;
            nginx)    cx_dim "  nginx → cx setup system nginx" ;;
            git)      cx_dim "  git → cx setup system git" ;;
            docker)   cx_dim "  docker → cx setup system docker" ;;
            mysql|mysqldump)
                      cx_dim "  $t → cx setup system mysql-client" ;;
            *)        cx_dim "  $t → 請自行安裝" ;;
        esac
    done
    if cx_runner_forced; then
        cx_dim "  你指定了 --runner native。要改用容器： --runner docker"
    else
        cx_dim "  或改用容器： --runner docker（需要 Docker daemon）"
    fi
    exit "$EX_PRECOND"
}

# 每個雙路徑動詞開頭都印一行，讓「這次到底跑在哪裡」永遠不必用猜的。
cx_runner_banner() {
    local r; r=$(cx_runner)
    local how=自動
    cx_runner_forced && how=指定
    cx_dim "runner: $r（$how）${1:+ — $1}"
}

cx_need() {
    cx_have "$1" && return 0
    local msg="缺少必要工具：$1"
    [[ -n ${2:-} ]] && msg="$msg —— $2"
    cx_die "$EX_PRECOND" "$msg"
}

# Docker daemon 的硬性要求。訊息要把「剛加入 docker 群組」這個最常見的情境講出來：
# usermod -aG 只影響「之後才建立」的登入 session，WSL 需要 wsl --shutdown 才會生效。
cx_docker_need() {
    cx_docker_ok && return 0
    cx_error "Docker daemon 不可用"
    cx_dim "  1) 確認 daemon：systemctl is-active docker"
    cx_dim "  2) 確認群組：id -nG | grep -q docker（沒有就 sudo usermod -aG docker \$USER）"
    cx_dim "  3) 加完群組後必須 wsl --shutdown（Windows 端）再重開，usermod 不影響既有 session"
    exit "$EX_PRECOND"
}

# ── 專案識別 ─────────────────────────────────────────────────────────────────
# compose project 前綴、網路名、映像前綴全部從這裡長出來。
#
# ⚠ 不可以寫死 'pm'。這個 repo 的用途之一是「當成新專案的範本」，
# 而 compose 的 -p 決定容器／網路／volume 的命名空間：
# 寫死的話，複製出去改名的專案仍然會建出 pm_dev / pm_dev_net，
# 於是它跟本專案在同一台機器上會互相搶容器名與網路 ——
# 症狀是新專案 up 之後，舊專案的容器被「接管」或直接衝突。
#
# .cxroot 在 cx:99 被 source，時間點在 lib 載入之後、動詞執行之前，
# 所以這個函式只能在**執行期**呼叫，不能拿去做頂層變數賦值。
# 「這個目錄自己是不是一個 repo 的根」——不是「git 在這裡能不能運作」。
#
# 這個差別在子模組沒初始化的時候會咬人：backend/ 是一個空目錄，
# `git -C backend rev-parse --git-dir` 仍然成功，因為 git 會**往上找**，
# 找到主庫的 .git。於是 cx_backup 會把主庫的 HEAD 當成 backend 的 HEAD
# 寫進 MANIFEST，封存出三個一模一樣的 bundle，而驗證還會全綠 ——
# 一份看起來完整、實際上沒有備份到任何子模組內容的封存。
# 2026-09-05 在拋棄式副本上實跑 cx fresh 時發現。
cx_is_repo_root() {
    local r=$1 top
    top=$(git -C "$r" rev-parse --show-toplevel 2>/dev/null) || return 1
    [[ $(cd "$r" && pwd -P) == "$(cd "$top" && pwd -P)" ]]
}

cx_project() { printf '%s' "${CX_PROJECT_NAME:-pm}"; }

# compose project 名（-p 的值）。
# 映像前綴。compose 用的是 .env 的 IMAGE_PREFIX（不是 CX_PROJECT_NAME）——
# 兩者由 cx setup env 產生時對齊，但 .env 可以被手改，所以要讀真正的來源。
cx_image_prefix() {
    local v=''
    [[ -f $CX_ROOT/.env ]] && v=$(grep -E '^IMAGE_PREFIX=' "$CX_ROOT/.env" | tail -1 | cut -d= -f2-)
    printf '%s' "${v:-$(cx_project)}"
}

cx_project_for() { printf '%s_%s' "$(cx_project)" "${1:?mode}"; }

# SonarQube 那組是獨立的 compose project（生命週期跟三個模式無關），
# 但一樣要跟著專案名走，否則兩個專案會共用同一台 SonarQube 與同一個網路。
# scan.sh 需要網路名去 docker run 一次性的 sonar-scanner，所以放在共用層。
cx_sonar_project() { printf '%s_devsecops' "$(cx_project)"; }
cx_sonar_net()     { printf '%s_devsecops_net' "$(cx_project)"; }

# ── compose 引數組裝 ──────────────────────────────────────────────────────────
# claude.md §4 的四個陷阱全部在這裡處理掉，所有動詞都必須走這條路：
#   1) --project-directory "$CX_ROOT"：相對路徑以「第一個 -f 的目錄」為基準，不是 cwd。
#   2) -p <專案>_<mode>：隔離容器／網路／volume（但**不隔離 host 埠**，埠靠 docker/env/<mode>.env）。
#   3) --env-file 顯式缺檔是硬錯誤（隱式 ./.env 才會靜默略過）→ 只加存在的檔。
#   4) 網路名在 compose 裡明寫 name:，否則會被命名空間化成 <project>_<key>。
CX_DC_ARGS=()
cx_compose_init() {
    local mode=${1:-${CX_MODE:-dev}}
    case $mode in
        dev|test|prod) : ;;
        *) cx_die "$EX_USAGE" "模式只接受 dev|test|prod（收到 $mode）" ;;
    esac
    local base="$CX_ROOT/docker-compose.yml"
    local overlay="$CX_ROOT/docker/compose/${mode}.yml"
    [[ -f $base    ]] || cx_die "$EX_PRECOND" "缺少 base compose：$base"
    [[ -f $overlay ]] || cx_die "$EX_PRECOND" "缺少 overlay compose：$overlay"

    CX_DC_ARGS=(--project-directory "$CX_ROOT" -p "$(cx_project_for "$mode")" -f "$base" -f "$overlay")
    local f
    # 後面的 --env-file 優先：模式專屬值（埠、target）要能蓋掉根 .env 的通用值。
    for f in "$CX_ROOT/.env" "$CX_ROOT/docker/env/${mode}.env"; do
        [[ -f $f ]] && CX_DC_ARGS+=(--env-file "$f")
    done
    CX_DC_MODE=$mode
    export CX_DC_MODE
}

cx_dc() {
    (( ${#CX_DC_ARGS[@]} )) || cx_die "$EX_FAIL" "內部錯誤：cx_dc 在 cx_compose_init 之前被呼叫"
    cx_run docker compose "${CX_DC_ARGS[@]}" "$@"
}

# 不經過 cx_run 的唯讀查詢版本 —— --dry-run 之下仍然要能拿到真實答案，
# 否則 dry-run 會因為「查不到容器」而走上跟實際執行完全不同的分支。
cx_dc_q() {
    (( ${#CX_DC_ARGS[@]} )) || cx_die "$EX_FAIL" "內部錯誤：cx_dc_q 在 cx_compose_init 之前被呼叫"
    docker compose "${CX_DC_ARGS[@]}" "$@"
}

# 掛在「image 中不存在的路徑」上的具名 volume 一律被 Docker 建成 root:root 0755，
# 於是非 root 的 Trivy / Semgrep / PHPStan / ZAP 全部 EACCES。
# 所有 bind mount 來源都必須由 cx 以呼叫者身分預先建立。
cx_ensure_host_dirs() {
    local d
    for d in "$@"; do
        [[ -d $d ]] && continue
        cx_run mkdir -p "$d" || cx_die "$EX_FAIL" "無法建立 $d"
    done
}

# compose 的 bind mount 來源不存在時，Docker 會靜默建立一個空目錄並掛上去
# （於是 CRS 排除規則從未載入、WAF 悄悄失效）。up/build 之前逐一確認。
cx_assert_mount_sources() {
    local mode=${1:-${CX_DC_MODE:-dev}} missing=0 p
    while IFS= read -r p; do
        [[ -z $p ]] && continue
        [[ -e $CX_ROOT/$p ]] || { cx_error "bind mount 來源不存在：$p"; missing=1; }
    done < <(cx_compose_mount_sources "$mode")
    (( missing )) && cx_die "$EX_PRECOND" "請先修好上列路徑（Docker 會靜默建空目錄並掛上去）"
    return 0
}

# 從 compose 設定裡撈出所有相對路徑的 bind mount 來源。
# 用 config --format json 而非 grep yaml：合併後的結果才是真相。
cx_compose_mount_sources() {
    local mode=${1:-${CX_DC_MODE:-dev}} f
    local -a a=(--project-directory "$CX_ROOT" -p "$(cx_project_for "$mode")"
                -f "$CX_ROOT/docker-compose.yml" -f "$CX_ROOT/docker/compose/${mode}.yml")
    for f in "$CX_ROOT/.env" "$CX_ROOT/docker/env/${mode}.env"; do
        [[ -f $f ]] && a+=(--env-file "$f")
    done
    docker compose "${a[@]}" config --format json 2>/dev/null \
        | CX_ROOT="$CX_ROOT" python3 "$CX_ROOT/bin/lib/compose_mounts.py"
}

# compose 的動作白名單。放在 common.sh 是因為 bin/cmd/test.sh 需要在
# source compose.sh 之前就判斷「cx test up」的 up 是 compose 動作還是測試套件名稱。
CX_COMPOSE_VERBS_LIST='up down restart ps logs sh build dc config'
