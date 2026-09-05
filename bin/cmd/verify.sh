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

範圍（可複選，省略 = static app ansible cli docs tui）
  不需要 Docker、不需要 .env，在全新 clone 上就能跑：
  cli        cx 自己：動詞／旗標／補全／help 四方同步
  docs       文件與實作是否一致（教的變數真的被讀嗎、路徑對嗎）
  tui        選單每一項都指得到真的存在的指令，且每個動詞都到得了

  需要合併後的 compose 設定（要有 .env）：
  static     compose 合併結果、Dockerfile、版本鎖定

  需要容器在跑：
  runtime    supervisord、vendor、APP_KEY、xdebug
  app        應用層端點（/up、/admin、/sanctum、前端）
  waf        ModSecurity：攻擊被擋、正常請求不被擋、引擎狀態與宣告一致
  acl        檔案權限（POSIX ACL）

  其他：
  ansible    ansible-playbook --syntax-check + ansible-lint + yamllint
  all        全部（會依序把三個模式都起起來，很慢）

選項
  --report <檔案>   把 Markdown 報告寫到指定路徑
                    （預設 reports/verify/<時間戳>.md）
  --quiet           只印總結

範例
  cx verify                 # 預設：不需要容器的那些 + 應用端點 + ansible
  cx verify cli docs tui    # 全新 clone 上就能跑，秒級
  cx verify runtime         # 需要先 cx dev up -d
  cx verify waf             # 需要先 cx test up -d
  cx verify all             # 完整驗收（會起三個模式）
TXT
}

# ── 結果累積 ────────────────────────────────────────────────────────────────
_VF_PASS=0; _VF_FAIL=0; _VF_SKIP=0
_VF_ROWS=()

# --quiet：只印總結。
#
# ⚠ 這個旗標原本 parser 收得下（quiet=1）但**沒有任何地方讀它** ——
#   也就是說 usage 宣傳了一個沒有效果的旗標。CLI-flags 那個檢查只驗
#   「parser 接不接受」，接受但不做事它看不出來。
#   FAIL 一律照印：安靜模式的用途是少看雜訊，不是把壞消息藏起來。
_VF_QUIET=0

_vf() {
    # _vf <PASS|FAIL|SKIP> <編號> <標題> [備註]
    local st=$1 id=$2 title=$3 note=${4:-}
    if (( _VF_QUIET )) && [[ $st != FAIL ]]; then
        case $st in
            PASS) _VF_PASS=$((_VF_PASS + 1)) ;;
            SKIP) _VF_SKIP=$((_VF_SKIP + 1)) ;;
        esac
        _VF_ROWS+=("$st|$id|$title|$note")
        return 0
    fi
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
    # -p 必須跟 cx_compose_init 一致。寫死 pm_ 的話，改名後的專案會把
    # config 快取建在別的 compose project 底下，接著 check 2.5 會拿
    # pm_<mode>_net 去比對真實的 <專案>_<mode>_net，全部判 FAIL ——
    # 一個全新的範本專案開箱就報驗證失敗。
    local -a a=(--project-directory "$CX_ROOT" -p "$(cx_project_for "$mode")"
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

    # D2：APP_KEY 就緒。2026-09-05 起兩個模式的判準不同 ——
    #
    #   dev        .env 是 host bind mount 進來的真檔案，entrypoint 產生 APP_KEY
    #              並持久化在那裡。判準：.env 裡有 APP_KEY=base64:。
    #
    #   test/prod  .env 被 .dockerignore 排除（否則開發者的 APP_KEY 與
    #              DB_PASSWORD 會被烘進映像層），改由 compose 注入。
    #              判準更強：APP_KEY 必須在**環境變數**裡，而且容器內
    #              **不可以有 .env** —— 有的話代表 entrypoint 又在 writable
    #              layer 寫了一把金鑰，那把金鑰會在下次 --force-recreate 消失。
    if [[ $mode == dev ]]; then
        if cx_dc_q exec -T app sh -c 'grep -q "^APP_KEY=base64:" .env' </dev/null 2>/dev/null; then
            _vf PASS "D2-$mode" "APP_KEY 已就緒（.env 持久化）"
        else
            _vf FAIL "D2-$mode" "APP_KEY 已就緒（.env 持久化）" "entrypoint 沒有產生 APP_KEY"
        fi
    else
        local _k _hasenv
        _k=$(cx_dc_q exec -T app sh -c 'printf %s "${APP_KEY:-}"' </dev/null 2>/dev/null)
        _hasenv=$(cx_dc_q exec -T app sh -c 'test -f .env && echo yes || echo no' </dev/null 2>/dev/null)
        if [[ $_k != base64:* ]]; then
            _vf FAIL "D2-$mode" "APP_KEY 由環境注入" \
                "容器的 APP_KEY 不是 base64: 開頭（實際：${_k:-（空）}）"
        elif [[ ${_hasenv//[[:space:]]/} == yes ]]; then
            _vf FAIL "D2-$mode" "APP_KEY 由環境注入" \
                "容器內仍有 .env —— 那把金鑰在 writable layer，重建容器就會換掉"
        else
            _vf PASS "D2-$mode" "APP_KEY 由環境注入（容器內無 .env）"
        fi
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

# ── cli / docs / tui ───────────────────────────────────────────────────────
# 這三個完全不碰 Docker 也不需要 .env —— 在一個剛 clone 下來、什麼都還沒裝的
# 樹上就能跑完。這是刻意的：本專案已知的缺陷有一半以上是「兩個檔案對同一件事
# 的說法不一致」，那一類完全不需要執行環境就驗得出來，也就沒有理由讓它們
# 卡在「要先把三個模式起起來」後面。
_verify_meta() {
    local family=$1 title=$2 line st id t note
    cx_step "$title"
    while IFS= read -r line; do
        [[ -n $line ]] || continue
        IFS='|' read -r st id t note <<< "$line"
        _vf "$st" "$id" "$t" "$note"
    done < <(CX_ROOT="$CX_ROOT" python3 "$CX_ROOT/bin/lib/verify_meta.py" "$family" 2>/dev/null)
}

# ── waf ────────────────────────────────────────────────────────────────────
# 為什麼要獨立一個範圍：既有的 app 範圍只打 edge，完全不經過 WAF；
# 而 scan dast 那條 lane 的閘門是「無 High risk alert」，它不會告訴你
# **正常請求被擋掉了**。2026-09-05 之前的狀態正是：攻擊 100% 全擋、
# Filament 後台完全不能用，兩件事同時成立而且沒有任何檢查會發現。
_verify_waf() {
    cx_step "WAF 驗收（test 模式）"
    local proj port
    proj=$(cx_project_for test)
    port=$(grep -E '^WAF_HTTP_PORT=' "$CX_ROOT/docker/env/test.env" 2>/dev/null | cut -d= -f2)
    port=${port:-18081}

    local cid
    cid=$(docker ps --filter "label=com.docker.compose.project=$proj" \
                    --filter "label=com.docker.compose.service=waf" -q 2>/dev/null | head -1)
    if [[ -z $cid ]]; then
        _vf SKIP "waf-up" "WAF 容器在跑" "cx test up -d"
        return 0
    fi
    _vf PASS "waf-up" "WAF 容器在跑"

    # 宣告值與實際值必須一致。這一項抓的是 cx scan dast 切換引擎之後沒還原
    # 造成的漂移 —— 環境跟版控說的不一樣，而且沒有任何地方會提醒你。
    local declared actual
    declared=$(grep -E '^MODSEC_RULE_ENGINE=' "$CX_ROOT/docker/env/test.env" 2>/dev/null | cut -d= -f2)
    declared=${declared:-DetectionOnly}
    actual=$(docker inspect "$cid" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
             | sed -n 's/^MODSEC_RULE_ENGINE=//p' | head -1)
    if [[ $actual == "$declared" ]]; then
        _vf PASS "waf-engine" "引擎狀態與 test.env 宣告一致" "$actual"
    else
        _vf FAIL "waf-engine" "引擎狀態與 test.env 宣告一致" \
            "宣告 $declared，實際 $actual（cx scan dast 之後沒還原？）"
    fi

    # 只有 On 才擋得下來。DetectionOnly 之下這兩項沒有意義，誠實地 SKIP。
    local base="http://127.0.0.1:$port" code
    if [[ $actual != On ]]; then
        _vf SKIP "waf-block" "攻擊特徵請求被擋成 403" "引擎是 $actual，不是 On"
        _vf SKIP "waf-livewire" "Livewire 的正常請求不被誤擋" "引擎是 $actual，不是 On"
        return 0
    fi

    # 一律明寫 Host。用 http://127.0.0.1:<埠> 探測時 curl 會把 Host 設成
    # 數字 IP，而 CRS 的 920350「Host header is a numeric IP address」會因此
    # 加分 —— 那是探測方式造成的，真實瀏覽器不會這樣送。
    # 少了這一行，waf-livewire 會因為一條與 Livewire 無關的規則而永遠 FAIL。
    local -a hosthdr=(-H "Host: ${CX_WAF_HOST:-localhost}")
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "${hosthdr[@]}" \
           "$base/?q=%3Cscript%3Ealert(1)%3C/script%3E" 2>/dev/null)
    if [[ $code == 403 ]]; then
        _vf PASS "waf-block" "攻擊特徵請求被擋成 403"
    else
        _vf FAIL "waf-block" "攻擊特徵請求被擋成 403" "實際回 ${code:-無回應}"
    fi

    # Livewire 的前綴由 APP_KEY 推導，現場從後台登入頁撈 —— 絕不可以寫死。
    local lw edge_port body c_waf c_edge
    lw=$(curl -s -m 15 "${hosthdr[@]}" "$base/admin/login" 2>/dev/null \
         | grep -o '/livewire-[0-9a-zA-Z]\{6,\}' | head -1)
    if [[ -z $lw ]]; then
        _vf SKIP "waf-livewire" "Livewire 的正常請求不被誤擋" "抓不到端點前綴"
        return 0
    fi
    edge_port=$(grep -E '^EDGE_HTTP_PORT=' "$CX_ROOT/docker/env/test.env" 2>/dev/null | cut -d= -f2)
    edge_port=${edge_port:-18080}
    # body 要用「排除規則正是為了放行它才存在」的內容 —— 太溫和的字串
    # 在 PL1 之下本來就不會觸發 CRS，那樣的檢查會永遠通過，等於沒驗。
    #
    # 2026-09-05 實測（舊規則、引擎 On、經 18081 對照 18080）：
    #   "x <b>y</b> or 1=1 -- select"    → waf 419 / edge 419（測不到東西）
    #   "<script>alert(1)</script>"      → waf 403 / edge 419 ← 抓得到
    #   "1 UNION SELECT NULL FROM users" → waf 403 / edge 419 ← 抓得到
    # 前者是富文字欄位貼上 HTML，後者是表格篩選器打了一句話 —— 兩個都是
    # 後台的日常操作，也正是 10011 移除 941/942 那幾條規則的理由。
    body='{"components": [{"snapshot": "{\"data\": {\"bio\": \"<script>alert(1)</script>\", \"q\": \"1 UNION SELECT NULL FROM users\"}}", "updates": {}, "calls": []}]}'
    c_waf=$(curl -s -o /dev/null -w '%{http_code}' -m 15 -X POST "${hosthdr[@]}" \
            -H 'Content-Type: application/json' -H 'X-Livewire: 1' \
            --data "$body" "$base$lw/update" 2>/dev/null)
    c_edge=$(curl -s -o /dev/null -w '%{http_code}' -m 15 -X POST "${hosthdr[@]}" \
            -H 'Content-Type: application/json' -H 'X-Livewire: 1' \
            --data "$body" "http://127.0.0.1:$edge_port$lw/update" 2>/dev/null)
    if [[ $c_waf == "$c_edge" ]]; then
        _vf PASS "waf-livewire" "Livewire 的正常請求不被誤擋" "經 WAF 與直連 edge 都是 $c_waf"
    else
        _vf FAIL "waf-livewire" "Livewire 的正常請求不被誤擋" \
            "經 WAF $c_waf、直連 edge $c_edge（排除規則沒命中 $lw）"
    fi
}

# ── acl ────────────────────────────────────────────────────────────────────
_verify_acl() {
    cx_step "檔案權限（POSIX ACL）"
    if ! cx_have setfacl || ! cx_have getfacl; then
        _vf SKIP "acl-tools" "setfacl / getfacl 可用" "cx setup system acl"
        return 0
    fi
    _vf PASS "acl-tools" "setfacl / getfacl 可用"

    # 檔案系統支不支援 ACL。noacl 掛載的錯誤是 "Operation not supported"，
    # 看起來完全不像掛載問題，所以先探測再說。
    local probe rc=0
    probe=$(mktemp -d "$CX_ROOT/.cx-acl-probe.XXXXXX" 2>/dev/null) || probe=''
    if [[ -n $probe ]]; then
        setfacl -m u:"$(id -u)":rwx "$probe" 2>/dev/null || rc=$?
        rm -rf "$probe"
        if (( rc )); then
            _vf FAIL "acl-fs" "檔案系統支援 ACL" "setfacl 失敗（noacl 掛載？findmnt -T .）"
            return 0
        fi
        _vf PASS "acl-fs" "檔案系統支援 ACL"
    fi

    # shellcheck source=/dev/null
    . "$CX_ROOT/bin/cmd/acl.sh"
    if ( _acl_check ) >/dev/null 2>&1; then
        _vf PASS "acl-model" "cx acl check 通過"
    else
        _vf SKIP "acl-model" "cx acl check 通過" "尚未套用（cx acl apply）—— ACL 是選用的"
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
    local report=''
    while (( $# )); do
        case $1 in
            -h|--help|help) _verify_usage; return 0 ;;
            --report) report=$(cx_resolve "${2:?--report 需要路徑}"); shift 2 ;;
            --report=*) report=$(cx_resolve "${1#*=}"); shift ;;
            --quiet) _VF_QUIET=1; shift ;;
            static|runtime|ansible|app|cli|docs|tui|waf|acl|all) scopes+=("$1"); shift ;;
            *) cx_error "未知的範圍：$1"; _verify_usage; return "$EX_USAGE" ;;
        esac
    done
    (( ${#scopes[@]} )) || scopes=(cli docs tui static app ansible)

    local s
    for s in "${scopes[@]}"; do
        [[ $s == all ]] && { scopes=(cli docs tui static runtime app waf acl ansible); break; }
    done

    # 清掉上一次的設定快取，確保這次讀到的是現在的 compose 檔。
    rm -f "$CX_ROOT/.cx/verify-config-"*.json 2>/dev/null || true

    for s in "${scopes[@]}"; do
        case $s in
            cli)     _verify_meta cli "cx 自身一致性" ;;
            docs)    _verify_meta docs "文件與實作一致性" ;;
            tui)     _verify_meta tui "TUI 選單可達性" ;;
            static)  _verify_static ;;
            ansible) _verify_ansible ;;
            waf)     cx_docker_need; _verify_waf ;;
            acl)     _verify_acl ;;
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
