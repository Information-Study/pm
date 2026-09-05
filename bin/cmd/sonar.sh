#!/usr/bin/env bash
# cx sonar —— 常駐的 SonarQube stack（dev 與 test 共用）。
#
# 獨立的 compose project（<專案>_devsecops），因為它的生命週期跟三個模式無關：
# 你會希望它一直開著累積歷史趨勢，而不是每次 cx dev down 就跟著消失。
#
# 網路名明寫 <專案>_devsecops_net —— bin/cmd/scan.sh 用
# `docker run --network <專案>_devsecops_net` 把短暫的 sonar-scanner 容器加進來，
# 這樣它才解析得到 http://sonarqube:9000（傳 localhost 進容器指的是容器自己）。

# 前綴不可寫死 pm —— 見 bin/lib/common.sh 的 cx_project()。
# sonar.sh 是在 .cxroot 被 source 之後才載入的，所以這裡讀得到 CX_PROJECT_NAME。
CX_SONAR_PROJECT=$(cx_sonar_project)
CX_SONAR_NET=$(cx_sonar_net)

_sonar_usage() {
    cat >&2 <<'TXT'
cx sonar <子指令>

  up            啟動 SonarQube + PostgreSQL（等到 healthy 為止）
  down [-v]     停止（-v 連資料一起刪，會要求確認）
  status        容器狀態與 API 健康度
  logs [-f]     看 log
  token         產生／輪替分析用的 token，寫進 .cx/sonar-token
  url           印出網址
  wait          等到 API 回報 UP（CI 用）

第一次使用
  1. cx sonar up
  2. 開 http://localhost:9000（預設帳密 admin / admin，會要求改密碼）
  3. cx sonar token        產生分析 token
  4. cx scan code          Larastan + sonar-scanner

SonarQube 的 healthcheck 一定要用 curl，不能用 wget ——
該映像基於 eclipse-temurin:25-jdk-noble，只裝了 bash / curl / fonts-dejavu。
寫成 wget 會永遠 unhealthy，任何 condition: service_healthy 依賴都會死鎖。
TXT
}

_sonar_args() {
    CX_DC_ARGS=(--project-directory "$CX_ROOT" -p "$CX_SONAR_PROJECT"
                -f "$CX_ROOT/docker/compose/sonar.yml")
    # sonar 是獨立 project，只吃根目錄的 .env（沒有 docker/env/sonar.env）。
    # 這裡原本是一個只有一個元素的 for 迴圈 —— 多模式那條路留下來的殘骸。
    [[ -f $CX_ROOT/.env ]] && CX_DC_ARGS+=(--env-file "$CX_ROOT/.env")
    CX_DC_MODE=sonar
}

_sonar_port() {
    local p
    p=$(grep -E '^SONAR_PORT=' "$CX_ROOT/.env" 2>/dev/null | cut -d= -f2)
    printf '%s' "${p:-9000}"
}

_sonar_wait() {
    local i=0 port
    port=$(_sonar_port)
    cx_info "等待 SonarQube 啟動（首次啟動要跑 Elasticsearch 初始化，可能 2 分鐘）"
    until curl -fsS "http://127.0.0.1:${port}/api/system/status" 2>/dev/null | grep -q '"status":"UP"'; do
        i=$((i + 1))
        (( i >= 80 )) && { cx_error "等待逾時"; cx_dim "  看 log：cx sonar logs"; return "$EX_PRECOND"; }
        sleep 3
    done
    cx_ok "SonarQube UP → http://localhost:${port}"
}

_sonar_up() {
    cx_ensure_host_dirs "$CX_ROOT/.cx"
    cx_dc up -d "$@"
    _sonar_wait
}

_sonar_down() {
    local wipe=0 a
    for a in "$@"; do [[ $a == -v || $a == --volumes ]] && wipe=1; done
    if (( wipe )); then
        cx_confirm --danger "刪除 SonarQube 的資料" \
"這會移除 $CX_SONAR_PROJECT 的所有 volume：

  • sonar-db        —— PostgreSQL，含全部歷史分析結果與趨勢
  • sonar-data      —— Elasticsearch 索引
  • sonar-extensions—— 已安裝的外掛

歷史趨勢無法回復。只是想停掉的話用不帶 -v 的 cx sonar down。" || return "$EX_ABORT"
    fi
    cx_dc down "$@"
}

_sonar_token() {
    local port out
    port=$(_sonar_port)
    out="$CX_ROOT/.cx/sonar-token"
    cx_ensure_host_dirs "$CX_ROOT/.cx"

    cx_step "產生 SonarQube 分析 token"
    cx_dim "  SonarQube 不允許用預設密碼呼叫 API，第一次要先到網頁改密碼。"
    printf '  管理者帳號 [admin]: ' >&2
    local user pass name
    read -r user </dev/tty || return 1
    user=${user:-admin}
    printf '  密碼: ' >&2
    read -rs pass </dev/tty || return 1
    printf '\n' >&2
    name="cx-$(date -u +%Y%m%dT%H%M%SZ)"

    local resp
    resp=$(curl -fsS -u "$user:$pass" -X POST \
        "http://127.0.0.1:${port}/api/user_tokens/generate" \
        -d "name=$name" -d "type=GLOBAL_ANALYSIS_TOKEN" 2>&1) || {
        cx_error "產生 token 失敗"
        cx_dim "  $resp"
        return "$EX_FAIL"
    }
    local tok
    tok=$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))')
    [[ -n $tok ]] || { cx_error "回應裡沒有 token：$resp"; return "$EX_FAIL"; }

    umask 077
    printf '%s\n' "$tok" > "$out"
    chmod 600 "$out"
    cx_ok "token 已寫入 $out（0600，已被 .gitignore 排除）"
    cx_dim "  cx scan code 會自動讀它；也可以自己 export SONAR_TOKEN=\$(cat $out)"
}

_sonar_status() {
    local port
    port=$(_sonar_port)
    cx_dc ps
    cx_step "API"
    curl -fsS "http://127.0.0.1:${port}/api/system/status" 2>/dev/null \
        || cx_warn "API 沒有回應（尚未啟動或還在初始化）"
    printf '\n' >&2
    cx_step "網路"
    if docker network inspect "$CX_SONAR_NET" >/dev/null 2>&1; then
        cx_ok "$CX_SONAR_NET 存在（sonar-scanner 加得進來）"
    else
        cx_warn "$CX_SONAR_NET 不存在 —— cx scan code 會略過 scanner"
    fi
}

cmd_sonar_main() {
    local sub=${1:-status}
    [[ $# -gt 0 ]] && shift
    case $sub in
        -h|--help|help) _sonar_usage; return 0 ;;
        url) printf 'http://localhost:%s\n' "$(_sonar_port)"; return 0 ;;
    esac

    cx_docker_need
    [[ -f $CX_ROOT/docker/compose/sonar.yml ]] \
        || cx_die "$EX_PRECOND" "缺少 docker/compose/sonar.yml"
    _sonar_args

    case $sub in
        up)     cx_lock sonar; _sonar_up "$@" ;;
        down)   cx_lock sonar; _sonar_down "$@" ;;
        status) _sonar_status ;;
        logs)   cx_dc logs --tail=200 "$@" ;;
        token)  _sonar_token ;;
        wait)   _sonar_wait ;;
        *) cx_error "未知的子指令：$sub"; _sonar_usage; return "$EX_USAGE" ;;
    esac
}
