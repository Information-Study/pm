#!/usr/bin/env bash
# cx doctor — 檢查工具鏈與環境，並明確指出哪些能力目前被阻擋。

_dr_pass=0 _dr_warn=0 _dr_fail=0
_ok()   { printf '  \033[32m✔\033[0m %-34s %s\n' "$1" "${2:-}"; _dr_pass=$((_dr_pass+1)); }
_wr()   { printf '  \033[33m⚠\033[0m %-34s %s\n' "$1" "${2:-}"; _dr_warn=$((_dr_warn+1)); }
_fl()   { printf '  \033[31m✘\033[0m %-34s %s\n' "$1" "${2:-}"; _dr_fail=$((_dr_fail+1)); }

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
            printf '      \033[2m開啟 Docker Desktop → Settings → Resources → WSL Integration\033[0m\n'
            printf '      \033[2m阻擋：Phase 2 全部、Semgrep、ZAP、SonarQube、WAF\033[0m\n'
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
                 (( ${#pkgs[@]} )) && printf '      \033[2msudo apt install -y %s\033[0m\n' "${pkgs[*]}"
                 printf '      \033[2m阻擋：php artisan test（phpunit.xml 用記憶體 sqlite）\033[0m\n'; }
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
    [[ -d $CX_ROOT/frontend/node_modules ]] && _ok "frontend 相依" "已安裝" || _wr "frontend 相依" "尚未 npm ci"

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
        printf '      \033[2msudo apt install -y ansible-core（或 pipx install ansible）\033[0m\n'
        printf '      \033[2m阻擋：Phase 5 連 --syntax-check 都跑不了\033[0m\n'
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

    cx_step "結果"
    printf '  通過 %d  警告 %d  失敗 %d\n' "$_dr_pass" "$_dr_warn" "$_dr_fail"
    if (( _dr_fail )); then
        cx_warn "有阻擋項目。未驗證清單見 claude.md §12"
        return "$EX_PRECOND"
    fi
    (( _dr_warn )) && cx_warn "有降級項目，功能仍可用" || cx_ok "全部就緒"
    return 0
}
