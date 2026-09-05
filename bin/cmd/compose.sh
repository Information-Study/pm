#!/usr/bin/env bash
# cx compose —— dev / test / prod 三模式的容器操作。
#
# 這個檔同時是八個動詞的實作（cx 的 CX_CMD_FILE_OF 把它們都指到這裡）：
#   cx up | down | restart | ps | logs | sh | build | dc
# 加上兩個模式前綴動詞：
#   cx dev <上面任一個> …    等於 cx --mode dev  <…>
#   cx prod <上面任一個> …   等於 cx --mode prod <…>
# （cx test 在 bin/cmd/test.sh，因為它同時要處理「跑測試套件」。）
#
# 一切都經過 cx_compose_init / cx_dc（bin/lib/common.sh），那裡處理掉
# claude.md §4 的四個陷阱：--project-directory、-p、條件式 --env-file、網路 name。
# **不要在這裡自己組 docker compose 指令。**

# 與 bin/lib/common.sh 的 CX_COMPOSE_VERBS_LIST 是同一份清單 —— test.sh 需要在
# source 本檔之前就能判斷 `cx test up` 的 up 是 compose 動作而不是測試套件名稱。
CX_COMPOSE_VERBS=${CX_COMPOSE_VERBS_LIST:-'up down restart ps logs sh build dc config'}

_compose_usage() {
    cat >&2 <<'TXT'
cx <模式> <動作> [參數...]      模式 = dev | test | prod（省略則用 --mode，預設 dev）

動作
  up [-d] [--build]     建立並啟動。會先確認 bind mount 來源都存在
  down [-v]             停止並移除容器。-v 連 volume 一起刪（會要求確認，資料會消失）
  restart [服務...]     重啟
  ps                    列出容器與埠
  logs [-f] [服務...]   看 log（預設 --tail=200）
  sh [服務]             進 shell（預設 app）
  build [--no-cache]    只建置映像，不啟動
  config                印出合併後的 compose 設定（除錯合併鏈用）
  dc <原生參數...>      直接把參數交給 docker compose（逃生門）

範例
  cx dev up -d --build          起開發環境
  cx test up -d                 起測試環境（含 ModSecurity WAF）
  cx prod up -d --build         起正式環境
  cx dev logs -f app            追 app 的 log
  cx --mode test sh waf         進 WAF 容器
  cx dev down -v                砍掉開發環境連資料庫（需確認）

三個模式可以同時運行：靠不同的 compose project（-p <專案>_dev|_test|_prod）
隔離容器／網路／volume，靠 env/docker/compose/<mode>.env 的不同埠段隔離 host 埠。
-p 不隔離 host 埠 —— 只做前者不做後者，第二個模式會 port is already allocated。
TXT
}

# reports/ 與快取的葉目錄要由呼叫者身分預先建立。
# 讓 Docker 自動建立的話會是 root:root 0755，之後非 root 的掃描器全部 EACCES。
_compose_prepare_dirs() {
    cx_ensure_host_dirs \
        "$CX_ROOT/reports/quality" \
        "$CX_ROOT/reports/sast" \
        "$CX_ROOT/reports/sca" \
        "$CX_ROOT/reports/dast/detect" \
        "$CX_ROOT/reports/dast/blocking" \
        "$CX_ROOT/reports/dast/compare" \
        "$CX_ROOT/reports/waf" \
        "$CX_ROOT/.cx/cache"

    # dev 模式把 ./src/backend 與 ./src/frontend bind mount 進容器，然後再用具名 volume
    # 蓋回 vendor / node_modules / .nuxt / .output。
    #
    # 具名 volume 掛在「bind mount 底下」時，Docker 會在容器內建立掛載點 ——
    # 而那個容器內路徑其實就是 host 上的目錄，於是 daemon 以 root:root 把它建出來。
    # 結果：非 root 的你既 npm ci 不進去、也刪不掉，而錯誤訊息只會說 EACCES。
    #
    # 先以呼叫者身分把它們建好，Docker 就會沿用既有目錄而不是自己建。
    if [[ ${CX_DC_MODE:-} == dev ]]; then
        cx_ensure_host_dirs \
            "$CX_ROOT/src/backend/vendor" \
            "$CX_ROOT/src/frontend/node_modules" \
            "$CX_ROOT/src/frontend/.nuxt" \
            "$CX_ROOT/src/frontend/.output"
        _compose_check_poisoned_volumes
    fi
    _compose_check_db_credentials
}

# 具名 volume 的另一個「訊息不指向原因」的坑。
#
# MySQL 的官方映像只在**資料目錄是空的**時候才會建立帳號。一旦
# <專案>_mysql-data 有內容，之後改 .env 的 DB_PASSWORD 完全不會生效 ——
# 容器照常起來、healthcheck 照常過，然後 app 的 entrypoint 在 migrate 那一步炸掉：
#     SQLSTATE[HY000] [1045] Access denied for user 'pm'@'…' (using password: YES)
# 而那句話不會告訴你「你的 .env 比資料庫還新」。
#
# 最常見的觸發：在同一台機器上換一個 checkout（worktree、另一份 clone）跑
# cx setup env —— 那會產生一組**新的**隨機密碼，但 volume 是共用的。
# 2026-09-05 實際踩到。
_compose_check_db_credentials() {
    cx_docker_ok || return 0
    local proj vol created env_mtime vol_epoch
    proj=$(cx_project_for "${CX_DC_MODE:-dev}")
    vol="${proj}_mysql-data"
    docker volume inspect "$vol" >/dev/null 2>&1 || return 0
    [[ -f $CX_ROOT/.env ]] || return 0

    created=$(docker volume inspect "$vol" --format '{{.CreatedAt}}' 2>/dev/null) || return 0
    vol_epoch=$(date -d "$created" +%s 2>/dev/null) || return 0
    env_mtime=$(stat -c %Y "$CX_ROOT/.env" 2>/dev/null) || return 0
    (( env_mtime > vol_epoch )) || return 0

    cx_warn ".env 比 $vol 新 —— 如果改過 DB_PASSWORD，資料庫並不知道"
    cx_dim "  MySQL 只在資料目錄是空的時候建帳號。既有 volume 用的還是舊密碼，"
    cx_dim "  症狀會是 app 的 entrypoint 在 migrate 炸掉：Access denied for user。"
    cx_dim "  兩條路（擇一）："
    cx_dim "    保留資料：把 .env 的 DB_PASSWORD／MYSQL_ROOT_PASSWORD 改回舊值"
    cx_dim "    丟掉資料：cx ${CX_DC_MODE:-dev} down -v   （會要求確認）"
}

# 上面那段只治「這一次」。已經被種成 root:root 的**具名 volume** 會留著，
# 而且重建映像救不回來 —— volume 只在第一次（空的時候）用映像的內容種子化。
#
# 症狀完全不指向 volume：
#     ERROR EACCES: permission denied, open '/app/.nuxt/nuxt.json'
# 於是人會去查 nuxt、查 bind mount、查 host 的權限，就是不會想到
# 「三天前某一次 up 留下來的 volume 內容是 root 的」。2026-09-05 實際踩到。
#
# 這裡只做偵測與指路，不自動刪 —— volume 裡可能有別人正在用的東西，
# 刪除一律要人自己決定。
_compose_check_poisoned_volumes() {
    cx_docker_ok || return 0
    local proj vol owner bad=()
    proj=$(cx_project_for "${CX_DC_MODE:-dev}")
    for vol in nuxt-build nuxt-output nuxt-node-modules app-vendor; do
        docker volume inspect "${proj}_${vol}" >/dev/null 2>&1 || continue
        # 用一次性容器去 stat —— host 上的 volume 路徑非 root 讀不到。
        owner=$(docker run --rm -v "${proj}_${vol}:/x:ro" \
                "${CX_IMG_ALPINE}" stat -c '%u' /x 2>/dev/null) || continue
        [[ $owner == 0 ]] && bad+=("${proj}_${vol}")
    done
    (( ${#bad[@]} )) || return 0
    cx_warn "下列具名 volume 的內容屬於 root，容器以非 root 身分跑會寫不進去："
    local v
    for v in "${bad[@]}"; do cx_dim "    $v"; done
    cx_dim "  症狀會長得像 nuxt 或 composer 的錯（EACCES），不會提到 volume。"
    cx_dim "  修正（會清掉快取，下次 up 會重新種子化）："
    cx_dim "    cx ${CX_DC_MODE:-dev} down && docker volume rm ${bad[*]}"
}

_compose_require_env() {
    [[ -f $CX_ROOT/.env ]] && return 0
    cx_error "缺少 $CX_ROOT/.env"
    cx_dim "  跑 cx setup 產生（會從 .env.example 複製並生成隨機密碼）"
    cx_dim "  這是硬失敗而不是警告：compose 的 MYSQL_ROOT_PASSWORD 是 :? 必填，"
    cx_dim "  少了它每一個 docker 動詞都會在做任何事之前就死掉。"
    exit "$EX_PRECOND"
}

_compose_up() {
    _compose_require_env
    _compose_prepare_dirs
    # bind mount 來源不存在時 Docker 會靜默建立 root:root 空目錄再掛上去，
    # 於是 CRS 排除規則從未載入、WAF 悄悄失效，而且沒有任何線索。
    cx_assert_mount_sources "$CX_DC_MODE"
    cx_info "啟動 $(cx_project_for "$CX_DC_MODE")（$(_compose_port_summary)）"
    cx_dc up "$@"
}

_compose_port_summary() {
    local f="$CX_ROOT/env/docker/compose/${CX_DC_MODE}.env"
    [[ -f $f ]] || { printf '埠段未知'; return; }
    local http nuxt db
    http=$(grep -E '^EDGE_HTTP_PORT=' "$f" | cut -d= -f2)
    nuxt=$(grep -E '^NUXT_PORT=' "$f" | cut -d= -f2)
    db=$(grep -E '^MYSQL_PORT=' "$f" | cut -d= -f2)
    printf 'edge:%s' "${http:-?}"
    [[ ${nuxt:-0} != 0 ]] && printf ' nuxt:%s' "$nuxt"
    [[ ${db:-0}   != 0 ]] && printf ' mysql:%s' "$db"
    if [[ $CX_DC_MODE == test ]]; then
        printf ' waf:%s' "$(grep -E '^WAF_HTTP_PORT=' "$f" | cut -d= -f2)"
    fi
}

_compose_down() {
    local wipe=0 a
    for a in "$@"; do
        [[ $a == -v || $a == --volumes ]] && wipe=1
    done
    if (( wipe )); then
        # 紅線 2：任何刪除必須有互動確認。-v 會刪掉 MySQL 的 volume，資料不可回復。
        cx_confirm --danger "刪除 $(cx_project_for "$CX_DC_MODE") 的 volume" \
"這會移除 compose project $(cx_project_for "$CX_DC_MODE") 的**所有 volume**，包含：

  • mysql-data   —— 資料庫的全部內容
  • app-storage / app-vendor / nuxt-* （若該模式有）

資料無法回復。要保留資料庫請改用不帶 -v 的 cx ${CX_DC_MODE} down。
若只是想重建 schema，用 cx db fresh。

確定要刪除？" || return "$EX_ABORT"
    fi
    cx_dc down "$@"
}

_compose_sh() {
    local svc=${1:-app}
    [[ $# -gt 0 ]] && shift
    # app 映像是 Alpine，沒有 bash。其他服務也一律用 sh。
    cx_dc exec "$svc" sh "$@"
}

_compose_logs() {
    local a has_tail=0
    for a in "$@"; do
        [[ $a == --tail* || $a == -n ]] && has_tail=1
    done
    if (( has_tail )); then
        cx_dc logs "$@"
    else
        cx_dc logs --tail=200 "$@"
    fi
}

cmd_compose_main() {
    local verb=${CX_VERB:-}
    local mode=''

    # dev / prod 是模式前綴：把第一個參數當成真正的動作。
    case $verb in
        dev|prod)
            mode=$verb
            verb=${1:-ps}
            [[ $# -gt 0 ]] && shift
            ;;
    esac

    case $verb in
        -h|--help|help) _compose_usage; return 0 ;;
    esac

    # 動作白名單。不驗證的話 `cx dev upp -d` 會被原封不動丟給 docker compose，
    # 錯誤訊息會是 compose 的，看不出是 cx 這一層打錯字。
    case " $CX_COMPOSE_VERBS " in
        *" $verb "*) : ;;
        *) cx_error "未知的動作：'$verb'"
           cx_dim "  可用：$CX_COMPOSE_VERBS"
           _compose_usage
           return "$EX_USAGE" ;;
    esac

    cx_docker_need
    cx_compose_init "${mode:-$CX_MODE}"

    case $verb in
        up)      _compose_up "$@" ;;
        down)    _compose_down "$@" ;;
        restart) cx_dc restart "$@" ;;
        ps)      cx_dc ps "$@" ;;
        logs)    _compose_logs "$@" ;;
        sh)      _compose_sh "$@" ;;
        build)   _compose_require_env; cx_dc build "$@" ;;
        config)  cx_dc_q config "$@" ;;
        dc)      cx_dc "$@" ;;
    esac
}

# cx dev … / cx prod … —— 動詞查找會優先命中這兩個，再退回 cmd_compose_main。
cmd_dev_main()  { CX_VERB=dev  cmd_compose_main "$@"; }
cmd_prod_main() { CX_VERB=prod cmd_compose_main "$@"; }
