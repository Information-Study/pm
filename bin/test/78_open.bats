#!/usr/bin/env bats
# ⑫ cx open — 服務網址
#
# 這個動詞最大的風險不是它自己壞掉，而是它**複製**了 pma 與 sonar 的埠推導。
# 那兩段有 prod 的刻意拒絕（D13）、容器沒跑時的指路、以及「從合併後的 compose
# 讀實際發布埠」的邏輯。複製之後兩邊會各自演化，然後 cx pma 與 cx open pma
# 給出不同的網址而沒有人發現。所以這裡的第一條案例就是釘住「委派，不是複製」。

setup() {
    load helpers/common
    load helpers/fixture
    make_root op >/dev/null
    add_compose_skeleton
}

@test "cx open --url pma 與 cx pma --url 的輸出完全相同（委派，不是複製）" {
    run cx_bin open --url pma
    local a=$output
    run cx_bin pma --url
    local b=$output
    [ "$a" = "$b" ] || _fail_with "兩者不一致：open=「$a」 pma=「$b」"
}

@test "prod 模式的 pma 被拒絕，而且說得出為什麼（D13）" {
    run cx_bin --mode prod open pma
    assert_rc "$EX_USAGE"
    assert_out_has "prod"
}

@test "cx open list 在沒有 Docker 的樹上照樣印得出清單（不失敗）" {
    no_docker
    run cx_bin open list
    assert_rc 0
    assert_out_has front
    assert_out_has back
    assert_out_has api
}

@test "未知目標要報 EX_USAGE，而不是安靜地開一個猜出來的網址" {
    run cx_bin open nosuchtarget
    assert_rc "$EX_USAGE"
}

@test "網址跟著模式走（dev 與 test 的 edge 埠不同）" {
    printf 'EDGE_HTTP_PORT=8080\n'  > "$CX_TEST_ROOT/env/docker/compose/dev.env"
    printf 'EDGE_HTTP_PORT=18080\n' > "$CX_TEST_ROOT/env/docker/compose/test.env"
    run cx_bin --mode dev open front --url
    assert_out_has "8080"
    run cx_bin --mode test open front --url
    assert_out_has "18080"
}
