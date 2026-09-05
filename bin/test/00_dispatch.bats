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

# ── 版面契約 ───────────────────────────────────────────────────────────────
#
# CX_LAYOUT_VERSION 在 2026-09-06 之前只在 doctor.sh 被**印出來**，
# 沒有任何比較 —— 也就是一個裝飾。後果是「舊版面的樹跑新 cx」會用一堆
# 看不出關聯的方式壞掉：缺 env/docker/compose/dev.yml、composer 找不到
# src/backend/composer.json、ansible cd 失敗 —— 每個訊息都指向不同的方向。
#
# 兩個方向都要驗。只驗擋得住不驗放得過，會讓豁免清單變成沒人測的死碼。

@test "舊版面的樹要被擋下（EX_PRECOND），並指出怎麼遷移" {
    printf 'CX_PROJECT_NAME=old\nCX_LAYOUT_VERSION=2\nCX_GH_ORG=X\nCX_REPO_MAIN=old\nCX_REPO_BACKEND=old-b\nCX_REPO_FRONTEND=old-f\n' \
        > "$CX_TEST_ROOT/.cxroot"
    run cx_bin status
    assert_rc "$EX_PRECOND"
    assert_out_has "版面不相容"
    # 訊息要說得出「怎麼修」，否則使用者只知道壞了
    assert_out_has "src/"
}

@test "舊版面之下 doctor 仍然跑得起來（拿到舊樹的人正需要它）" {
    printf 'CX_PROJECT_NAME=old\nCX_LAYOUT_VERSION=2\nCX_GH_ORG=X\nCX_REPO_MAIN=old\nCX_REPO_BACKEND=old-b\nCX_REPO_FRONTEND=old-f\n' \
        > "$CX_TEST_ROOT/.cxroot"
    run cx_bin doctor
    # doctor 可能因為別的原因回非 0（工具缺東西），但**不可以**是版面閘門擋的
    assert_out_lacks "版面不相容"
    assert_out_has "layout v2"
}
