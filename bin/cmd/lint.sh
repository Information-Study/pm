#!/usr/bin/env bash
# cx lint — 靜態檢查（不改檔案）。
#
# 這個動詞原本只做 Ansible 的靜態檢查，是個命名陷阱：在任何其他專案裡
# `lint` 都是「檢查我的原始碼」。而本專案的 PHP（Pint）與前端（Prettier）
# 明明都已經隨相依裝好了，卻沒有任何動詞叫得到。
#
# 現在是分派器。分工：
#   cx lint    只檢查、絕不改檔案（CI、提交前）
#   cx style   會改檔案（自動修正）
#
# ansible 這一支仍然是 ansible-playbook --syntax-check 與 ansible-lint 的
# **替代品**，不是等價物 —— 它只做 YAML 剖析、FQCN、紅線、變數引用、
# changed_when。ansible 可用時請改跑 cx deploy lint。

_lint_usage() {
    cat >&2 <<'TXT'
用法：cx lint [ansible|php|js|sh|all] [目錄]

  ansible   Ansible 靜態檢查（預設目錄 ansible/）
            ⚠ 這是 --syntax-check 的替代品，不是等價物。
              ansible 裝好之後請改用 cx deploy lint
  php       Laravel Pint --test（= cx style php --check）
  js        Prettier --check（= cx style js --check）
  sh        shellcheck 掃 cx 與 bin/**.sh
  all       以上全部（預設）

全部跑完才回傳最嚴重的退出碼，不是遇到第一個問題就停。
TXT
}

_lint_ansible() {
    local target="${1:-$CX_ROOT/env/ansible}"
    [[ $target == /* ]] || target=$(cx_resolve "$target")
    [[ -d $target ]] || cx_die "$EX_PRECOND" "找不到 $target"

    cx_step "Ansible 靜態檢查"
    if cx_have ansible-playbook; then
        cx_warn "偵測到 ansible-playbook —— 真正的檢查是 cx deploy lint"
        cx_dim "  ansible-playbook $CX_ROOT/env/ansible/site.yml --syntax-check"
        cx_dim "  ansible-lint $CX_ROOT/env/ansible/"
        cx_info "以下仍執行靜態檢查作為補充"
    else
        cx_warn "ansible 未安裝 —— 這是替代性檢查，不等於 --syntax-check"
    fi
    python3 "$CX_ROOT/bin/lib/ansible_lint.py" "$target"
}

# ShellCheck：cx 自己是 ~8000 行 bash，卻從來沒有被靜態檢查過。
# 誠實的範圍說明：shellcheck 抓不到本專案最貴的那類缺陷
#（_setup_system_have 少一個 case 分支是完全合法的 bash），
# 它抓的是引號、字詞分割、未定義變數那一類。
_lint_sh() {
    cx_step "Shell 靜態檢查 — shellcheck"
    if ! cx_have shellcheck; then
        cx_warn "shellcheck 未安裝 —— 略過"
        cx_dim "  安裝： cx setup tools shellcheck"
        return "$EX_PRECOND"
    fi
    local -a files=("$CX_ROOT/cx")
    # *.sh 與 bin/test 的 helper（*.bash）都要檢查。
    # **不含 *.bats** —— `@test "…" {` 不是合法 bash，shellcheck 會對每一支
    # 測試檔吐一堆 parse error，把真正的 finding 淹掉。
    while IFS= read -r -d '' f; do files+=("$f"); done \
        < <(find "$CX_ROOT/bin" \( -name '*.sh' -o -name '*.bash' \) -type f -print0 | sort -z)
    cx_info "${#files[@]} 個檔案"
    # 閘門只看 error，warning 仍然完整顯示 —— 與 ② SAST 那條 lane 的作法一致
    # （見 bin/lib/sarif_gate.py 與 docker-verification.md 的 A12：
    #  用「有任何 finding 就失敗」當閘門的結果是這條 lane 永遠紅燈，
    #  於是沒有人會再看它）。
    #
    # 剩下的 warning 都複核過，是這個 codebase 的結構造成的誤報：
    #   SC2034  bin/lib/*.sh 是被 source 的函式庫，變數給呼叫者用
    #   SC2097/8 `CX_ROOT="$CX_ROOT" python3 …` —— CX_ROOT 在 cx 裡已經 export，
    #           前綴是冗餘但無害的
    #   SC2178  同名區域變數在不同函式裡的型別不同，shellcheck 跨函式追丟了
    # -x：追蹤 source 進來的檔案。-P：讓 source 找得到 bin/lib/。
    #
    # 但有一小撮 shellcheck 歸類為 warning 的東西，其實是**正確性缺陷**而不是風格。
    # 它們一律當作 error 擋下來 —— 清單刻意保持很短，而且加入前都確認過
    # 目前的樹上是 0 命中，所以這道閘門是綠的，不是一開就紅的裝飾品。
    #
    #   SC2215  旗標被當成指令名 —— 幾乎一定是「註解夾在 `\` 續行中間」。
    #           bash 會把續行接上來、`#` 吃掉整行、而那行沒有結尾的 `\`，
    #           於是指令提早結束（例如 docker run 的映像名整個消失），
    #           後面的 `-e …` 變成一條新指令。`bash -n` 過得了 ——
    #           那是合法語法，只是變成另一支程式。2026-09-05 真的踩到過。
    #   SC2216/7 管給不讀 stdin 的指令 —— 資料默默掉進黑洞
    #   SC2218  函式在定義之前就被呼叫
    #   SC2069  `2>&1 >file` 順序寫反 —— stderr 沒有進檔案
    #   SC2064  trap 用雙引號 → 變數在**設 trap 當下**就展開。
    #           這正是 fresh.sh 的 C-1 缺陷（`rm -rf` 拿到烘死的路徑）。
    #   SC2140  字串意外相接，通常是漏了逗號或引號寫錯
    #   SC2145  把陣列接在字串上 —— 只有第一個元素是你想的那樣
    local -a fatal_warn=(SC2215 SC2216 SC2217 SC2218 SC2069 SC2064 SC2140 SC2145)
    local all_warn='' fatal_hits=''
    all_warn=$(shellcheck -x -P "$CX_ROOT/bin/lib" -S warning -f gcc "${files[@]}" 2>/dev/null || true)
    local warn=0
    warn=$(printf '%s\n' "$all_warn" | grep -c ': warning:' || true)
    local re
    re=$(IFS='|'; printf '%s' "${fatal_warn[*]}")
    fatal_hits=$(printf '%s\n' "$all_warn" | grep -E "\[($re)\]" || true)
    cx_run shellcheck -x -P "$CX_ROOT/bin/lib" -S error "${files[@]}" || return $?
    if [[ -n $fatal_hits ]]; then
        cx_error "shellcheck：以下 warning 屬於正確性缺陷，視同 error"
        printf '%s\n' "$fatal_hits" | while IFS= read -r l; do cx_dim "    $l"; done
        return "$EX_FAIL"
    fi
    if (( warn )); then
        cx_warn "shellcheck：0 error，$warn 個 warning（不擋，細節： cx lint sh 之後跑"
        cx_dim "    shellcheck -x -P bin/lib -S warning cx bin/**/*.sh"
    else
        cx_ok "shellcheck：0 error、0 warning"
    fi
}

# ── 前端：ESLint ────────────────────────────────────────────────────────────
#
# 與 Prettier 的分工是硬的：ESLint 抓「會出錯的東西」（未使用的變數、用了沒
# 定義的東西、Vue 的錯誤用法），Prettier 只管排版。src/frontend/eslint.config.mjs
# 刻意不開任何排版規則，所以兩者不會互相打架。
#
# eslint.config.mjs 會 import ./.nuxt/eslint.config.mjs —— 那份由 @nuxt/eslint
# 在 `nuxt prepare` 時產生，帶著 Nuxt 的 auto-import 全域。**沒跑過 prepare
# 就沒有那個檔**，eslint 會死在 import 失敗；那是環境問題（EX_PRECOND），
# 不是「程式有問題」，所以要分開回報 —— 否則剛 clone 下來的樹會看到一個
# 假的 lint 失敗。
_lint_js_eslint() {
    [[ -f $CX_ROOT/src/frontend/package.json ]] || {
        cx_warn "找不到 src/frontend/package.json，略過前端"; return "$EX_PRECOND"; }

    cx_step "前端靜態檢查 — ESLint"
    local rc=0
    if [[ $(cx_runner) == docker ]]; then
        cx_runner_need_docker "cx lint js"
        cx_runner_banner "compose 的 nuxt service"
        cx_compose_init "$CX_MODE"
        cx_dc run --rm --no-deps -u "$(id -u):$(id -g)" \
            --entrypoint npx nuxt eslint . || rc=$?
    else
        cx_runner_need_native "cx lint js" npm
        [[ -x $CX_ROOT/src/frontend/node_modules/.bin/eslint ]] || { cx_warn \
            "找不到 src/frontend/node_modules/.bin/eslint —— 先跑 cx --runner native npm ci"
            return "$EX_PRECOND"; }
        [[ -f $CX_ROOT/src/frontend/.nuxt/eslint.config.mjs ]] || { cx_warn \
            "缺少 src/frontend/.nuxt/eslint.config.mjs —— 先跑 npx nuxt prepare（npm ci 的 postinstall 會做）"
            return "$EX_PRECOND"; }
        cx_runner_banner "src/frontend/node_modules/.bin/eslint"
        cx_run env -C "$CX_ROOT/src/frontend" node_modules/.bin/eslint . || rc=$?
    fi
    if (( rc == 0 )); then cx_ok "ESLint：0 finding"; else cx_warn "ESLint 有 finding"; fi
    return "$rc"
}

cmd_lint_main() {
    local target=all dir=''
    case ${1:-} in
        -h|--help)          _lint_usage; return 0 ;;
        ansible|php|js|sh|all) target=$1; shift ;;
        '')                 : ;;
        # 相容舊用法：cx lint <目錄> 等於 cx lint ansible <目錄>
        *)                  target=ansible ;;
    esac
    dir=${1:-}
    (( $# <= 1 )) || cx_die "$EX_USAGE" "lint 最多接受一個目錄（收到 $# 個）"

    # 需要 style.sh 的兩個子項
    if [[ $target == php || $target == js || $target == all ]]; then
        # shellcheck source=/dev/null
        . "$CX_ROOT/bin/cmd/style.sh"
    fi

    local worst=0 rc=0
    _lint_one() { rc=0; "$@" || rc=$?; (( rc > worst )) && worst=$rc; return 0; }

    case $target in
        ansible) _lint_one _lint_ansible "$dir" ;;
        php)     _lint_one _style_php 1 ;;
        js)      _lint_one _lint_js_eslint; _lint_one _style_js 1 ;;
        sh)      _lint_one _lint_sh ;;
        all)
            _lint_one _lint_ansible "$dir"
            _lint_one _style_php 1
            _lint_one _lint_js_eslint
            _lint_one _style_js 1
            _lint_one _lint_sh
            ;;
    esac

    # EX_PRECOND（工具沒裝）不該蓋掉「真的有 finding」。前者是環境問題。
    (( worst == 0 )) && cx_ok "靜態檢查通過"
    return "$worst"
}
