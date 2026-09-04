#!/usr/bin/env bash
# cx 共用函式庫：日誌、錯誤處理、根目錄探測、鎖、dry-run。

readonly EX_OK=0 EX_FAIL=1 EX_USAGE=2 EX_PRECOND=3 EX_ABORT=4
readonly EX_SCAN_QUALITY=20 EX_SCAN_SAST=21 EX_SCAN_SCA=22 EX_SCAN_DAST=23

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
    for t in "$@"; do cx_have "$t" || missing+=("$t"); done
    (( ${#missing[@]} == 0 )) && return 0
    cx_error "$what 的原生路徑缺少：${missing[*]}"
    for t in "${missing[@]}"; do
        case $t in
            composer) cx_dim "  composer → cx setup tools composer" ;;
            node|npm) cx_dim "  $t → cx setup tools node" ;;
            php)      cx_dim "  php → 系統套件（sudo apt install php8.5-cli），cx 不代裝需要 root 的東西" ;;
            mysql|mysqldump)
                      cx_dim "  $t → 系統套件（sudo apt install mysql-client）" ;;
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

# ── compose 引數組裝 ──────────────────────────────────────────────────────────
# claude.md §4 的四個陷阱全部在這裡處理掉，所有動詞都必須走這條路：
#   1) --project-directory "$CX_ROOT"：相對路徑以「第一個 -f 的目錄」為基準，不是 cwd。
#   2) -p pm_<mode>：隔離容器／網路／volume（但**不隔離 host 埠**，埠靠 docker/env/<mode>.env）。
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

    CX_DC_ARGS=(--project-directory "$CX_ROOT" -p "pm_${mode}" -f "$base" -f "$overlay")
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
    local -a a=(--project-directory "$CX_ROOT" -p "pm_${mode}"
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
