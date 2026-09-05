#!/usr/bin/env bash
# cx 行為測試的共用 helper。
#
# 為什麼不用 bats-support / bats-assert：它們同樣沒有 release asset，
# 引進來就是兩個沒有校驗的下載、或一份 vendor 進 public repo 的第三方 bash
# （那會被 cx scan sca 掃到，也會讓 cx lint sh 開始檢查別人的程式碼）。
# 我們需要的只有 assert_success / assert_output --partial，那是下面十幾行。
# 而且自己寫的版本可以印出更有用的診斷：完整的 cx argv、status、以及輸出尾巴。
#
# 紀律：一個來自 cx setup tools 的二進位 + 一個專案自有的 helper 檔。
# 不 npm、不 submodule、不 vendor。

# 真正的專案樹（cx test cli 會 export）。測試跑的是**真的程式碼**，
# 只是把 CX_ROOT 指到拋棄式的 fixture。
: "${CX_TEST_REAL_ROOT:?CX_TEST_REAL_ROOT 未設定 —— 請用 cx test cli 執行}"

# 退出碼從 common.sh 直接匯入，不重打一份。
# 但**有一個測試會硬編碼數字**（10_exitcodes.bats）——
# 那些數字是對外的契約，CI 會拿去分支判斷，所以要有恰好一個地方釘住它們，
# 而那個地方應該是測試，不是文件。
eval "$(sed -n '/^readonly EX_/p' "$CX_TEST_REAL_ROOT/bin/lib/common.sh")"

# ── 執行 ──────────────────────────────────────────────────────────────────

# 一律透過真正的 cx 進入點跑。
#
# 絕不 source bin/lib/common.sh 進 bats 再直接呼叫函式 —— 那會繞過 cx 自己的
# 旗標解析、set -Eeuo pipefail、ERR trap，以及 cx:196 的
# `"$fn" "$@" || _rc=$?` —— 而退出碼的契約正是活在那一行。
cx_bin() {
    "$CX_TEST_REAL_ROOT/cx" --root "$CX_TEST_ROOT" --ui plain "$@"
}

# 不帶 --root 的版本（測 .cxroot 向上搜尋、--root 驗證等）
cx_raw() {
    "$CX_TEST_REAL_ROOT/cx" "$@"
}

# ── 斷言 ──────────────────────────────────────────────────────────────────

_fail_with() {                      # _fail_with <訊息>
    printf 'assertion failed: %s\n' "$1" >&2
    printf '  status : %s\n' "${status:-?}" >&2
    printf '  output :\n' >&2
    printf '%s\n' "${output:-（空）}" | tail -20 | sed 's/^/    /' >&2
    return 1
}

assert_rc() {                       # assert_rc <期望的退出碼>
    [[ ${status:-} -eq $1 ]] || _fail_with "期望 exit $1，實際 ${status:-?}"
}

assert_ok() { assert_rc 0; }

assert_out_has() {                  # assert_out_has <子字串...>
    local want
    for want in "$@"; do
        [[ ${output:-} == *"$want"* ]] || _fail_with "輸出不含「$want」"
    done
}

assert_out_lacks() {                # assert_out_lacks <子字串...>
    local bad
    for bad in "$@"; do
        [[ ${output:-} != *"$bad"* ]] || _fail_with "輸出不該含「$bad」"
    done
}

# 需要 Docker daemon 的測試用這個。skip 不等於 pass —— cx test cli 會把
# skip 數印出來，並且支援 CX_TEST_STRICT=1 讓 CI 把 skip 當失敗。
need_docker() {
    docker version --format '{{.Server.Version}}' >/dev/null 2>&1 \
        || skip "需要可用的 Docker daemon"
}

need_cmd() {                        # need_cmd <指令...>
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || skip "需要 $c"
    done
}

# Docker 不可用的情境：不要從 PATH 拿掉 docker。
# 「CLI 不存在」與「daemon 不通」是兩個不同的分支、不同的訊息，
# 混在一起就是在測錯的程式碼。指向一個不存在的 socket 才是對的模擬。
no_docker() { export DOCKER_HOST='unix:///nonexistent/docker.sock'; }
