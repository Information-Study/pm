#!/usr/bin/env bats
# ③ runner 選擇 + ⑨ WSL/原生偵測

setup() {
    load helpers/common
    load helpers/fixture
    make_root >/dev/null
}

@test "--runner docker 在 daemon 不通時硬失敗（絕不靜默退回原生）" {
    # 這是紅線：允許靜默 fallback 的話，「原生路徑可以獨立運作」
    # 這件事就永遠無法被驗證 —— 你以為在測原生，實際跑的是容器。
    no_docker
    local v
    for v in "php -v" "composer --version" "art --version"; do
        # shellcheck disable=SC2086
        run cx_bin --runner docker $v
        assert_rc "$EX_PRECOND"
        assert_out_has "--runner native"
    done
}

@test "--runner auto 在 daemon 不通時退回原生" {
    need_cmd php
    no_docker
    run cx_bin --runner auto php -v
    assert_rc 0
    assert_out_has "PHP"
}

@test "只能靠 Docker 的動詞在 daemon 不通時給可行動訊息，不是 stack dump" {
    no_docker
    local v
    for v in "pma --url" "sonar status" "verify runtime"; do
        # shellcheck disable=SC2086
        run cx_bin $v
        assert_rc "$EX_PRECOND"
        assert_out_lacks "command not found" "Traceback"
    done
}

@test "與 runner 無關的動詞在 daemon 不通時照常可用" {
    no_docker
    run cx_bin verify cli
    assert_rc 0
}

@test "cx_is_win_interop 認得出 Windows 的兩種形狀" {
    # 這個函式是純樣式比對（/mnt/[a-z]/* 或 *.exe），路徑不必真的存在。
    # 所以直接餵字面路徑 —— 用 BATS_TEST_TMPDIR 造假是造不出 /mnt/ 開頭的。
    #
    # 這件事為什麼重要：WSL 預設把 Windows 的 PATH 併進來，於是
    # /mnt/c/.../npm 會被當成「原生 npm」。實測過的症狀是 npm ci「成功」
    # 但留下 24KB 壞掉的 node_modules，錯誤要到 vite build 才現形。
    run env CX_ROOT="$CX_TEST_ROOT" bash -c "
        . '$CX_TEST_REAL_ROOT/bin/lib/common.sh'
        for p in /mnt/c/Program\ Files/nodejs/npm /mnt/d/tools/git C:/x/foo.exe /usr/bin/npm; do
            cx_is_win_interop \"\$p\" && echo \"WIN \$p\" || echo \"NATIVE \$p\"
        done"
    assert_rc 0
    assert_out_has "WIN /mnt/c/" "WIN /mnt/d/" "WIN C:/x/foo.exe" "NATIVE /usr/bin/npm"
}

@test "cx_have_native 不把 .exe 當成原生工具鏈" {
    local fake="$BATS_TEST_TMPDIR/winbin"
    mkdir -p "$fake"
    printf '#!/bin/sh\nexit 0\n' > "$fake/faketool.exe"; chmod +x "$fake/faketool.exe"
    run env CX_ROOT="$CX_TEST_ROOT" PATH="$fake:/usr/bin:/bin" bash -c "
        . '$CX_TEST_REAL_ROOT/bin/lib/common.sh'
        cx_have faketool.exe        && echo HAVE      || echo NO_HAVE
        cx_have_native faketool.exe && echo NATIVE    || echo NOT_NATIVE"
    # cx_have 找得到（cx pma 要開瀏覽器時**需要** explorer.exe），
    # 但 cx_have_native 必須說不是原生 —— 這個區分正是它存在的理由。
    assert_out_has "HAVE" "NOT_NATIVE"
}
