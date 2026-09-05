#!/usr/bin/env bash
# cx scan — DevSecOps 四道防線。
#
# 雙 runner：docker（優先）／ native（Docker 不可用時的降級）。
#
# 關鍵設計（皆來自對抗驗證的實際失敗路徑）：
#   1. 掃描器「找到東西」與「工具當掉」是不同的事。全部顯式捕捉 exit code
#      並映射到 EX_SCAN_*，絕不讓 ERR trap 把 finding 變成 stack dump。
#   2. 所有輸出／快取目錄由 cx 以呼叫者身分預先建立。掛在「image 中不存在的
#      路徑」上的具名 volume 一律被 Docker 建成 root:root 0755，
#      非 root 的掃描器（uid 1000）必定 EACCES。
#   3. 短暫容器不固定 --name。--rm 在 CLI 被 SIGKILL／daemon 重啟／OOM 時
#      不會執行，下一次就 Conflict。

CX_REPORT_DIR="${CX_REPORT_DIR:-$CX_ROOT/reports}"
CX_CACHE_DIR="${CX_CACHE_DIR:-$CX_ROOT/.cx/cache}"

_scan_usage() {
    cat >&2 <<'TXT'
用法：cx scan <防線> [--runner docker|native|auto]

  code    ① Quality  Larastan（level 5）+ SonarQube scanner
  sast    ② SAST     Semgrep
  sca     ③ SCA      Trivy（fs/secret/misconfig）+ composer audit + npm audit
  dast    ④ DAST     OWASP ZAP（僅 docker runner）
  secrets    gitleaks 全歷史祕密掃描
  all        ①②③④ 再加 secrets

  ⚠ all 不是「遇到第一個問題就停」：每一道都會跑完，最後回傳**最嚴重**的退出碼。
    掃描器的價值在於一次看到全部問題；停在第一道會讓後面三道永遠沒機會跑。

報告位置
  reports/quality/  larastan.json
  reports/sast/     semgrep.sarif
  reports/sca/      trivy-fs.json・composer-audit.json・npm-audit.json
  reports/secrets/  gitleaks-{pm,backend,frontend}.json
  reports/dast/     detect/ 與 blocking/ 各一份 report.{json,html}，compare/ 是對照

結束碼
  0   全部通過
  20  ① Quality 有問題      22  ③ SCA 有問題（secrets 也用這個碼）
  21  ② SAST 有問題         23  ④ DAST 有問題
  3   前置條件不足（工具缺失／Docker 不可用）—— 這是環境問題，不是掃描結果
TXT
}

# ---------------------------------------------------------------------------
# 報告與快取目錄：一律由呼叫者身分預先建立
# ---------------------------------------------------------------------------
_scan_ensure_dirs() {
    local d
    # secrets 曾經漏掉。gitleaks 的輸出從 sca/ 搬到 secrets/ 的時候只改了寫入路徑，
    # 沒有把目錄加進這張清單 —— 在乾淨的樹上（或 rm -rf reports 之後）
    # gitleaks 寫不出報告而 exit 1，_scan_step 把它判成「有 finding」，
    # 於是「目錄不存在」會顯示成「掃到祕密」，rc=22。
    for d in quality sast sca secrets dast/detect dast/blocking dast/compare waf; do
        mkdir -p "$CX_REPORT_DIR/$d"
    done
    for d in trivy semgrep phpstan; do
        mkdir -p "$CX_CACHE_DIR/$d"
    done
    [[ -O $CX_REPORT_DIR ]] || cx_warn "reports/ 擁有者不是 $(id -un) —— 掃描器可能寫不進去"
}

# 與 cx_runner 是同一件事，保留名字是因為本檔到處在用。
_scan_runner() { cx_runner; }

# _scan_step <EX_CODE> <名稱> <指令...>
# 回傳：0 = 乾淨，$EX_CODE = 有 finding，EX_PRECOND = 工具本身出錯
_scan_step() {
    local ex=$1 name=$2; shift 2
    local rc=0
    cx_info "$name …"
    "$@" || rc=$?
    case $rc in
        0)  cx_ok "$name：乾淨"; return 0 ;;
        1)  cx_warn "$name：有 finding"; return "$ex" ;;
        *)  cx_error "$name：工具異常結束（exit $rc）"; return "$EX_PRECOND" ;;
    esac
}

_scan_max() { local a=$1 b=$2; (( a > b )) && printf '%s\n' "$a" || printf '%s\n' "$b"; }

# npm audit 的輸出到底是「報告」還是「錯誤」。
# 只認 auditReportVersion / metadata / vulnerabilities —— 有其中之一才算掃成功。
# 從失敗的 npm audit 輸出裡挖出真正的原因。
# 沒有這個，使用者只會看到「失敗」，不知道是離線、proxy 還是 registry 掛了。
_scan_npm_audit_err() {
    python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("報告不是合法 JSON"); raise SystemExit
print(d.get("message") or "npm 沒有產生 audit 報告")
' "$1" 2>/dev/null || echo '讀不到報告'
}

_scan_npm_audit_is_report() {
    [[ -s $1 ]] || return 1
    python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(1)
ok = isinstance(d, dict) and any(
    k in d for k in ("auditReportVersion", "metadata", "vulnerabilities"))
raise SystemExit(0 if ok else 1)
' "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# ① Quality
# ---------------------------------------------------------------------------
_scan_code() {
    cx_step "① Quality — Larastan + SonarQube"
    # 累加器一律 lane 私有並明確 local。
    # 曾經寫成 `local runner; runner=$(...) worst=0 rc=0` —— 那是一個賦值串，
    # 只有 runner 是 local，worst/rc 在 bash 的動態作用域下會寫進呼叫者的變數，
    # 把 cmd_scan_main 累積的 worst 歸零，導致 cx scan all 回傳 0。
    local _lane_worst=0 rc=0

    if [[ -x $CX_ROOT/backend/vendor/bin/phpstan ]]; then
        _scan_step "$EX_SCAN_QUALITY" "Larastan" \
            env -C "$CX_ROOT/backend" ./vendor/bin/phpstan analyse \
                --memory-limit=1G --no-progress \
                --error-format=json > "$CX_REPORT_DIR/quality/larastan.json" || rc=$?
        _lane_worst=$(_scan_max "$_lane_worst" "$rc")
        if [[ -s $CX_REPORT_DIR/quality/larastan.json ]]; then
            # 這個檔要用兩層小心讀：
            #
            # ① 它是 JSONL 不是單一 JSON 物件。phpstan 有 note 要說的時候
            #    （例如「Note: Using configuration file …」）會先吐一行
            #    {"tool":…,"raw":[…]}，結果行才在後面。json.load(整個檔) 會
            #    JSONDecodeError，被 `|| echo '?'` 吞掉 —— errors= 永遠印成 ?。
            #
            # ② 結果物件長這樣：{"totals":{"errors":N,"file_errors":M},
            #    "files":{…},"errors":[…]}。頂層的 "errors" 是**通用錯誤的陣列**
            #    （設定檔問題之類），不是計數；檔案裡的問題數在 totals.file_errors。
            #    取 d["errors"] 的結果是印出 errors=[] —— 而且 100 個檔案錯誤時
            #    它**still** 印 []，看起來永遠乾淨。要的是 totals 的兩個數字相加。
            local n; n=$(python3 -c '
import json, sys
# 兩種格式都要吃：
#   * PHPStan --error-format=json 的標準輸出
#       {"totals":{"errors":N,"file_errors":M},"files":{...},"errors":[...]}
#     這裡頂層的 "errors" 是**通用錯誤的陣列**（設定檔問題之類）不是計數，
#     檔案裡的問題數在 totals.file_errors —— 取錯欄位會永遠印 []。
#   * 某些包裝層會改寫成扁平的 {"result":"failed","errors":N}
#     這時 "errors" 就是整數計數。
# 只認一種的話，另一種環境會靜靜印出 "?" 或永遠的 "[]"，兩種都是假的乾淨。
# 檔案本身是 JSONL：phpstan 有 note 要說的時候會先吐一行，所以逐行讀。
n = "?"
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if not isinstance(d, dict):
        continue
    t = d.get("totals")
    if isinstance(t, dict):
        n = int(t.get("file_errors", 0)) + int(t.get("errors", 0))
    elif isinstance(d.get("errors"), int):
        n = d["errors"]
print(n)
' < "$CX_REPORT_DIR/quality/larastan.json" 2>/dev/null || echo '?')
            cx_dim "報告：reports/quality/larastan.json（errors=$n）"
        fi
    else
        cx_warn "Larastan 未安裝（backend/vendor/bin/phpstan 不存在）"
    fi

    # SonarQube scanner 需要一台 SonarQube server，只有 docker runner 有
    if [[ $(_scan_runner) == docker ]]; then
        if docker network inspect "$(cx_sonar_net)" >/dev/null 2>&1; then
            # ⚠ 這裡原本是 -e SONAR_TOKEN="${SONAR_TOKEN:?…}"。
            #
            # ${var:?} 在非互動 shell 是「立刻結束整個 shell」，不是回傳非零 ——
            # cx 的 `"$fn" "$@" || _rc=$?` 攔不住它（實測：② ③ ④ 與總結全部不執行，
            # 連已經產生的 reports/quality/larastan.json 都不會被總結）。
            # 也就是說「沒設 token」會讓整條 cx scan all 在第 ① 道防線就無聲死掉。
            #
            # 另外，cx sonar token 會把 token 寫進 .cx/sonar-token 並告訴你
            # 「cx scan code 會自動讀它」—— 但在 2026-09-04 之前沒有任何地方讀回來。
            # 這裡補上，並把「沒有 token」降級成「略過 scanner 並警告」。
            local sonar_token="${SONAR_TOKEN:-}"
            if [[ -z $sonar_token && -r $CX_ROOT/.cx/sonar-token ]]; then
                sonar_token=$(< "$CX_ROOT/.cx/sonar-token")
                sonar_token=${sonar_token//[$'\n\r']/}
            fi
            if [[ -z $sonar_token ]]; then
                cx_warn "沒有 SONAR_TOKEN —— 略過 SonarQube scanner（Larastan 已完成）"
                cx_dim "  產生：cx sonar token（會寫進 .cx/sonar-token，之後自動讀取）"
                cx_dim "  或自行 export SONAR_TOKEN=…"
            else
                cx_info "SonarQube scanner …"
                rc=0
                cx_run docker run --rm -u "$(id -u):$(id -g)" \
                    --network "$(cx_sonar_net)" \
                    -e SONAR_HOST_URL="${SONAR_HOST_URL:-http://sonarqube:9000}" \
                    -e SONAR_TOKEN="$sonar_token" \
                    -v "$CX_ROOT:/usr/src" \
                    "${CX_IMG_SONAR_SCANNER:-sonarsource/sonar-scanner-cli:latest}" || rc=$?
                # 這裡曾經寫 worst=$(...)。檔頭的註解正在講這個坑，而這一行自己犯了：
                # worst 不是本函式的 local，寫進去的是呼叫者的變數，
                # 但下面 return 的是 _lane_worst → scanner 的失敗被靜默吞掉。
                _lane_worst=$(_scan_max "$_lane_worst" "$rc")
            fi
        else
            cx_warn "SonarQube 未啟動（cx sonar up）—— 略過 scanner"
        fi
    else
        cx_warn "native runner 無法執行 SonarQube scanner（需要 SonarQube server）"
    fi
    return "$_lane_worst"
}

# ---------------------------------------------------------------------------
# ② SAST — Semgrep
# ---------------------------------------------------------------------------
_scan_sast() {
    cx_step "② SAST — Semgrep"
    local runner; runner=$(_scan_runner)
    local -a cfg=()
    local line
    while read -r line; do
        [[ $line =~ ^[[:space:]]*# || -z ${line// } ]] && continue
        cfg+=(--config "$line")
    done < "$CX_ROOT/docker/security/semgrep/rulesets.txt"

    local sarif="$CX_REPORT_DIR/sast/semgrep.sarif" rc=0

    # 刻意不加 --error。
    # claude.md §5 的閘門是「無 ERROR 等級 finding」，而 --error 是
    # 「有任何 finding 就 exit 1」，包含 warning ——
    # 用它當閘門的結果是這條 lane 永遠紅燈，於是沒有人會再看它。
    # 改成先產生完整 SARIF，再由 bin/lib/sarif_gate.py 依嚴重度判定。
    if [[ $runner == docker ]]; then
        cx_info "Semgrep（docker）…"
        cx_run docker run --rm -u "$(id -u):$(id -g)" \
            -e HOME=/semgrep-home \
            -e SEMGREP_SEND_METRICS=off \
            -v "$CX_CACHE_DIR/semgrep:/semgrep-home" \
            -v "$CX_ROOT:/src:ro" \
            -v "$CX_REPORT_DIR:/out" \
            -w /src \
            "${CX_IMG_SEMGREP:-semgrep/semgrep:latest}" \
            semgrep scan "${cfg[@]}" --sarif --output /out/sast/semgrep.sarif || rc=$?
    elif cx_have semgrep; then
        cx_info "Semgrep（原生）…"
        cx_run env -C "$CX_ROOT" semgrep scan "${cfg[@]}" \
            --sarif --output "$sarif" || rc=$?
    else
        cx_warn "Semgrep 不可用（需要 Docker，或 cx setup tools semgrep）"
        return "$EX_PRECOND"
    fi

    # Semgrep 對「規則集下載失敗」回 exit 7，而且在 --output 之下
    # 連錯誤訊息都不會出現在終端機（stdout 全被導進 sarif 檔）。
    # 2026-09-04 實測：p/laravel 與 p/vue 都已經是 HTTP 404。
    if (( rc >= 2 )); then
        cx_error "Semgrep 工具異常結束（exit $rc）"
        cx_dim "  最常見原因：rulesets.txt 裡有 registry 上不存在的規則集（exit 7）"
        cx_dim "  逐一驗證：docker run --rm semgrep/semgrep semgrep scan --config p/<名稱> --metrics=off <檔案>"
        return "$EX_PRECOND"
    fi

    [[ -f $sarif ]] || { cx_error "Semgrep 沒有產生 $sarif"; return "$EX_PRECOND"; }
    cx_dim "報告：reports/sast/semgrep.sarif"

    if python3 "$CX_ROOT/bin/lib/sarif_gate.py" "$sarif"; then
        cx_ok "Semgrep：無 ERROR 等級 finding"
        return 0
    fi
    cx_error "Semgrep：有 ERROR 等級 finding"
    return "$EX_SCAN_SAST"
}

# ---------------------------------------------------------------------------
# ③ SCA — Trivy + composer audit + npm audit
# ---------------------------------------------------------------------------
_scan_sca() {
    cx_step "③ SCA — Trivy + 套件管理器 audit"
    local runner _lane_worst=0 rc=0
    runner=$(_scan_runner)

    if [[ $runner == docker ]]; then
        _scan_step "$EX_SCAN_SCA" "Trivy fs" \
            docker run --rm -u "$(id -u):$(id -g)" \
                -e TRIVY_CACHE_DIR=/tmp/trivy \
                -v "$CX_CACHE_DIR/trivy:/tmp/trivy" \
                -v "$CX_ROOT:/workspace:ro" \
                -v "$CX_REPORT_DIR:/out" \
                -w /workspace \
                "${CX_IMG_TRIVY:-aquasec/trivy:latest}" \
                fs --config /workspace/docker/security/trivy/trivy.yaml \
                   --scanners vuln,secret,misconfig --exit-code 1 \
                   --format json --output /out/sca/trivy-fs.json . || rc=$?
        _lane_worst=$(_scan_max "$_lane_worst" "$rc")
    elif cx_have trivy; then
        rc=0
        # 原生路徑一定要載入同一份 trivy.yaml。手抄一組旗標的後果是兩條 runner
        # 的閘門悄悄變成兩套：原生這邊漏掉 ignorefile（於是有到期日的例外不生效，
        # 掃出來的 HIGH/CRITICAL 比 docker 多）、漏掉 secret.config、
        # 也漏掉 ansible/collections 與 .git 的 skip-dirs（於是回報一堆上游
        # collection 測試夾具裡的問題）。--runner 的用意是「兩條路都能獨立跑完
        # 同一件事」，不是「兩條路做不同的事」。
        #
        # trivy.yaml 裡的路徑是容器內絕對路徑（/workspace/...），原生跑不到，
        # 所以用 CLI 旗標覆寫那兩個 —— Trivy 的 CLI 優先於設定檔。
        _scan_step "$EX_SCAN_SCA" "Trivy fs（原生）" \
            env -C "$CX_ROOT" TRIVY_CACHE_DIR="$CX_CACHE_DIR/trivy" \
                trivy fs --config "$CX_ROOT/docker/security/trivy/trivy.yaml" \
                    --secret-config "$CX_ROOT/docker/security/trivy/secret.yaml" \
                    --ignorefile "$CX_ROOT/docker/security/trivy/.trivyignore.yaml" \
                    --scanners vuln,secret,misconfig --exit-code 1 \
                    --format json --output "$CX_REPORT_DIR/sca/trivy-fs.json" . || rc=$?
        _lane_worst=$(_scan_max "$_lane_worst" "$rc")
    else
        cx_warn "Trivy 不可用"
        _lane_worst=$(_scan_max "$_lane_worst" "$EX_PRECOND")
    fi

    # composer audit（原生可用）
    if cx_have composer && [[ -f $CX_ROOT/backend/composer.lock ]]; then
        rc=0
        _scan_step "$EX_SCAN_SCA" "composer audit" \
            env -C "$CX_ROOT/backend" composer audit --no-interaction --format=json \
            > "$CX_REPORT_DIR/sca/composer-audit.json" || rc=$?
        _lane_worst=$(_scan_max "$_lane_worst" "$rc")
    fi

    # npm audit（原生可用）
    #
    # ⚠ npm audit 的 exit 1 有兩種完全不同的意思：
    #     a) 真的找到漏洞
    #     b) 連不到 registry（網路逾時、離線、proxy 擋掉）
    #   實測 b 的輸出是 {"message":"network timeout at: …","error":{…}}，
    #   而 _scan_step 只看退出碼，於是把「掃不成」報成「有 finding」，
    #   CI 拿到的是 22（SCA 有問題）而不是 3（環境問題）——
    #   一個網路抖動就會變成一份假的資安報告。
    #   成功的報告一定有 auditReportVersion / metadata；錯誤的只有 message+error。
    if cx_have npm && [[ -f $CX_ROOT/frontend/package-lock.json ]]; then
        # 這裡不能用 _scan_step —— 它只看退出碼就先印結論了，
        # 於是網路失敗的時候畫面會先出現「⚠ 有 finding」再出現
        # 「✘ 沒跑成」，兩句互相矛盾。判斷必須在印出結論之前做完。
        local nrc=0 nout="$CX_REPORT_DIR/sca/npm-audit.json"
        cx_info "npm audit …"
        env -C "$CX_ROOT/frontend" npm audit --audit-level=high --json \
            > "$nout" 2>/dev/null || nrc=$?
        if (( nrc == 0 )); then
            cx_ok "npm audit：乾淨"
        elif _scan_npm_audit_is_report "$nout"; then
            cx_warn "npm audit：有 finding"
            rc=$EX_SCAN_SCA
        else
            cx_error "npm audit 沒跑成，不是掃出問題：$(_scan_npm_audit_err "$nout")"
            cx_dim "  這是環境問題（退出碼 $EX_PRECOND），不是 SCA finding"
            rc=$EX_PRECOND
        fi
        _lane_worst=$(_scan_max "$_lane_worst" "$rc")
    fi

    return "$_lane_worst"
}

# ---------------------------------------------------------------------------
# ④ DAST — ZAP（僅 docker）
# ---------------------------------------------------------------------------
_scan_dast() {
    cx_step "④ DAST — OWASP ZAP"
    local mode rc=0 _lane_worst=0
    if [[ $(_scan_runner) != docker ]]; then
        cx_warn "ZAP 需要 Docker（本機沒有 Java runtime）"
        cx_dim "  詳見 docker/security/zap/README.md"
        return "$EX_PRECOND"
    fi
    local target=${ZAP_TARGET:-http://waf:8080}
    local net=${CX_TEST_NETWORK:-$(cx_project)_test_net}
    docker network inspect "$net" >/dev/null 2>&1 \
        || cx_die "$EX_PRECOND" "network $net 不存在 —— 先跑 cx test up -d"

    for mode in detect blocking; do
        # C10：這個迴圈以前只是換輸出目錄，從來沒有真的動過引擎 ——
        # 兩份報告是同一個 WAF 狀態下跑出來的，而 docker/security/zap/README.md
        # 卻描述成「DetectionOnly 與 On 各跑一次」。名字說了一件事，行為做的是另一件。
        local engine
        case $mode in
            detect)   engine=DetectionOnly ;;
            blocking) engine=On ;;
        esac
        _scan_waf_engine "$engine" || {
            cx_warn "無法把 WAF 切到 $engine，略過 $mode 這一輪"
            continue
        }
        cx_info "ZAP baseline（$mode・MODSEC_RULE_ENGINE=$engine）…"
        rc=0
        cx_run docker run --rm -u "$(id -u):$(id -g)" \
            --network "$net" \
            -v "$CX_REPORT_DIR/dast/$mode:/zap/wrk:rw" \
            -v "$CX_ROOT/docker/security/zap:/zap/pmconf:ro" \
            "${CX_IMG_ZAP:-ghcr.io/zaproxy/zaproxy:stable}" \
            zap-baseline.py -t "$target" \
                -c /zap/pmconf/baseline.conf \
                -J report.json -r report.html || rc=$?

        # zap-baseline.py 的退出碼慣例（不是一般的 0/1）：
        #   0  全部通過
        #   1  至少一個 FAIL（也就是有 High risk alert）
        #   2  只有 WARN，沒有 FAIL
        #   3+ 工具本身出錯
        #
        # claude.md §5 的閘門是「無 High risk alert」，所以 2 是**通過**。
        # 原本寫成 `rc > 1 → EX_PRECOND`，於是只要有任何 warning 就被誤報成
        # 「前置條件不足／工具不可用」—— 實測 8 個 warning 就觸發了這個誤判。
        case $rc in
            0) cx_ok "ZAP $mode：無 alert" ;;
            1) cx_error "ZAP $mode：有 High risk alert"
               _lane_worst=$(_scan_max "$_lane_worst" "$EX_SCAN_DAST") ;;
            2) cx_warn "ZAP $mode：只有 warning（依 §5 的閘門定義算通過）"
               cx_dim "  細節：reports/dast/$mode/report.html" ;;
            *) cx_error "ZAP $mode：工具異常結束（exit $rc）"
               _lane_worst=$(_scan_max "$_lane_worst" "$EX_PRECOND") ;;
        esac
    done

    # 順序有意義：主動探測是**攔截率的真實量測**，先跑先印。
    # 被動 baseline 的 alert 差異放後面，而且不能叫「攔截率」。
    _scan_dast_probe "$net"
    _scan_dast_compare
    # 探測那支自己也會還原，這裡再做一次是為了「ZAP 跑完但探測被略過」那條路徑。
    _scan_waf_engine "$(_scan_waf_engine_declared)" \
        || cx_warn "無法還原 WAF 引擎 —— 請手動 cx test up -d waf"
    return "$_lane_worst"
}

# ── WAF 引擎切換 ───────────────────────────────────────────────────────────
# 切換一定要成對出現：切過去、用完切回宣告值。少了還原這一半，
# cx scan dast 跑完就把 test 堆疊留在 On，而 docker/env/test.env 宣告的是
# DetectionOnly —— 環境與版控說的不一樣，而且不會有任何地方提醒你。
# 這個漂移在 2026-09-05 的實機檢查中確認過真的發生了。
_scan_waf_engine_declared() {
    local v
    v=$(grep -E '^MODSEC_RULE_ENGINE=' "$CX_ROOT/docker/env/test.env" 2>/dev/null \
        | tail -1 | cut -d= -f2-)
    printf '%s' "${v:-DetectionOnly}"
}

_scan_waf_engine() {
    local engine=$1 rc=0
    # 用 test 模式的合併設定重建 waf 這一個 service。--wait 確保 healthy 之後才回來，
    # 否則下一步的 ZAP 會打在還沒載入新規則的 nginx 上。
    ( export MODSEC_RULE_ENGINE="$engine"
      CX_MODE=test cx_compose_init test
      cx_dc up -d --wait waf ) >/dev/null 2>&1 || rc=$?
    return "$rc"
}

# ── 主動攻擊探測 ───────────────────────────────────────────────────────────
# zap-baseline.py 是**被動**掃描：它爬站並檢查回應標頭，不送攻擊 payload。
# 所以拿 DetectionOnly 與 Blocking 兩份 baseline 報告去比對，兩邊必然一樣，
# 結論永遠是「WAF 擋下 0 項」—— 那個數字不是 WAF 沒用，是量錯了東西。
#
# 要量 WAF 的實際攔截率，必須真的送攻擊請求，並比較兩個引擎模式下的狀態碼。
# 這裡送一組已知會被 CRS 命中的 payload，外加一組正常請求當對照組
#（正常請求被擋才是真正的問題 —— 那代表排除規則沒生效）。
_scan_dast_probe() {
    local net=$1
    local out="$CX_REPORT_DIR/dast/compare/waf-probe.json"
    cx_ensure_host_dirs "$CX_REPORT_DIR/dast/compare"
    cx_info "主動攻擊探測（WAF 攔截率的真實量測）…"
    CX_ROOT="$CX_ROOT" CX_NET="$net" \
        python3 "$CX_ROOT/bin/lib/waf_probe.py" "$out" || return 0
}

# 被動 baseline 的 alert 差異。
# 這個數字**不是** WAF 攔截率 —— 見 _scan_dast_probe 上面那段說明。
# 保留它是因為「Blocking 模式下多出來的 alert」仍然有意義
#（代表 WAF 自己引入了新的回應標頭問題），但標題必須誠實，
# 否則它會跟主動探測的 100% 在同一畫面上互相打臉。
_scan_dast_compare() {
    cx_info "被動掃描 alert 對照（非攔截率）…"
    local d="$CX_REPORT_DIR/dast"
    [[ -f $d/detect/report.json && -f $d/blocking/report.json ]] || {
        cx_warn "缺少其中一份報告，無法比對"; return 0; }
    python3 - "$d" <<'PY'
import json, sys, pathlib
d = pathlib.Path(sys.argv[1])
def alerts(p):
    try: j = json.loads((d / p / 'report.json').read_text())
    except Exception: return {}
    out = {}
    for site in j.get('site', []):
        for a in site.get('alerts', []):
            out[(a.get('pluginid'), a.get('alert'))] = a.get('riskdesc', '')
    return out
det, blk = alerts('detect'), alerts('blocking')
blocked = sorted(set(det) - set(blk))
leaked  = sorted(set(blk))
(d / 'compare').mkdir(parents=True, exist_ok=True)
(d / 'compare' / 'waf-effectiveness.json').write_text(json.dumps({
    'detection_only_alerts': len(det),
    'blocking_alerts': len(blk),
    'blocked_by_waf': [{'pluginid': p, 'alert': a} for p, a in blocked],
    'still_reachable': [{'pluginid': p, 'alert': a} for p, a in leaked],
}, ensure_ascii=False, indent=2))
print(f"  被動 alert：DetectionOnly {len(det)} 項 → Blocking {len(blk)} 項"
      f"（差 {len(blocked)} 項）")
print("  ※ 這不是攔截率。zap-baseline 是被動掃描，不送攻擊 payload，")
print("    兩個模式看到的回應標頭本來就一樣，差值恆為 0 也是正常的。")
print("    真正的攔截率看上面那行「主動攻擊探測」。")
PY
}

# ---------------------------------------------------------------------------
# gitleaks — 全歷史祕密掃描
# ---------------------------------------------------------------------------
_scan_secrets() {
    cx_step "祕密掃描 — gitleaks（含 git 歷史）"
    cx_have gitleaks || { cx_warn "gitleaks 未安裝"; return "$EX_PRECOND"; }
    local r _lane_worst=0 rc=0 slug
    for r in "$CX_ROOT/backend" "$CX_ROOT/frontend" "$CX_ROOT"; do
        # 主庫的 slug 要用專案名，不能用 basename —— 目錄名不見得叫 pm
        # （worktree、別人 clone 時改的名字、範本化之後的新專案都不叫 pm），
        # 於是報告會變成 gitleaks-<隨便什麼目錄名>.json，與 usage 和
        # docs/reports.md 講的 gitleaks-{pm,backend,frontend}.json 對不上，
        # 下游想撿檔案的人只會拿到「找不到」。
        if [[ $r == "$CX_ROOT" ]]; then slug=$(cx_project); else slug=$(basename "$r"); fi
        rc=0
        # gitleaks 8.30 起 `detect` 已被 `git` / `dir` 取代。
        # 用 `git` 掃「整個歷史」——祕密一旦進過 commit，改掉當前檔案是不夠的。
        local out="$CX_REPORT_DIR/secrets/gitleaks-$slug.json"
        rm -f "$out"
        cx_info "gitleaks: $slug（含歷史）…"
        gitleaks git "$r" --no-banner --redact \
            --config "$CX_ROOT/docker/security/trivy/gitleaks.toml" \
            --report-format json \
            --report-path "$out" || rc=$?
        # ⚠ 不能只看退出碼。gitleaks 的 exit 1 同時代表「找到祕密」與
        #   「跑不起來」（最常見的是報告目錄不存在 → Report path is not writable）。
        #   實測把 reports/secrets/ 移走之後跑 cx scan secrets：
        #   三個 repo 全部顯示「有 finding」、rc=22 —— 也就是把
        #   「寫不出報告」報成「掃到祕密」。在最不能誤報的這一道上尤其不能接受。
        #   跑成功一定會留下一份 JSON（乾淨時是 []）；沒有檔案就是工具出錯。
        if (( rc == 0 )); then
            cx_ok "gitleaks: $slug（含歷史）：乾淨"
        elif [[ -f $out ]]; then
            cx_warn "gitleaks: $slug（含歷史）：有 finding"
            rc=$EX_SCAN_SCA
        else
            cx_error "gitleaks: $slug 沒跑成，不是掃到東西 —— 沒有產生 $out"
            cx_dim "  這是環境問題（退出碼 $EX_PRECOND），不是祕密外洩"
            rc=$EX_PRECOND
        fi
        _lane_worst=$(_scan_max "$_lane_worst" "$rc")
    done
    # 這裡曾經 return "$worst" —— 那個變數在本函式裡不存在。
    # 直接跑 cx scan secrets 時 set -u 會炸；從 cx scan all 進來則回傳呼叫者的
    # 舊值，gitleaks 找到的東西被整個丟掉。
    return "$_lane_worst"
}

# ---------------------------------------------------------------------------
cmd_scan_main() {
    local lane=${1:-}; shift || true
    # 預設沿用全域的 --runner；cx scan 自己的 --runner 可以再覆寫（更靠近的贏）。
    CX_RUNNER=${CX_RUNNER:-auto}
    while (( $# )); do
        case $1 in
            --runner)   [[ -n ${2:-} ]] || cx_die "$EX_USAGE" "--runner 需要一個值"
                        CX_RUNNER=$2; shift 2 ;;
            --runner=*) CX_RUNNER=${1#*=}; shift ;;
            -h|--help)  _scan_usage; return 0 ;;
            *)          cx_die "$EX_USAGE" "未知參數：$1" ;;
        esac
    done
    [[ -n $lane ]] || { _scan_usage; return "$EX_USAGE"; }
    case $lane in
        code|sast|sca|dast|secrets|all) : ;;
        -h|--help) _scan_usage; return 0 ;;
        *) cx_die "$EX_USAGE" "未知防線：$lane（code|sast|sca|dast|secrets|all）" ;;
    esac
    case ${CX_RUNNER:-auto} in
        docker|native|auto) : ;;
        *) cx_die "$EX_USAGE" "--runner 只接受 docker|native|auto（收到 $CX_RUNNER）" ;;
    esac

    _scan_ensure_dirs
    cx_info "runner = $(_scan_runner)"

    local rc=0 worst=0
    case $lane in
        code)    _scan_code    || rc=$? ;;
        sast)    _scan_sast    || rc=$? ;;
        sca)     _scan_sca     || rc=$? ;;
        dast)    _scan_dast    || rc=$? ;;
        secrets) _scan_secrets || rc=$? ;;
        all)
            local l
            for l in code sast sca dast; do
                rc=0; "_scan_$l" || rc=$?
                worst=$(_scan_max "$worst" "$rc")
            done
            rc=0; _scan_secrets || rc=$?
            worst=$(_scan_max "$worst" "$rc")
            rc=$worst
            ;;
    esac

    cx_step "結果"
    case $rc in
        0)  cx_ok "全部通過" ;;
        "$EX_PRECOND") cx_warn "部分工具不可用（前置條件不足）" ;;
        *)  cx_warn "有 finding，報告在 reports/" ;;
    esac
    return "$rc"
}
