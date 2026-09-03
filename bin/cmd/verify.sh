#!/usr/bin/env bash
# cx verify —— 把 docs/docker-verification.md 的驗收清單變成可執行的檢查。
#
# 為什麼要有這個動詞：
# 那份文件列了 D1–D15、5 項阻斷級、12 項重大項目，全部是「請接手者逐項確認」。
# 人工逐項確認的問題是它只會做一次，而且結果會過期。
# 把它寫成程式之後，每次改完 compose / Dockerfile 都可以重跑，
# 並且把結果回填成一份帶時間戳的報告。
#
# 每個檢查回報三種結果：
#   PASS  真的驗過了
#   FAIL  真的壞了
#   SKIP  這次沒辦法驗（例如容器沒起來），**不算通過**
#
# SKIP 與 PASS 嚴格分開是刻意的 —— claude.md §12 的原則是
# 「沒跑過的就寫沒跑過」，不要因為程式碼看起來對就標成已驗證。

_verify_usage() {
    cat >&2 <<'TXT'
cx verify [範圍...]

範圍（可複選，省略 = static app ansible）
  static     不需要容器的檢查：compose 合併結果、Dockerfile、版本鎖定
  runtime    需要容器在跑：supervisord、vendor、端點、資料庫
  ansible    ansible-playbook --syntax-check + ansible-lint + yamllint
  app        應用層端點（/up、/admin、/sanctum、前端）
  all        全部（會依序把三個模式都起起來，很慢）

選項
  --report <檔案>   把 Markdown 報告寫到指定路徑
                    （預設 reports/verify/<時間戳>.md）
  --quiet           只印總結

範例
  cx verify                 # 靜態 + 應用 + ansible
  cx verify static
  cx verify runtime         # 需要先 cx dev up -d
  cx verify all             # 完整驗收（會起三個模式）
TXT
}

# ── 結果累積 ────────────────────────────────────────────────────────────────
_VF_PASS=0; _VF_FAIL=0; _VF_SKIP=0
_VF_ROWS=()

_vf() {
    # _vf <PASS|FAIL|SKIP> <編號> <標題> [備註]
    local st=$1 id=$2 title=$3 note=${4:-}
    case $st in
        PASS) _VF_PASS=$((_VF_PASS + 1)); printf '%s✔%s %-10s %s\n' "$C_GRN" "$C_RST" "$id" "$title" >&2 ;;
        FAIL) _VF_FAIL=$((_VF_FAIL + 1)); printf '%s✘%s %-10s %s\n' "$C_RED" "$C_RST" "$id" "$title" >&2
              [[ -n $note ]] && cx_dim "  $note" ;;
        SKIP) _VF_SKIP=$((_VF_SKIP + 1)); printf '%s–%s %-10s %s\n' "$C_YLW" "$C_RST" "$id" "$title" >&2
              [[ -n $note ]] && cx_dim "  $note" ;;
    esac
    _VF_ROWS+=("$st|$id|$title|$note")
}

# 用合併後的 compose 設定作為事實來源。grep yaml 檔會漏掉 overlay 的影響。
_vf_config() {
    local mode=$1 out="$CX_ROOT/.cx/verify-config-$1.json"
    [[ -f $out ]] && { printf '%s' "$out"; return 0; }
    cx_ensure_host_dirs "$CX_ROOT/.cx" >/dev/null 2>&1
    local -a a=(--project-directory "$CX_ROOT" -p "pm_${mode}"
                -f "$CX_ROOT/docker-compose.yml" -f "$CX_ROOT/docker/compose/${mode}.yml")
    local f
    for f in "$CX_ROOT/.env" "$CX_ROOT/docker/env/${mode}.env"; do
        [[ -f $f ]] && a+=(--env-file "$f")
    done
    docker compose "${a[@]}" config --format json >"$out" 2>/dev/null || return 1
    printf '%s' "$out"
}

_vf_py() { python3 "$CX_ROOT/bin/lib/verify_checks.py" "$@"; }

# ── static ─────────────────────────────────────────────────────────────────
_verify_static() {
    cx_step "靜態驗收（不需要容器）"
    cx_docker_need
    local m ok=1
    for m in dev test prod; do
        _vf_config "$m" >/dev/null || { _vf FAIL "cfg-$m" "compose 設定可合併" "docker compose config 失敗"; ok=0; }
    done
    (( ok )) || return 0

    local st id title note line
    while IFS=$'\t' read -r st id title note; do
        [[ -z ${st:-} ]] && continue
        _vf "$st" "$id" "$title" "$note"
    done < <(_vf_py "$CX_ROOT")
}

# ── runtime ────────────────────────────────────────────────────────────────
# 需要對應模式的容器正在跑。沒跑就 SKIP —— SKIP 不是 PASS。
_verify_runtime_mode() {
    local mode=$1
    cx_compose_init "$mode"

    if ! cx_dc_q ps --status running --services 2>/dev/null | grep -qx app; then
        _vf SKIP "rt-$mode" "$mode 執行期檢查" "app 容器沒在跑（cx $mode up -d）"
        return 0
    fi

    # D5：supervisord 真的在管四個程式。
    # 舊版 CMD 陣列的第 4 個元素變成 sh -c 的 $0，supervisord 從未啟動 ——
    # 也就是 queue worker 從來沒跑過，而且沒有任何錯誤訊息。
    local sup
    sup=$(cx_dc_q exec -T app supervisorctl status 2>/dev/null </dev/null) || sup=''
    local running
    running=$(printf '%s\n' "$sup" | grep -c RUNNING || true)
    if (( running >= 4 )); then
        _vf PASS "D5-$mode" "supervisord 管理 $running 個程式" \
            "$(printf '%s\n' "$sup" | awk '{printf "%s ", $1}')"
    else
        _vf FAIL "D5-$mode" "supervisord 管理 ≥4 個程式" "只有 $running 個 RUNNING：$sup"
    fi

    # D6：vendor 沒被 bind mount 蓋掉。
    if cx_dc_q exec -T app test -f vendor/autoload.php </dev/null 2>/dev/null; then
        _vf PASS "D6-$mode" "vendor/autoload.php 存在"
    else
        _vf FAIL "D6-$mode" "vendor/autoload.php 存在" "bind mount 蓋掉了 image 裡的 vendor"
    fi

    # D2：entrypoint 產生 .env 與 APP_KEY。
    if cx_dc_q exec -T app sh -c 'grep -q "^APP_KEY=base64:" .env' </dev/null 2>/dev/null; then
        _vf PASS "D2-$mode" ".env 與 APP_KEY 已就緒"
    else
        _vf FAIL "D2-$mode" ".env 與 APP_KEY 已就緒" "entrypoint 沒有產生 APP_KEY"
    fi

    # D12：prod 映像不得含 xdebug（build 斷言的執行期複驗）。
    if [[ $mode == prod ]]; then
        if cx_dc_q exec -T app sh -c 'php -m | grep -qi "^xdebug$"' </dev/null 2>/dev/null; then
            _vf FAIL "D12rt" "prod 執行期無 xdebug" "php -m 找得到 xdebug"
        else
            _vf PASS "D12rt" "prod 執行期無 xdebug"
        fi
    fi

    # migration 真的跑過。
    local tables
    tables=$(cx_dc_q exec -T mysql sh -c \
        'exec mysql -N -h 127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE()" '"${DB_DATABASE:-pm}" \
        </dev/null 2>/dev/null | tr -dc '0-9') || tables=''
    if [[ -n $tables ]] && (( tables > 0 )); then
        _vf PASS "db-$mode" "migration 已執行" "$tables 個資料表"
    else
        _vf FAIL "db-$mode" "migration 已執行" "查不到資料表"
    fi
}

# ── app（端點）─────────────────────────────────────────────────────────────
_verify_app_mode() {
    local mode=$1 base=$2
    local -a checks=(
        "/up|200|Laravel 健康檢查（bootstrap/app.php 的 health:）"
        "/|200|Nuxt 首頁（edge 轉給 nuxt:3000）"
        "/healthz|200|edge 自己的健康檢查"
        "/admin/login|200|Filament 後台登入頁"
        "/sanctum/csrf-cookie|204|Sanctum SPA 認證的第一步"
    )
    local spec path want desc got
    for spec in "${checks[@]}"; do
        IFS='|' read -r path want desc <<< "$spec"
        got=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "${base}${path}" 2>/dev/null || echo 000)
        if [[ $got == "$want" ]]; then
            _vf PASS "ep-$mode" "$path → $got" "$desc"
        else
            _vf FAIL "ep-$mode" "$path → $got（預期 $want）" "$desc"
        fi
    done
    # API 未認證要回 401，不是 500。
    got=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "${base}/api/user" 2>/dev/null || echo 000)
    if [[ $got == 401 ]]; then
        _vf PASS "ep-$mode" "/api/user → 401（未認證）"
    else
        _vf FAIL "ep-$mode" "/api/user → $got（預期 401）" \
            "500 通常代表 bootstrap/app.php 沒設 redirectGuestsTo，Laravel 去找不存在的 login 路由"
    fi
}

# ── ansible ────────────────────────────────────────────────────────────────
_verify_ansible() {
    cx_step "Ansible 驗收"
    if ! cx_have ansible-playbook; then
        _vf SKIP "ans-syntax" "ansible-playbook --syntax-check" "沒有 ansible（cx setup tools ansible）"
        _vf SKIP "ans-lint" "ansible-lint" "沒有 ansible-lint"
        return 0
    fi
    # shellcheck source=/dev/null
    . "$CX_ROOT/bin/cmd/deploy.sh"
    if _deploy_syntax >/dev/null 2>&1; then
        _vf PASS "ans-syntax" "三個 playbook 的 --syntax-check"
    else
        _vf FAIL "ans-syntax" "三個 playbook 的 --syntax-check" "跑 cx deploy syntax 看細節"
    fi
    if cx_have ansible-lint; then
        if _deploy_lint >/dev/null 2>&1; then
            _vf PASS "ans-lint" "ansible-lint（production profile）+ yamllint"
        else
            _vf FAIL "ans-lint" "ansible-lint（production profile）+ yamllint" "跑 cx deploy lint 看細節"
        fi
    else
        _vf SKIP "ans-lint" "ansible-lint" "未安裝"
    fi
}

# ── 報告 ───────────────────────────────────────────────────────────────────
_verify_report() {
    local out=$1 row st id title note
    cx_ensure_host_dirs "$(dirname "$out")"
    {
        printf '# cx verify 報告\n\n'
        printf '產生時間：%s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '主機：%s ・ Docker：%s ・ Compose：%s\n\n' \
            "$(uname -srm)" \
            "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 不可用)" \
            "$(docker compose version --short 2>/dev/null || echo 不可用)"
        printf '| 結果 | 編號 | 項目 | 備註 |\n|---|---|---|---|\n'
        for row in "${_VF_ROWS[@]}"; do
            IFS='|' read -r st id title note <<< "$row"
            local mark
            case $st in
                PASS) mark='✅' ;;
                FAIL) mark='❌' ;;
                *)    mark='⬜' ;;
            esac
            printf '| %s | %s | %s | %s |\n' "$mark" "$id" "$title" "${note//|/\|}"
        done
        printf '\n**通過 %d ・ 失敗 %d ・ 未驗 %d**\n\n' "$_VF_PASS" "$_VF_FAIL" "$_VF_SKIP"
        printf '> ⬜（未驗）不等於通過。原則見 claude.md §12：沒跑過的就寫沒跑過。\n'
    } > "$out"
    cx_ok "報告：$out"
}

cmd_verify_main() {
    local -a scopes=()
    local report='' quiet=0
    while (( $# )); do
        case $1 in
            -h|--help|help) _verify_usage; return 0 ;;
            --report) report=$(cx_resolve "${2:?--report 需要路徑}"); shift 2 ;;
            --report=*) report=$(cx_resolve "${1#*=}"); shift ;;
            --quiet) quiet=1; shift ;;
            static|runtime|ansible|app|all) scopes+=("$1"); shift ;;
            *) cx_error "未知的範圍：$1"; _verify_usage; return "$EX_USAGE" ;;
        esac
    done
    (( ${#scopes[@]} )) || scopes=(static app ansible)

    local s
    for s in "${scopes[@]}"; do
        [[ $s == all ]] && { scopes=(static runtime app ansible); break; }
    done

    # 清掉上一次的設定快取，確保這次讀到的是現在的 compose 檔。
    rm -f "$CX_ROOT/.cx/verify-config-"*.json 2>/dev/null || true

    for s in "${scopes[@]}"; do
        case $s in
            static)  _verify_static ;;
            ansible) _verify_ansible ;;
            runtime)
                cx_docker_need
                cx_step "執行期驗收"
                local m
                for m in dev test prod; do _verify_runtime_mode "$m"; done
                ;;
            app)
                cx_step "應用端點驗收"
                cx_docker_need
                local m port
                for m in dev test prod; do
                    port=$(grep -E '^EDGE_HTTP_PORT=' "$CX_ROOT/docker/env/$m.env" 2>/dev/null | cut -d= -f2)
                    [[ -n $port ]] || continue
                    if curl -s -o /dev/null -m 5 "http://localhost:$port/healthz" 2>/dev/null; then
                        _verify_app_mode "$m" "http://localhost:$port"
                    else
                        _vf SKIP "ep-$m" "$m 端點檢查" "edge 沒有回應（cx $m up -d）"
                    fi
                done
                ;;
        esac
    done

    cx_step "總結"
    printf '  %s通過 %d%s ・ %s失敗 %d%s ・ %s未驗 %d%s\n' \
        "$C_GRN" "$_VF_PASS" "$C_RST" "$C_RED" "$_VF_FAIL" "$C_RST" \
        "$C_YLW" "$_VF_SKIP" "$C_RST" >&2

    [[ -n $report ]] || report="$CX_ROOT/reports/verify/$(date -u +%Y%m%dT%H%M%SZ).md"
    _verify_report "$report"

    (( _VF_FAIL == 0 )) || return "$EX_FAIL"
    return 0
}
