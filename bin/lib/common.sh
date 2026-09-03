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
