#!/usr/bin/env bash
# cx status — 這棵樹現在是什麼狀態。
#
# ⚠ 與 cx doctor 的分工要講清楚，否則兩個動詞會慢慢長成同一個：
#     cx doctor — 「環境**能不能用**」。工具鏈、Docker daemon、埠、執行位元。
#                 有問題就回非 0，因為那是要修的東西。
#     cx status — 「這棵樹**現在是什麼狀態**」。身分、模式、容器、分支、
#                 gitlink、網址、上次驗收。
#
# 契約：**status 從不失敗，只報告。**
#   沒有 Docker、沒有 .env、連 .git 都沒有，它一樣要 rc=0 印出它知道的部分。
#   理由：這是接手專案的人打的第一個指令。一個在半成品的樹上會失敗的
#   「現況一覽」等於沒有 —— 而那正是最需要看現況的時刻。
#   要判斷「能不能用」請用 cx doctor，它會回非 0。

_status_usage() {
    cat >&2 <<'TXT'
用法：cx status [--short] [--json]

  （無參數）    完整的現況一覽
  --short       一行摘要（給提示字元或 CI 用）
  --json        機器可讀（給腳本用）

cx status 回答「這棵樹現在是什麼狀態」，cx doctor 回答「環境能不能用」。
status 從不失敗（rc 永遠是 0）—— 要靠退出碼判斷的請用 doctor。
TXT
}

# ── 各區塊的取值。每一個都要能在「那東西不存在」時回空字串而不是失敗 ──

_status_verify_last() {             # → "<時間戳> <通過> <失敗> <未驗>" 或空
    local f
    f=$(find "$CX_ROOT/reports/verify" -maxdepth 1 -name '*.md' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2-)
    [[ -n ${f:-} ]] || return 0
    # 報告最後一行是「**通過 N ・ 失敗 M ・ 未驗 K**」
    local line; line=$(grep -oE '通過 [0-9]+ ・ 失敗 [0-9]+ ・ 未驗 [0-9]+' "$f" | tail -1)
    [[ -n $line ]] || return 0
    printf '%s|%s' "$(basename "$f" .md)" "$line"
}

_status_containers() {              # _status_containers <模式> → "跑著/總數" 或 "-"
    local m=$1 proj
    cx_docker_ok || { printf '-'; return 0; }
    proj=$(cx_project_for "$m")
    local total running
    total=$(docker ps -a --filter "label=com.docker.compose.project=$proj" -q 2>/dev/null | wc -l)
    running=$(docker ps --filter "label=com.docker.compose.project=$proj" -q 2>/dev/null | wc -l)
    (( total )) || { printf '-'; return 0; }
    printf '%s/%s' "$running" "$total"
}

# 主庫索引裡的 gitlink 與子模組 HEAD 是否一致。
# 不一致不代表壞掉（feature 做到一半就是這樣），但它是「我現在該 commit 什麼」
# 的答案，而 git status 只會說「有未提交的變更」，看不出是哪一種。
_status_gitlink() {                 # _status_gitlink <子模組名> → 描述
    # ⚠ 不可以寫成 `local c=$1 d="$CX_ROOT/$c"`。bash 的 local 會先把**所有**
    #   名字宣告成 local（此刻是 unset），才依序賦值 —— 於是 d 的右邊讀到的
    #   是剛被遮蔽掉、還沒賦值的 c，在 set -u 之下直接 unbound variable。
    #   實測 bash 5.3.9。同一行的後面引用前面，只在沒有 local 時才成立。
    local c d idx head
    c=$1; d="$CX_ROOT/$c"
    [[ -e $d/.git ]] || { printf '（未初始化）'; return 0; }
    idx=$(git -C "$CX_ROOT" ls-files --stage -- "$c" 2>/dev/null | awk '{print $2}')
    head=$(git -C "$d" rev-parse HEAD 2>/dev/null || echo '')
    [[ -n $idx && -n $head ]] || { printf '（讀不到）'; return 0; }
    if [[ $idx == "$head" ]]; then
        printf '同步 %s' "${head:0:7}"
    else
        printf '主庫記錄 %s ≠ 子模組 %s（要 cx git commit）' "${idx:0:7}" "${head:0:7}"
    fi
}

_status_guard_count() {             # → "n/3"
    local n=0 total=0 r gd
    while read -r r; do
        total=$((total + 1))
        gd=$(git -C "$r" rev-parse --absolute-git-dir 2>/dev/null) || continue
        [[ -x $gd/hooks/pre-push ]] \
            && grep -q "$CX_GUARD_MARK" "$gd/hooks/pre-push" 2>/dev/null \
            && n=$((n + 1))
    done < <(cx_guard_repos 2>/dev/null)
    printf '%s/%s' "$n" "$total"
}

_status_short() {
    local br dirty
    br=$(git -C "$CX_ROOT" branch --show-current 2>/dev/null || echo '-')
    dirty=$(git -C "$CX_ROOT" status --porcelain 2>/dev/null | wc -l)
    printf '%s  mode=%s  runner=%s  branch=%s  dirty=%s  dev=%s test=%s prod=%s\n' \
        "$(cx_project)" "$CX_MODE" "$(cx_runner)" "$br" "$dirty" \
        "$(_status_containers dev)" "$(_status_containers test)" "$(_status_containers prod)"
}

_status_json() {
    local br dirty vlast
    br=$(git -C "$CX_ROOT" branch --show-current 2>/dev/null || echo '')
    dirty=$(git -C "$CX_ROOT" status --porcelain 2>/dev/null | wc -l)
    vlast=$(_status_verify_last)
    CX_S_PROJECT="$(cx_project)" CX_S_LAYOUT="${CX_LAYOUT_VERSION:-}" \
    CX_S_MODE="$CX_MODE" CX_S_RUNNER="$(cx_runner)" CX_S_FORCED="$(cx_runner_forced && echo 1 || echo 0)" \
    CX_S_BRANCH="$br" CX_S_DIRTY="$dirty" \
    CX_S_DEV="$(_status_containers dev)" CX_S_TEST="$(_status_containers test)" \
    CX_S_PROD="$(_status_containers prod)" \
    CX_S_GL_BE="$(_status_gitlink backend)" CX_S_GL_FE="$(_status_gitlink frontend)" \
    CX_S_GUARD="$(_status_guard_count)" CX_S_VERIFY="$vlast" \
    python3 -c '
import json, os
v = os.environ.get("CX_S_VERIFY", "")
stamp, _, summary = v.partition("|")
print(json.dumps({
    "project":  os.environ.get("CX_S_PROJECT", ""),
    "layout":   os.environ.get("CX_S_LAYOUT", ""),
    "mode":     os.environ.get("CX_S_MODE", ""),
    "runner":   {"resolved": os.environ.get("CX_S_RUNNER", ""),
                 "forced": os.environ.get("CX_S_FORCED") == "1"},
    "git":      {"branch": os.environ.get("CX_S_BRANCH", ""),
                 "dirty":  int(os.environ.get("CX_S_DIRTY") or 0),
                 "gitlink": {"backend":  os.environ.get("CX_S_GL_BE", ""),
                             "frontend": os.environ.get("CX_S_GL_FE", "")}},
    "containers": {"dev":  os.environ.get("CX_S_DEV", "-"),
                   "test": os.environ.get("CX_S_TEST", "-"),
                   "prod": os.environ.get("CX_S_PROD", "-")},
    "push_guard": os.environ.get("CX_S_GUARD", ""),
    "last_verify": {"stamp": stamp, "summary": summary},
}, ensure_ascii=False, indent=2))
'
}

cmd_status_main() {
    local short=0 as_json=0
    while (( $# )); do
        case $1 in
            -h|--help) _status_usage; return 0 ;;
            --short)   short=1; shift ;;
            --json)    as_json=1; shift ;;
            *) cx_die "$EX_USAGE" "status: 未知參數 $1（試試 cx status --help）" ;;
        esac
    done
    # guard.sh 提供 cx_guard_repos 與 CX_GUARD_MARK。status 不裝也不移除任何 hook，
    # 只是報告它們在不在。
    . "$CX_ROOT/bin/lib/guard.sh"
    # git.sh 提供 _git_status（三個 repo 的分支／領先落後）與 _git_is_repo_root。
    # ⚠ 重用而不是重寫：_git_status 裡的「領先落後」讀的是 remote-tracking ref
    #   而不是遠端本身（不連線），這件事講清楚過一次就夠了。抄一份的話，
    #   下次有人改了那個語意，status 印出來的數字會安靜地變成另一個意思。
    . "$CX_ROOT/bin/cmd/git.sh"

    (( short ))   && { _status_short; return 0; }
    (( as_json )) && { _status_json;  return 0; }

    cx_step "專案"
    printf '  名稱      : %s（版面 v%s）\n' "$(cx_project)" "${CX_LAYOUT_VERSION:-?}"
    printf '  GitHub    : %s/{%s, %s, %s}\n' "${CX_GH_ORG:-?}" \
        "${CX_REPO_MAIN:-?}" "${CX_REPO_BACKEND:-?}" "${CX_REPO_FRONTEND:-?}"
    printf '  分支模型  : %s ← %s\n' "${CX_GIT_MAIN_BRANCH:-main}" "${CX_GIT_DEV_BRANCH:-dev}"
    printf '  .env      : %s\n' \
        "$([[ -f $CX_ROOT/.env ]] && echo '存在' || echo '不存在（cx setup env）')"

    cx_step "執行環境"
    printf '  模式      : %s\n' "$CX_MODE"
    printf '  runner    : %s（%s）\n' "$(cx_runner)" \
        "$(cx_runner_forced && echo '指定' || echo '自動')"
    printf '  Docker    : %s\n' "$(cx_docker_ok && echo '可用' || echo '不可用')"
    printf '  容器      : dev %s ・ test %s ・ prod %s   （跑著/總數，- = 沒建過）\n' \
        "$(_status_containers dev)" "$(_status_containers test)" "$(_status_containers prod)"

    cx_step "Git"
    if _git_is_repo_root "$CX_ROOT" 2>/dev/null; then
        _git_status
        printf '\n  gitlink\n'
        printf '    backend  : %s\n' "$(_status_gitlink backend)"
        printf '    frontend : %s\n' "$(_status_gitlink frontend)"
        printf '  push guard : %s（選用，預設不安裝；cx git guard install）\n' \
            "$(_status_guard_count)"
    else
        printf '  （這棵樹還不是 git repo —— cx init 或 git init）\n'
    fi

    cx_step "服務網址"
    . "$CX_ROOT/bin/cmd/open.sh"
    local t url
    for t in front back api; do
        url=$(_open_url_of "$t" 2>/dev/null) && printf '  %-7s %s\n' "$t" "$url"
    done
    if url=$(_open_url_of pma 2>/dev/null) && [[ -n $url ]]; then
        printf '  %-7s %s\n' pma "$url"
    fi

    cx_step "上次驗收"
    local v; v=$(_status_verify_last)
    if [[ -n $v ]]; then
        printf '  %s\n  %s\n' "${v%%|*}" "${v#*|}"
        printf '  （SKIP 不等於通過。判準是 FAIL=0 **且 SKIP 沒有增加**）\n'
    else
        printf '  還沒跑過 —— cx verify\n'
    fi
    return 0
}
