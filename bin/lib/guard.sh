#!/usr/bin/env bash
# cx push guard：白名單 + 黑名單 + 顯式解鎖。
#
# 設計原則（2026-09-03 使用者授權推送後修訂）：
#   原本是「絕對禁止 push」。使用者授權後改為白名單制 —— 這防的是「推到錯的組織」，
#   比單純封鎖有價值。舊的 team-of-P/* 是永久黑名單，不接受任何覆寫旗標。
#
# 誠實揭露：pre-push hook 擋不住 `git push --no-verify`。
# 真正擋得住 --no-verify 的是「不設定遠端」與「cx 不提供 push 動詞」。
# 因此白名單檢查同時存在於 hook 與 cx git push 兩處。

# ⚠ 白名單不可以寫死組織名與 repo 名。
# 這個 repo 會被當成新專案的範本複製出去，寫死的話，新專案安裝的 hook
# 會拒絕它**自己**的合法遠端 —— 而且錯誤訊息還會叫使用者去推 Information-Study/pm。
# 單一來源是 .cxroot（cx:99 在動詞執行前 source，所以這裡讀得到）。
CX_DENIED_REMOTE_RE='team-of-P/'

# hook 檔裡的辨識標記。cx doctor 與 cx git guard status 靠它判斷「這是 cx 裝的」，
# 不能拿組織名來認 —— 換了名字的專案會全部顯示成沒安裝。
CX_GUARD_MARK='cx-push-guard'

_cx_guard_re_escape() { printf '%s' "${1//./\\.}"; }

cx_guard_repo_names() {
    local main=${CX_REPO_MAIN:-${CX_PROJECT_NAME:-}}
    [[ -n $main ]] || cx_die "$EX_PRECOND" ".cxroot 未定義 CX_REPO_MAIN／CX_PROJECT_NAME，無法組出推送白名單"
    printf '%s\n%s\n%s\n' "$main" \
        "${CX_REPO_BACKEND:-${main}-backend}" \
        "${CX_REPO_FRONTEND:-${main}-frontend}"
}

cx_guard_allow_re() {
    local org; org=$(_cx_guard_re_escape "${CX_GH_ORG:?.cxroot 未定義 CX_GH_ORG}")
    local n alts=''
    while read -r n; do alts+="|$(_cx_guard_re_escape "$n")"; done < <(cx_guard_repo_names)
    printf '^(https://github\\.com/|git@github\\.com:)%s/(%s)(\\.git)?/?$' "$org" "${alts#|}"
}

# 拒絕訊息裡列出的合法目標。訊息跟著白名單走，否則會叫使用者去推別人的 repo。
cx_guard_allow_list() {
    local n
    while read -r n; do printf '    github.com/%s/%s\n' "$CX_GH_ORG" "$n"; done < <(cx_guard_repo_names)
}

CX_ALLOWED_REMOTE_RE=$(cx_guard_allow_re)

cx_guard_hook_body() {
    # 前段要「展開」（把白名單烤進 hook：hook 執行時沒有 cx，讀不到 .cxroot），
    # 後段必須「不展開」（$remote_url 等要留到 hook 執行時才解析）。
    # 所以是兩個 heredoc，不是一個。
    cat <<HEAD
#!/usr/bin/env bash
# 由 cx git guard install 產生。請勿手動編輯。
# $CX_GUARD_MARK —— 這一行是 cx doctor / cx git guard status 的辨識標記，請勿刪除。
# 白名單來自 .cxroot；改了 .cxroot 之後要重跑 cx git guard install 才會生效。
set -uo pipefail

remote_name=\${1:-}
remote_url=\${2:-}

ALLOW_RE=$(printf '%q' "$(cx_guard_allow_re)")
DENY_RE=$(printf '%q' "$CX_DENIED_REMOTE_RE")
ALLOW_LIST=$(printf '%q' "$(cx_guard_allow_list)")
HEAD
    cat <<'HOOK'

say() { printf '%s\n' "$*" >&2; }

if printf '%s' "$remote_url" | grep -qE "$DENY_RE"; then
    say ''
    say '╔══════════════════════════════════════════════════════════════╗'
    say '║  推送被拒絕：目標位於永久黑名單                              ║'
    say '╚══════════════════════════════════════════════════════════════╝'
    say "  遠端  : $remote_name"
    say "  URL   : $remote_url"
    say ''
    say '  team-of-P/* 是本專案的舊遠端，已永久停用。'
    say '  這道封鎖不接受任何覆寫旗標，包含 CX_ALLOW_PUSH。'
    say ''
    exit 1
fi

if ! printf '%s' "$remote_url" | grep -qE "$ALLOW_RE"; then
    say ''
    say '╔══════════════════════════════════════════════════════════════╗'
    say '║  推送被拒絕：目標不在白名單內                                ║'
    say '╚══════════════════════════════════════════════════════════════╝'
    say "  遠端  : $remote_name"
    say "  URL   : $remote_url"
    say ''
    say '  唯一允許的推送目標：'
    say "$ALLOW_LIST"
    say ''
    exit 1
fi

if [ "${CX_ALLOW_PUSH:-0}" != "1" ]; then
    say ''
    say '╔══════════════════════════════════════════════════════════════╗'
    say '║  推送被攔截：需要顯式解鎖                                    ║'
    say '╚══════════════════════════════════════════════════════════════╝'
    say "  目標是合法的白名單遠端（$remote_url），但推送預設為拒絕。"
    say ''
    say '  正確做法：'
    say '    cx git push'
    say ''
    say '  （cx git push 會先做祕密掃描，並自動處理子模組先後順序）'
    say ''
    exit 1
fi

exit 0
HOOK
}

# 列出所有 repo（主庫 + 子模組），輸出絕對路徑
cx_guard_repos() {
    # 結尾必須成功：這個函式常被放進 <(...)，而子 shell 裡的 errexit 仍有效，
    # 迴圈最後一次條件為假就會讓整個 process substitution 以非零結束並觸發 ERR trap。
    printf '%s\n' "$CX_ROOT"
    local c
    for c in backend frontend; do
        if [[ -d $CX_ROOT/$c ]] && git -C "$CX_ROOT/$c" rev-parse --git-dir >/dev/null 2>&1; then
            printf '%s\n' "$CX_ROOT/$c"
        fi
    done
    return 0
}

cx_guard_install() {
    local r gd hook n=0
    while read -r r; do
        gd=$(git -C "$r" rev-parse --absolute-git-dir)
        mkdir -p "$gd/hooks"
        hook="$gd/hooks/pre-push"
        cx_guard_hook_body > "$hook"
        chmod +x "$hook"
        cx_ok "已安裝 pre-push hook：$(realpath --relative-to="$CX_ROOT" "$hook")"
        n=$((n + 1))
    done < <(cx_guard_repos)
    cx_ok "共 $n 個 repo"
}

cx_guard_status() {
    local r gd hook
    while read -r r; do
        gd=$(git -C "$r" rev-parse --absolute-git-dir)
        hook="$gd/hooks/pre-push"
        printf '  %-40s ' "$(realpath --relative-to="$(dirname "$CX_ROOT")" "$r")"
        if [[ -x $hook ]] && grep -q "$CX_GUARD_MARK" "$hook" 2>/dev/null; then
            printf 'hook ✔  '
        else
            printf 'hook ✘  '
        fi
        local u; u=$(git -C "$r" remote get-url origin 2>/dev/null || echo '(無 origin)')
        printf 'origin=%s\n' "$u"
    done < <(cx_guard_repos)
}

cx_guard_remove() {
    cx_confirm --danger "移除 push guard" \
        "將移除所有 repo 的 pre-push hook。\n\n之後任何 git push 都不會被攔截。\n\n確定嗎？" || return "$EX_ABORT"
    local r gd
    while read -r r; do
        gd=$(git -C "$r" rev-parse --absolute-git-dir)
        rm -f "$gd/hooks/pre-push"
        cx_warn "已移除：$(realpath --relative-to="$CX_ROOT" "$gd")/hooks/pre-push"
    done < <(cx_guard_repos)
}
