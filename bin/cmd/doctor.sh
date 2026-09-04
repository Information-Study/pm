#!/usr/bin/env bash
# cx doctor — 檢查工具鏈與環境，並明確指出哪些能力目前被阻擋。

_dr_pass=0 _dr_warn=0 _dr_fail=0
# 與 cx_* 家族一致：輸出走 stderr，顏色由 common.sh 依 [[ -t 2 ]] 決定，
# 這樣 `cx doctor > report.txt` 才不會夾雜跳脫序列、也不會把區段標題丟到另一個串流。
_ok()   { printf '  %s✔%s %-34s %s\n' "$C_GRN" "$C_RST" "$1" "${2:-}" >&2; _dr_pass=$((_dr_pass+1)); }
_wr()   { printf '  %s⚠%s %-34s %s\n' "$C_YLW" "$C_RST" "$1" "${2:-}" >&2; _dr_warn=$((_dr_warn+1)); }
_fl()   { printf '  %s✘%s %-34s %s\n' "$C_RED" "$C_RST" "$1" "${2:-}" >&2; _dr_fail=$((_dr_fail+1)); }

cmd_doctor_main() {
    cx_step "專案"
    _ok "CX_ROOT" "$CX_ROOT"
    [[ -f $CX_ROOT/.cxroot ]] && _ok ".cxroot" "layout v${CX_LAYOUT_VERSION:-?}" || _fl ".cxroot" "缺少"
    [[ -f $CX_ROOT/claude.md ]] && _ok "claude.md" || _wr "claude.md" "缺少"

    cx_step "容器"
    # command -v docker 會騙人：WSL 上 CLI 在 PATH 但 daemon 不通
    if cx_have docker; then
        if cx_docker_ok; then
            _ok "Docker daemon" "$(docker version --format '{{.Server.Version}}')"
        else
            _fl "Docker daemon" "CLI 在 PATH 但 daemon 不通"
            cx_dim '開啟 Docker Desktop → Settings → Resources → WSL Integration'
            cx_dim '阻擋：Phase 2 全部、Semgrep、ZAP、SonarQube、WAF'
        fi
    else
        _fl "Docker" "未安裝"
    fi
    cx_have docker && docker compose version >/dev/null 2>&1 \
        && _ok "docker compose" "$(docker compose version --short 2>/dev/null)" \
        || _wr "docker compose" "不可用"

    cx_step "後端工具鏈"
    if cx_have php; then
        _ok "PHP" "$(php -r 'echo PHP_VERSION;')"
        local miss=()
        for e in intl mbstring xml curl zip gd pdo_mysql openssl tokenizer fileinfo; do
            php -m | grep -qix "$e" || miss+=("$e")
        done
        (( ${#miss[@]} == 0 )) && _ok "PHP 必要擴充" "齊備" || _fl "PHP 擴充缺少" "${miss[*]}"
        # 擴充名 → apt 套件名（php8.5-sqlite3 同時提供 sqlite3 與 pdo_sqlite，
        # 沒有 php8.5-pdo_sqlite 這個套件）
        local opt=() pkgs=()
        for e in bcmath sqlite3; do
            php -m | grep -qix "$e" || { opt+=("$e"); pkgs+=("php8.5-$e"); }
        done
        php -m | grep -qix pdo_sqlite || opt+=("pdo_sqlite")
        (( ${#opt[@]} == 0 )) && _ok "PHP 選用擴充" "齊備" \
            || { _wr "PHP 選用擴充缺少" "${opt[*]}"
                 (( ${#pkgs[@]} )) && cx_dim "sudo apt install -y ${pkgs[*]}"
                 cx_dim '這只影響「在 host 上直接跑 php artisan test」。'
                 cx_dim '容器映像已內建 pdo_sqlite，cx test back 不受影響。'; }
    else
        _fl "PHP" "未安裝"
    fi
    cx_have composer && _ok "Composer" "$(composer --version 2>/dev/null | awk '{print $3}')" || _fl "Composer" "未安裝"
    [[ -x $CX_ROOT/backend/vendor/bin/phpstan ]] && _ok "Larastan" "已安裝" || _wr "Larastan" "未安裝"

    cx_step "前端工具鏈"
    if cx_have node; then
        local nv; nv=$(node --version)
        _ok "Node" "$nv"
        [[ ${nv#v} =~ ^(22\.(19|[2-9][0-9])|2[46]\.) ]] \
            || _wr "Node 版本" "Nuxt 4 需要 ^22.19 || ^24.11 || >=26"
    else _fl "Node" "未安裝"; fi
    cx_have npm && _ok "npm" "$(npm --version)" || _fl "npm" "未安裝"
    [[ -d $CX_ROOT/frontend/node_modules/nuxt ]] && _ok "frontend 相依" "已安裝" || _wr "frontend 相依" "尚未 npm ci"

    cx_step "DevSecOps"
    cx_have trivy    && _ok "Trivy" "$(trivy --version 2>/dev/null | head -1 | awk '{print $2}')" \
                     || _wr "Trivy" "未安裝（原生 SCA 不可用）"
    cx_have gitleaks && _ok "gitleaks" "$(gitleaks version 2>/dev/null)" \
                     || _wr "gitleaks" "未安裝（歷史祕密掃描不可用）"
    if cx_have semgrep; then _ok "Semgrep" "$(semgrep --version 2>/dev/null)"
    elif cx_docker_ok;  then _ok "Semgrep" "將以 docker runner 執行"
    else _wr "Semgrep" "不可用 —— 需 Docker 或 pip（本機兩者皆無）"; fi
    if cx_docker_ok; then _ok "OWASP ZAP" "將以 docker runner 執行"
    else _wr "OWASP ZAP" "不可用 —— 需 Docker（本機無 Java runtime）"; fi

    cx_step "Ansible"
    if cx_have ansible-playbook; then
        _ok "ansible-playbook" "$(ansible-playbook --version 2>/dev/null | head -1 | awk '{print $NF}' | tr -d ']')"
    else
        _wr "ansible" "未安裝 —— 只能用 cx lint 做靜態檢查"
        cx_dim 'sudo apt install -y ansible-core（或 pipx install ansible）'
        cx_dim '阻擋：Phase 5 連 --syntax-check 都跑不了'
    fi
    cx_have ansible-lint && _ok "ansible-lint" || _wr "ansible-lint" "未安裝"

    cx_step "介面與 Git"
    cx_have whiptail && _ok "whiptail" "TUI 可用" \
        || { cx_have dialog && _ok "dialog" "TUI 可用（降級）" || _wr "TUI" "將使用純文字模式"; }
    cx_have gh && gh auth status >/dev/null 2>&1 \
        && _ok "gh" "已登入 $(gh api /user --jq .login 2>/dev/null)" || _wr "gh" "未安裝或未登入"

    . "$CX_ROOT/bin/lib/guard.sh"
    local r gd n=0 tot=0
    while read -r r; do
        tot=$((tot+1)); gd=$(git -C "$r" rev-parse --absolute-git-dir 2>/dev/null) || continue
        [[ -x $gd/hooks/pre-push ]] && grep -q Information-Study "$gd/hooks/pre-push" 2>/dev/null && n=$((n+1))
    done < <(cx_guard_repos)
    (( n == tot )) && _ok "push guard" "$n/$tot 個 repo" || _fl "push guard" "只有 $n/$tot —— 執行 cx git guard install"

    cx_step "可執行位元"
    # 這個 repo 的進入點必須可執行。git index 曾經把 cx 的模式記成 100644
    # 而磁碟是 755 —— 內容零差異，git diff 看不出來，但一旦提交，
    # 任何人 clone 下來打 ./cx 都是 Permission denied。
    # 清單是「相對 CX_ROOT」的路徑（cd 只發生在下面那個 process substitution 的
    # 子 shell 裡，不影響這裡的 cwd）。所以測試一定要自己補上 $CX_ROOT/ ——
    # 少了它，從任何子目錄執行 cx doctor 都會把 28 個檔案全部誤報成
    # 「磁碟未設執行位元」，而在專案根目錄執行卻完全正常。
    local f nx=0 idx_bad=0
    while IFS= read -r f; do
        [[ -x $CX_ROOT/$f ]] || { _fl "磁碟未設執行位元" "$f"; nx=$((nx+1)); }
        if git -C "$CX_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
            local m; m=$(git -C "$CX_ROOT" ls-files -s -- "$f" 2>/dev/null | awk '{print $1}')
            [[ -n $m && $m != 100755 ]] && { _fl "git index 模式錯誤" "$f（$m，應為 100755）"; idx_bad=$((idx_bad+1)); }
        fi
    done < <(cd "$CX_ROOT" && ls cx bin/lib/*.sh bin/cmd/*.sh bin/lib/*.py 2>/dev/null)
    (( nx == 0 && idx_bad == 0 )) && _ok "cx 與 bin/ 的執行位元" "磁碟與 git index 皆正確"
    (( idx_bad )) && cx_dim "修正： git update-index --chmod=+x <檔案>"

    cx_step "Phase 2 產出物"
    # 這些檔案是 cx dev/test/prod 的前提。缺任何一個，對應的動詞都會在
    # cx_compose_init 就 EX_PRECOND —— 早點在 doctor 講清楚比較好。
    local need_missing=0 p
    for p in docker-compose.yml \
             docker/compose/dev.yml docker/compose/test.yml docker/compose/prod.yml \
             docker/compose/sonar.yml \
             docker/env/dev.env docker/env/test.env docker/env/prod.env \
             docker/php/Dockerfile docker/nuxt/Dockerfile \
             docker/edge/nginx.conf docker/edge/conf.d/default.conf \
             docker/entrypoint/app.sh .dockerignore .env.example; do
        [[ -e $CX_ROOT/$p ]] || { _fl "缺少檔案" "$p"; need_missing=1; }
    done
    (( need_missing )) || _ok "Docker 三模式的檔案" "compose / Dockerfile / edge / entrypoint 齊全"

    # .env 是硬失敗不是警告：compose 的 MYSQL_ROOT_PASSWORD 是 :? 必填，
    # 少了它每一個 docker 動詞都會在做任何事之前就死掉。
    if [[ -f $CX_ROOT/.env ]]; then
        if grep -q '__CHANGE_ME__' "$CX_ROOT/.env" 2>/dev/null; then
            _fl ".env" "仍有 __CHANGE_ME__ 佔位字串（跑 cx setup env）"
        else
            _ok ".env" "存在且已填值"
        fi
    else
        _fl ".env" "不存在 —— 跑 cx setup env"
        cx_dim "  這是硬失敗：compose 的 MYSQL_ROOT_PASSWORD 是 :? 必填變數"
    fi

    cx_step "cx 動詞完整性"
    # dispatcher 的 CX_CMD_FILE_OF 曾經把 8 個動詞指到一個不存在的
    # bin/cmd/compose.sh，於是 cx up 直接「未知的指令」。
    # 這裡實際檢查每個對外動詞都找得到實作檔。
    local v file missing_verbs=()
    for v in help doctor setup lint scan verify git fresh tui install art composer npm \
             db test sonar deploy compose; do
        file="$CX_ROOT/bin/cmd/${v}.sh"
        [[ -f $file ]] || missing_verbs+=("$v")
    done
    if (( ${#missing_verbs[@]} )); then
        _fl "動詞實作檔" "缺少：${missing_verbs[*]}"
    else
        _ok "動詞實作檔" "18 個全部存在"
    fi

    cx_step "結果"
    printf '  通過 %d  警告 %d  失敗 %d\n' "$_dr_pass" "$_dr_warn" "$_dr_fail" >&2
    if (( _dr_fail )); then
        cx_warn "有阻擋項目。未驗證清單見 claude.md §12"
        return "$EX_PRECOND"
    fi
    (( _dr_warn )) && cx_warn "有降級項目，功能仍可用" || cx_ok "全部就緒"
    return 0
}
