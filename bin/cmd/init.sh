#!/usr/bin/env bash
# cx init / cx re-init — 把這個範本變成一個新專案。
#
# ⚠ 這支程式**幾乎沒有自己的邏輯**，而那是刻意的。
#
#   刪除 git 紀錄、重建前後端骨架、重新連結 submodule、確認閘門、封存與
#   rollback —— 這些全部已經在 `cx fresh` 裡，而且是本專案唯一經過對抗式
#   稽核與實跑驗證的破壞性程式碼（見 docs/progress.md 的 A-1..H-10）。
#   專案身分的改寫在 `cx rename`，GitHub repo 的建立在 `cx git remote-init`。
#
#   再寫一份「其實差不多」的流程，等於讓那三份保護各自演化然後分岔。
#   所以 init 只做三件事：把名字改對、按正確順序呼叫它們、在最前面問一次。
#
# 順序不可調換的理由：
#   rename 必須在 fresh **之前**。_fresh_git_init 會用 .cxroot 的
#   CX_REPO_BACKEND / CX_REPO_FRONTEND 重新產生 .gitmodules；先 fresh 再 rename
#   的話，.gitmodules 會帶著範本的舊名字被寫進新專案的第一個 commit。

_init_usage() {
    cat >&2 <<'TXT'
用法：cx init <新專案名> [選項]
      cx re-init [選項]

  init      把範本設定成一個**新專案**：改名 → 重建 → 接遠端
  re-init   同樣的重建流程，但**不改名**（拿來重來一次）

選項
  --org <組織>        GitHub 組織或使用者名稱（寫進 .cxroot 的 CX_GH_ORG）
  --gh                用 gh 建立三個 GitHub repo 並接上 origin
                      （等同事後跑 cx git remote-init）
  --remote <URL>      指到**現成**的主庫 remote；backend / frontend 由同一個
                      目錄推導（proj.git → proj-backend.git / proj-frontend.git）
  --mode <模式>       carryover（預設，把現有程式碼疊回去）或 scaffold（純新骨架）

  跳過確認閘門請用**全域**旗標 --yes（放在動詞前面）：
    cx --yes init shop        # 危險，只在拋棄式副本上用

這個動詞會做的事，等同依序執行：
  cx rename <新專案名>            # init 才有；re-init 跳過
  cx fresh --mode <模式>          # 刪 .git、重建骨架、重新連結 submodule、git init
  cx git remote-init | remote-set # --gh 或 --remote 才有

範例
  cx --dry-run init shop --org my-org        # 先看會動到什麼
  cx init shop --org my-org --gh
  cx init shop --remote git@github.com:me/shop.git
  cx re-init --mode carryover                # 名字不變，重建骨架但留下自己的程式碼
TXT
}

_init_parse() {                     # 共用的旗標解析；結果放進 _INIT_*
    # 預設 carryover，與 cx fresh 一致。
    #
    # 這裡曾經是 scaffold，而那會產出一個**缺零件**的新專案：
    # backend/ 不只是 Laravel 骨架，它還帶著範本自己接上去的三樣東西 ——
    #   app/Providers/Filament/AdminPanelProvider.php
    #   routes/api.php
    #   database/migrations/*_create_personal_access_tokens_table.php
    # 而 _fresh_rebuild_backend 只跑 create-project + require filament + require
    # larastan，**從不跑 filament:install --panels**（它只用 cx_dim 叫你自己跑）。
    # 於是 scaffold 出來的專案沒有後台、沒有 API 路由、沒有 Sanctum 資料表，
    # 而 cx verify app 正是在驗 /admin 與 /sanctum。
    #
    # 現在 templates/backend/ 也收了那三個檔、由 scaffold_patch.py 裝回去，
    # 所以兩個模式都能產出完整系統；carryover 當預設是因為它額外保住
    # 使用者自己寫的東西，誤打的代價小得多。
    _INIT_ORG=''; _INIT_GH=0; _INIT_REMOTE=''; _INIT_MODE=carryover
    while (( $# )); do
        case $1 in
            --org)    [[ -n ${2:-} ]] || cx_die "$EX_USAGE" "--org 需要值"
                      _INIT_ORG=$2; shift 2 ;;
            --gh)     _INIT_GH=1; shift ;;
            --remote) [[ -n ${2:-} ]] || cx_die "$EX_USAGE" "--remote 需要 URL"
                      _INIT_REMOTE=$2; shift 2 ;;
            --mode)   [[ -n ${2:-} ]] || cx_die "$EX_USAGE" "--mode 需要值"
                      _INIT_MODE=$2; shift 2 ;;
            -h|--help) _init_usage; return 2 ;;
            *) cx_die "$EX_USAGE" "未知參數：$1" ;;
        esac
    done
    case $_INIT_MODE in
        scaffold|carryover) : ;;
        *) cx_die "$EX_USAGE" "--mode 只能是 scaffold 或 carryover（收到 $_INIT_MODE）" ;;
    esac
    (( _INIT_GH )) && [[ -n $_INIT_REMOTE ]] \
        && cx_die "$EX_USAGE" "--gh 與 --remote 只能擇一（前者建立 repo，後者指到現成的）"
    return 0
}

# init 的閘門與 fresh 的不是同一個。
#
# fresh 要你打「DESTROY <目前的專案名>」—— 在 init 的情境裡那個名字還是範本的名字，
# 讓人打 DESTROY pm 而他其實想建立 shop，是在問錯的問題。
# 這裡改成打「INIT <新名字>」，同時把 init 特有的損失也列出來
#（.env 的密碼與 ansible/inventory/hosts.yml 都不在 fresh 的清單裡）。
_init_gate() {                      # _init_gate <token> <新名字或空> <模式>
    local token=$1 newname=$2 mode=$3
    local body
    body="這會把目前這棵樹改造成一個新專案，而且**不可逆**。

會發生的事：
  1. 刪掉 .git 與 .gitmodules —— 整個提交歷史消失
  2. 刪掉 backend/ 與 frontend/ 目前的內容"
    [[ $mode == scaffold ]] && body+="
     ⚠ --mode scaffold：**只產生全新骨架**。
        你自己寫的程式碼（app/ routes/ tests/ pages/ components/ …）
        不會被疊回去，只會留在封存裡。
        範本自己接的 Filament 後台、routes/api.php 與 Sanctum migration
        會由 templates/ 重新裝回，所以系統仍然是完整的。" \
                            || body+="
     --mode carryover（預設）：產生全新骨架之後，把 app/ routes/ tests/
        resources/ database/{migrations,seeders,factories} 從封存疊回去。
        框架骨架檔（config/ bootstrap/ package.json nuxt.config）用新版的。"
    body+="
  3. 用新的骨架重建，並重新連結 backend / frontend 兩個 submodule"
    [[ -n $newname ]] && body+="
  4. 專案身分改成「$newname」（.cxroot / .env / sonar / group_vars / site.yml）"
    body+="

**不會**被 fresh 保護、需要你自己確認的：
  * .env 裡的密碼與 APP_KEY 會保留 —— 新專案應該重新產生（cx setup env）
  * ansible/inventory/hosts.yml 還指向舊環境的主機
  * 已經跑起來的容器與 volume 仍叫舊名字（cx dev down -v 自己清）

執行之前會先做完整封存（cx fresh 的 backup 階段），失敗可以 cx fresh --rollback。

要繼續請輸入： $token"
    cx_ask_typed "確認：$token" "$body" "$token"
}

_init_do_remote() {
    if (( _INIT_GH )); then
        cx_step "建立 GitHub 遠端"
        cmd_git_main remote-init || return $?
    elif [[ -n $_INIT_REMOTE ]]; then
        cx_step "設定遠端"
        cmd_git_main remote-set "$_INIT_REMOTE" || return $?
    else
        cx_info "沒有指定遠端 —— 之後可以用："
        cx_dim "  cx git remote-init             # 用 gh 建立"
        cx_dim "  cx git remote-set <URL>        # 指到現成的"
    fi
}

_init_next_steps() {
    local name=$1
    cx_step "接下來"
    cx_dim "  1. cx setup env          重新產生 .env（新的密碼與 APP_KEY）"
    cx_dim "  2. cx setup deps         安裝前後端相依"
    cx_dim "  3. cx dev up -d --build  起開發環境"
    cx_dim "  4. cx verify cli docs tui static   應該全綠"
    cx_dim "  5. cx deploy hosts init  之後要部署時，建立主機清單"
    cx_dim "  6. cx git config identity --name … --email …   新 repo 沒有身分"
    [[ -n $name ]] && cx_dim "  7. 專案現在叫「$name」—— .gitmodules 已由 fresh 用新名字重新產生"
}

cmd_init_main() {
    # rename 與 fresh 各自住在自己的檔案裡；dispatcher 只 source 了 init.sh。
    # 用 source + 直接呼叫函式（而不是 "$CX_ROOT/cx" rename …）是刻意的：
    # 開子行程的話，rename 改完 .cxroot 之後，本行程仍然拿著舊的身分，
    # 後面的 fresh 與 remote 就會用錯名字。
    # shellcheck source=/dev/null
    . "$CX_ROOT/bin/cmd/rename.sh"
    # shellcheck source=/dev/null
    . "$CX_ROOT/bin/cmd/fresh.sh"
    # shellcheck source=/dev/null
    . "$CX_ROOT/bin/cmd/git.sh"
    . "$CX_ROOT/bin/lib/guard.sh"

    local verb=${CX_VERB:-init}
    local newname=''
    # 明確要說明 → 0；忘了給名字 → EX_USAGE。全庫慣例
    # （bin/test/00_dispatch.bats 的「每個動詞的 --help」在守這件事）。
    #
    # --help 出現在**任何位置**都算數。原本只看第一個參數，於是
    # `cx init --help` 回 0 而 `cx init shop --help` 落到 _init_parse 回 2 ——
    # 同一個旗標兩種退出碼。
    local _a
    for _a in "$@"; do
        case $_a in -h|--help) _init_usage; return "$EX_OK" ;; esac
    done
    if [[ $verb == init ]]; then
        [[ -n ${1:-} ]] || { _init_usage; return "$EX_USAGE"; }
        newname=$1; shift
    fi
    local _prc=0; _init_parse "$@" || _prc=$?
    (( _prc == 0 )) || return "$EX_USAGE"

    # ${_INIT_ORG:+--org "$_INIT_ORG"} 這種寫法是**沒有加引號**的展開，
    # 裡面的引號不構成分組 —— org 含空白時會被字詞分割成兩個參數，
    # rename 會回報「多餘的參數：org」而不是它自己的合法性訊息。用陣列。
    local -a _org_args=()
    [[ -n $_INIT_ORG ]] && _org_args=(--org "$_INIT_ORG")

    # 改名的合法性由 cx rename 自己驗（同一組規則，不要有第二份）
    local token
    if [[ -n $newname ]]; then token="INIT $newname"; else token="RE-INIT $(cx_project)"; fi

    if (( CX_DRY_RUN )); then
        cx_step "dry-run：$verb 會依序執行"
        [[ -n $newname ]] && cx_dim "  cx rename $newname${_INIT_ORG:+ --org $_INIT_ORG}"
        cx_dim "  cx fresh --mode $_INIT_MODE"
        (( _INIT_GH )) && cx_dim "  cx git remote-init"
        [[ -n $_INIT_REMOTE ]] && cx_dim "  cx git remote-set $_INIT_REMOTE"
        if [[ -n $newname ]]; then
            cx_info "以下是 rename 的變更點（fresh 的 dry-run 請單獨跑 cx --dry-run fresh）："
            cmd_rename_main "$newname" "${_org_args[@]}"
        else
            cx_dim "  （re-init 不改名，所以沒有 rename 的變更點）"
            cx_dim "  fresh 的 dry-run 請單獨跑： cx --dry-run fresh --mode $_INIT_MODE"
        fi
        return "$EX_OK"
    fi

    _init_gate "$token" "$newname" "$_INIT_MODE" || { cx_warn "已取消"; return "$EX_ABORT"; }

    # ── 1. 改名（必須在 fresh 之前，理由見檔頭）─────────────────────────────
    if [[ -n $newname ]]; then
        cx_step "改名：$(cx_project) → $newname"
        # rename 自己還會問一次；這裡已經過了 init 的閘門，所以直接放行
        CX_ASSUME_YES=1 cmd_rename_main "$newname" "${_org_args[@]}" \
            || { cx_error "改名失敗 —— 什麼都還沒破壞，可以直接重跑"; return "$EX_FAIL"; }
        # 重新載入身分，後面的 fresh / remote 才會用新名字
        # shellcheck source=/dev/null
        . "$CX_ROOT/.cxroot"
    elif [[ -n $_INIT_ORG ]]; then
        CX_ASSUME_YES=1 cmd_rename_main "$(cx_project)" --org "$_INIT_ORG" \
            || return "$EX_FAIL"
        # shellcheck source=/dev/null
        . "$CX_ROOT/.cxroot"
    fi

    # ── 2. 重建（fresh 擁有所有破壞性邏輯與 rollback）───────────────────────
    cx_step "重建（cx fresh --mode $_INIT_MODE）"
    CX_ASSUME_YES=1 cmd_fresh_main --mode "$_INIT_MODE" \
        || { cx_error "重建失敗"
             cx_dim "  封存還在，可以 cx fresh --rollback 回到動手之前"
             return "$EX_FAIL"; }

    # ── 3. 遠端 ─────────────────────────────────────────────────────────────
    _init_do_remote || cx_warn "遠端設定沒有完成 —— 之後可以自己跑 cx git remote-init/remote-set"

    cx_ok "$verb 完成"
    _init_next_steps "$newname"
}

# re-init 走同一支主程式；差別只在不吃「新名字」這個位置參數。
cmd_re-init_main() { cmd_init_main "$@"; }
