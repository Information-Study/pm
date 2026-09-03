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
用法：cx scan <防線> [--runner docker|native|auto] [--fail-on-findings]

  code    ① Quality  Larastan + SonarQube scanner
  sast    ② SAST     Semgrep
  sca     ③ SCA      Trivy（fs/secret/misconfig）+ composer audit + npm audit
  dast    ④ DAST     OWASP ZAP（僅 docker runner）
  secrets    gitleaks 全歷史祕密掃描
  all        依序執行 ①②③④

結束碼
  0   全部通過
  20  ① Quality 有問題      22  ③ SCA 有問題
  21  ② SAST 有問題         23  ④ DAST 有問題
  3   前置條件不足（工具缺失／Docker 不可用）
TXT
}

# ---------------------------------------------------------------------------
# 報告與快取目錄：一律由呼叫者身分預先建立
# ---------------------------------------------------------------------------
_scan_ensure_dirs() {
    local d
    for d in quality sast sca dast/detect dast/blocking dast/compare waf; do
        mkdir -p "$CX_REPORT_DIR/$d"
    done
    for d in trivy semgrep phpstan; do
        mkdir -p "$CX_CACHE_DIR/$d"
    done
    [[ -O $CX_REPORT_DIR ]] || cx_warn "reports/ 擁有者不是 $(id -un) —— 掃描器可能寫不進去"
}

_scan_runner() {
    case ${CX_RUNNER:-auto} in
        docker) printf 'docker\n' ;;
        native) printf 'native\n' ;;
        *)      cx_docker_ok && printf 'docker\n' || printf 'native\n' ;;
    esac
}

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
            local n; n=$(python3 -c 'import json,sys;print(json.load(sys.stdin).get("errors","?"))' \
                         < "$CX_REPORT_DIR/quality/larastan.json" 2>/dev/null || echo '?')
            cx_dim "報告：reports/quality/larastan.json（errors=$n）"
        fi
    else
        cx_warn "Larastan 未安裝（backend/vendor/bin/phpstan 不存在）"
    fi

    # SonarQube scanner 需要一台 SonarQube server，只有 docker runner 有
    if [[ $(_scan_runner) == docker ]]; then
        if docker network inspect pm_devsecops_net >/dev/null 2>&1; then
            cx_info "SonarQube scanner …"
            cx_run docker run --rm -u "$(id -u):$(id -g)" \
                --network pm_devsecops_net \
                -e SONAR_HOST_URL="${SONAR_HOST_URL:-http://sonarqube:9000}" \
                -e SONAR_TOKEN="${SONAR_TOKEN:?尚未設定 —— 跑 cx sonar up 之後再跑 cx sonar token}" \
                -v "$CX_ROOT:/usr/src" \
                "${CX_IMG_SONAR_SCANNER:-sonarsource/sonar-scanner-cli:latest}" || rc=$?
            # 這裡曾經寫 worst=$(...)。檔頭第 80-83 行的註解正在講這個坑，
            # 而這一行自己犯了：worst 不是本函式的 local，寫進去的是呼叫者的變數，
            # 但下面 return 的是 _lane_worst → SonarQube scanner 的失敗被靜默吞掉。
            _lane_worst=$(_scan_max "$_lane_worst" "$rc")
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
        _scan_step "$EX_SCAN_SCA" "Trivy fs（原生）" \
            env -C "$CX_ROOT" TRIVY_CACHE_DIR="$CX_CACHE_DIR/trivy" \
                trivy fs --scanners vuln,secret,misconfig --exit-code 1 \
                    --severity HIGH,CRITICAL \
                    --skip-dirs '**/vendor' --skip-dirs '**/node_modules' \
                    --skip-dirs '**/.nuxt' --skip-dirs '**/.output' \
                    --skip-dirs '**/storage/framework' --skip-dirs '**/bootstrap/cache' \
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
    if cx_have npm && [[ -f $CX_ROOT/frontend/package-lock.json ]]; then
        rc=0
        _scan_step "$EX_SCAN_SCA" "npm audit" \
            env -C "$CX_ROOT/frontend" npm audit --audit-level=high --json \
            > "$CX_REPORT_DIR/sca/npm-audit.json" || rc=$?
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
    local net=${CX_TEST_NETWORK:-pm_test_net}
    docker network inspect "$net" >/dev/null 2>&1 \
        || cx_die "$EX_PRECOND" "network $net 不存在 —— 先跑 cx test up -d"

    for mode in detect blocking; do
        cx_info "ZAP baseline（$mode）…"
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

    _scan_dast_probe "$net"
    cx_info "產生 WAF 攔截率對照 …"
    _scan_dast_compare
    return "$_lane_worst"
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

_scan_dast_compare() {
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
print(f"  DetectionOnly {len(det)} 項 → Blocking {len(blk)} 項，WAF 擋下 {len(blocked)} 項")
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
        slug=$(basename "$r")
        rc=0
        # gitleaks 8.30 起 `detect` 已被 `git` / `dir` 取代。
        # 用 `git` 掃「整個歷史」——祕密一旦進過 commit，改掉當前檔案是不夠的。
        _scan_step "$EX_SCAN_SCA" "gitleaks: $slug（含歷史）" \
            gitleaks git "$r" --no-banner --redact \
                --config "$CX_ROOT/docker/security/trivy/gitleaks.toml" \
                --report-format json \
                --report-path "$CX_REPORT_DIR/sca/gitleaks-$slug.json" || rc=$?
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
    CX_RUNNER=auto
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
