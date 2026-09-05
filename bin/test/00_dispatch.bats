#!/usr/bin/env bats
# ① 參數解析與動詞分派

setup() {
    load helpers/common
    load helpers/fixture
    make_root >/dev/null
}

@test "無參數時預設動詞是 tui（非互動下要求 TTY 而不是卡住）" {
    run cx_bin tui
    assert_rc "$EX_PRECOND"
    assert_out_has "終端機" "cx help"
}

@test "未知動詞回 EX_USAGE 並提示 cx help" {
    run cx_bin nosuchverb
    assert_rc "$EX_USAGE"
    assert_out_has "未知的指令" "cx help"
}

@test "--ui 只接受 whiptail|dialog|plain" {
    run cx_raw --ui bogus help
    assert_rc "$EX_USAGE"
    assert_out_has "--ui"
}

@test "--mode 只接受 dev|test|prod" {
    run cx_raw --mode bogus help
    assert_rc "$EX_USAGE"
    assert_out_has "--mode"
}

@test "--runner 只接受 docker|native|auto" {
    run cx_raw --runner bogus help
    assert_rc "$EX_USAGE"
    assert_out_has "--runner"
}

@test "--root 需要值" {
    run cx_raw --root
    assert_rc "$EX_USAGE"
}

@test "--root 指到沒有 .cxroot 的目錄要拒絕" {
    run cx_raw --root "$BATS_TEST_TMPDIR" help
    assert_rc "$EX_PRECOND"
    assert_out_has ".cxroot"
}

@test "未知的全域旗標要拒絕" {
    run cx_raw --nope help
    assert_rc "$EX_USAGE"
}

@test "每個動詞的 --help 都跑得起來且印得出東西" {
    # 這一項便宜地涵蓋「動詞檔存在但 cmd_<verb>_main 沒定義」（cx:150-153）
    # 以及任何在印出 usage 之前就死掉的 --help 路徑。
    # $verbs 的宣告可能跨行，用 python 抓（awk/sed 的多行處理只會更難讀）
    local verbs; verbs=$(python3 -c "
import re,sys
s=open(sys.argv[1],encoding='utf-8').read()
m=re.search(r\"local verbs='([^']*)'\", s, re.S)
print(m.group(1) if m else '')
" "$CX_TEST_REAL_ROOT/bin/completion/cx.bash")
    [ -n "$verbs" ]
    local v
    for v in $verbs; do
        case $v in tui) continue ;; esac      # tui 沒有 --help，它要 TTY
        run cx_bin "$v" --help
        [[ $status -eq 0 || $status -eq "$EX_PRECOND" ]] \
            || _fail_with "cx $v --help 回 $status"
        [ -n "$output" ] || _fail_with "cx $v --help 沒有輸出"
    done
}
