#!/usr/bin/env bash
# cx acl — 用 POSIX ACL 設定開發／部署環境的檔案權限。
#
# 為什麼需要 ACL，而不是 chmod / chown 就好：
#
#   目前的模型是 setgid + 群組（deploy:www-data、目錄 02750／02770）。
#   setgid 只讓新建的**目錄**繼承群組，**不繼承權限位元** ——
#   權限位元仍然由建立者的 umask 決定。於是：
#
#     php-fpm（www-data，umask 022）建出 storage/logs/laravel.log
#         → rw-r--r-- www-data:www-data
#         → deploy 雖然在 www-data 群組裡，卻**不能寫**這個檔
#
#     deploy（umask 022）建出 storage/framework/views/xxx.php
#         → rw-r--r-- deploy:www-data
#         → www-data 不能寫，Laravel 清快取時 Permission denied
#
#   這就是 Laravel「明明 chown 過了還是 permission denied」的典型成因。
#   `chmod -R 777` 能繞過，但那等於把 storage 對同機所有帳號開放，
#   而 storage 裡有 session、快取、上傳檔。
#
#   default ACL（setfacl -d）是唯一乾淨的解法：它讓**每一個新建的檔案與目錄**
#   都自動帶上指定的權限，完全不受 umask 影響，而且 others 仍然是 0。
#
# 三種權限分開處理（對應使用者的三個需求）：
#   backend    Laravel：整棵樹 web 可讀，storage/ 與 bootstrap/cache 可寫
#   frontend   Nuxt：靜態產物 web 可讀（PM2 模式下 node 以 deploy 身分跑）
#   user       其他開發者：可以改原始碼

_acl_usage() {
    cat >&9 <<'TXT'
cx acl <子指令> [參數...]

  status [路徑...]        顯示目前的 ACL（不給路徑就看本專案的關鍵路徑）
  apply [backend|frontend]
                          套用權限模型；不給就兩邊都套
  user add <帳號> [--ro]  讓另一個帳號能改原始碼（預設可寫，--ro 只讀）
  user rm  <帳號>         收回該帳號的權限
  check                   唯讀驗證（給 cx doctor / CI 用，不改任何東西）
  drop [路徑...]          移除 ACL，回到純 chmod 的狀態

旗標
  --web-user <名稱|uid>   網頁伺服器的執行身分（預設讀 .env 的 APP_UID）
  --dev-user <名稱|uid>   開發者身分（預設：你自己）
  --root <路徑>           要套用的專案根（預設：CX_ROOT）
  -n, --dry-run           只印出會執行的 setfacl，不執行

為什麼是 ACL 不是 chmod
  setgid 只繼承群組，不繼承權限位元 —— 位元仍由建立者的 umask 決定。
  php-fpm 建的檔 deploy 不能寫，deploy 建的檔 php-fpm 不能寫，
  兩邊互相踩。default ACL 讓新檔一律帶上兩邊的權限，且 others 仍為 0。

範例
  cx acl check                     先看現況（唯讀）
  cx acl apply                     套用前後端的權限模型
  cx acl apply backend             只處理 Laravel
  cx acl user add alice            讓 alice 可以改原始碼
  cx acl status backend/storage    看單一路徑

部署主機的權限由 Ansible 的 common role 處理（同一套模型），
不需要在目標機上跑 cx —— 見 docs/ansible-reference.md 的 §6.6。
TXT
}

# ---------------------------------------------------------------------------
# 前置：工具與檔案系統
# ---------------------------------------------------------------------------
_acl_need_tools() {
    local missing=()
    cx_have setfacl || missing+=(setfacl)
    cx_have getfacl || missing+=(getfacl)
    (( ${#missing[@]} == 0 )) && return 0
    cx_error "缺少 ${missing[*]}（套件：acl）"
    cx_dim "  安裝： cx setup system acl"
    cx_dim "  或    sudo apt-get install -y acl"
    return "$EX_PRECOND"
}

# ext4/xfs 現在預設就開 ACL，但 mount 選項仍可能關掉（noacl），
# 而 setfacl 在那種情況下的錯誤是 "Operation not supported" —— 看不出是掛載問題。
_acl_need_fs() {
    local d=$1 probe rc=0
    probe=$(mktemp -d "${d%/}/.cx-acl-probe.XXXXXX" 2>/dev/null) || {
        cx_error "$d 不可寫，無法檢查 ACL 支援"; return "$EX_PRECOND"; }
    setfacl -m u:"$(id -u)":rwx "$probe" 2>/dev/null || rc=$?
    rmdir "$probe" 2>/dev/null || true
    (( rc == 0 )) && return 0
    cx_error "$d 所在的檔案系統不支援 ACL（或以 noacl 掛載）"
    cx_dim "  檢查： findmnt -no SOURCE,FSTYPE,OPTIONS -T $d"
    cx_dim "  ext4/xfs 預設支援；掛載選項有 noacl 的話要拿掉再重新掛載。"
    return "$EX_PRECOND"
}

# ---------------------------------------------------------------------------
# 身分解析
# ---------------------------------------------------------------------------
# 網頁伺服器的身分。本機開發時容器裡的 www-data 已經被對齊成 APP_UID
#（見 docker/php/Dockerfile 的 groupmod/usermod），所以預設讀 .env 的 APP_UID。
# 讀不到就退回目前使用者 —— 那代表容器與 host 同 uid，本來就不需要 ACL，
# 但仍然把規則寫上去，這樣之後 APP_UID 改了也不會突然壞掉。
_acl_web_id() {
    [[ -n ${CX_ACL_WEB_USER:-} ]] && { printf '%s' "$CX_ACL_WEB_USER"; return 0; }
    local v=''
    [[ -f $CX_ROOT/.env ]] && v=$(grep -m1 '^APP_UID=' "$CX_ROOT/.env" 2>/dev/null | cut -d= -f2- | tr -d ' \r')
    [[ -n $v ]] || v=$(id -u)
    printf '%s' "$v"
}
_acl_dev_id() { printf '%s' "${CX_ACL_DEV_USER:-$(id -u)}"; }

# setfacl 接受名稱或 uid，但錯的名稱只會得到 "Invalid argument"，
# 完全看不出是哪一個 -m 出問題。先自己驗一次。
_acl_resolve() {
    local who=$1
    if [[ $who =~ ^[0-9]+$ ]]; then printf '%s' "$who"; return 0; fi
    id -u "$who" >/dev/null 2>&1 || {
        cx_error "找不到使用者：$who"
        cx_dim "  可用 uid 代替名稱（例如容器內的 www-data 在 host 上沒有對應帳號時）"
        return "$EX_USAGE"; }
    printf '%s' "$who"
}

# ---------------------------------------------------------------------------
# 套用
# ---------------------------------------------------------------------------
# $1=路徑 $2=ACL 規格（逗號分隔） $3=說明
# 同時下兩次：一次是「現有檔案」，一次是 -d「之後新建的」。
# 只下 -d 的話既有檔案不會變；只下非 -d 的話新檔又會回到 umask 決定。
_acl_set() {
    local path=$1 spec=$2 label=$3
    [[ -e $path ]] || { cx_dim "  略過（不存在）：${path#$CX_ROOT/}"; return 0; }
    cx_info "$label → ${path#$CX_ROOT/}"
    cx_run setfacl -R  -m "$spec" "$path" || return $?
    cx_run setfacl -Rd -m "$spec" "$path" || return $?
}

# X（大寫）只在「已經是目錄或已有任一執行位元」時才給 x。
# 用小寫 x 會讓每一個 .php 檔都變成可執行 —— 那是沒必要的攻擊面。
_acl_apply_backend() {
    local web dev
    web=$(_acl_resolve "$(_acl_web_id)") || return $?
    dev=$(_acl_resolve "$(_acl_dev_id)") || return $?
    local b="$CX_ROOT/backend"
    [[ -d $b ]] || { cx_warn "backend/ 不存在，略過"; return 0; }

    cx_step "backend（Laravel）— web=$web dev=$dev"

    # ① 整棵樹：web 可讀可進入，dev 可寫，**others 一律 0**。
    #    o::--- 不是可有可無：web 與 dev 都已經有明確的 ACL 條目，
    #    others 不需要任何權限。少了它，同機的其他帳號讀得到原始碼與 .env。
    #    這與部署模型的 02750（rwxr-x---）是同一個決定。
    _acl_set "$b" "u:$web:rX,u:$dev:rwX,o::---" "唯讀（原始碼、vendor、public）" || return $?

    # ② 兩個必須可寫的目錄。Laravel 會在這裡寫 log、快取、session、上傳檔，
    #    而 artisan（dev 身分）也會寫同一批檔案 —— 這正是 default ACL 的用途。
    #    o::--- 在這裡尤其重要：storage 裡有 session、快取與上傳檔。
    #    實測沒帶 o::--- 的後果：webu 以 umask 022 建出的 laravel.log
    #    會是 other::r--，同機任何帳號都讀得到日誌內容。
    #    對應部署模型的 02770。
    local w
    for w in storage bootstrap/cache; do
        _acl_set "$b/$w" "u:$web:rwX,u:$dev:rwX,o::---" "可寫（others 一律 0）" || return $?
    done

    # ③ .env 只給 web 讀，不給寫；others 一律 0。
    #    Laravel 只在啟動時讀它，沒有任何情況需要應用程式改自己的 .env。
    if [[ -f $b/.env ]]; then
        cx_info "唯讀且不對外 → backend/.env"
        cx_run setfacl -m "u:$web:r--,u:$dev:rw-,o::---" "$b/.env" || return $?
    fi
    cx_ok "backend 完成"
}

_acl_apply_frontend() {
    local web dev
    web=$(_acl_resolve "$(_acl_web_id)") || return $?
    dev=$(_acl_resolve "$(_acl_dev_id)") || return $?
    local f="$CX_ROOT/frontend"
    [[ -d $f ]] || { cx_warn "frontend/ 不存在，略過"; return 0; }

    cx_step "frontend（Nuxt）— web=$web dev=$dev"

    # Nuxt 兩種部署形態需要的權限不同，但取聯集是安全的：
    #   static 模式：nginx 直送 .output/public，只需要讀
    #   pm2 模式  ：node 以 deploy 身分跑，nginx 反代，也只需要讀靜態資產
    # 所以 web 一律只給 rX —— 前端沒有任何「應用程式要寫回原始碼樹」的情境。
    _acl_set "$f" "u:$web:rX,u:$dev:rwX,o::---" "唯讀（nginx 直送 / PM2 反代）" || return $?

    # node_modules 與建置產物只有 dev（或 CI）會寫，web 只讀。
    # 這裡不特別放寬 —— 上面那條已經涵蓋。
    cx_ok "frontend 完成"
}

_acl_user() {
    local action=${1:-}; shift || true
    local who=${1:-}; shift || true
    [[ -n $action && -n $who ]] || { cx_error "用法： cx acl user add|rm <帳號> [--ro]"; return "$EX_USAGE"; }
    local ro=0 a
    for a in "$@"; do [[ $a == --ro ]] && ro=1; done
    local id; id=$(_acl_resolve "$who") || return $?

    case $action in
        add)
            local spec="u:$id:rwX"; (( ro )) && spec="u:$id:rX"
            cx_step "授予 $who $( ((ro)) && echo '唯讀' || echo '可讀寫' )"
            local d
            for d in backend frontend; do
                [[ -d $CX_ROOT/$d ]] || continue
                _acl_set "$CX_ROOT/$d" "$spec" "$who" || return $?
            done
            # 專案根本身要能進入，否則上面全部白搭
            cx_run setfacl -m "u:$id:rX" "$CX_ROOT" || return $?
            cx_ok "$who 已可$( ((ro)) && echo '讀取' || echo '修改' )前後端原始碼"
            ;;
        rm|remove)
            cx_step "收回 $who 的權限"
            local d
            for d in backend frontend; do
                [[ -d $CX_ROOT/$d ]] || continue
                cx_run setfacl -R  -x "u:$id" "$CX_ROOT/$d" || return $?
                cx_run setfacl -Rd -x "u:$id" "$CX_ROOT/$d" || return $?
            done
            cx_run setfacl -x "u:$id" "$CX_ROOT" 2>/dev/null || true
            cx_ok "$who 的 ACL 已移除"
            ;;
        *) cx_error "未知的動作：$action（可用 add / rm）"; return "$EX_USAGE" ;;
    esac
}

# ---------------------------------------------------------------------------
# 檢視與驗證
# ---------------------------------------------------------------------------
_acl_paths() {
    local p
    for p in backend backend/storage backend/bootstrap/cache backend/.env frontend; do
        [[ -e $CX_ROOT/$p ]] && printf '%s\n' "$CX_ROOT/$p"
    done
    return 0
}

_acl_status() {
    local -a paths=("$@")
    (( ${#paths[@]} )) || { mapfile -t paths < <(_acl_paths); }
    (( ${#paths[@]} )) || { cx_warn "沒有可檢視的路徑"; return 0; }
    local p
    for p in "${paths[@]}"; do
        [[ $p == /* ]] || p="$CX_ROOT/$p"
        [[ -e $p ]] || { cx_warn "不存在：$p"; continue; }
        cx_step "${p#$CX_ROOT/}"
        getfacl -p --absolute-names "$p" 2>/dev/null | grep -vE '^#' | grep -v '^$' | sed 's/^/  /' >&8
    done
}

# check 是唯讀的，而且必須能被 doctor / CI 直接用退出碼判斷。
_acl_check() {
    local web dev rc=0
    web=$(_acl_resolve "$(_acl_web_id)") || return $?
    dev=$(_acl_resolve "$(_acl_dev_id)") || return $?
    cx_step "ACL 檢查（web=$web dev=$dev）"

    local -a want_ro=("backend" "frontend")
    local -a want_rw=("backend/storage" "backend/bootstrap/cache")
    local p acl

    for p in "${want_ro[@]}"; do
        [[ -d $CX_ROOT/$p ]] || continue
        acl=$(getfacl -p --absolute-names "$CX_ROOT/$p" 2>/dev/null)
        if grep -qE "^user:$web:r-x|^user:$web:rwx" <<< "$acl"; then
            cx_ok "$p：web 可讀"
        else
            cx_warn "$p：web（$web）沒有讀取權的 ACL"; rc=1
        fi
    done

    for p in "${want_rw[@]}"; do
        [[ -d $CX_ROOT/$p ]] || continue
        acl=$(getfacl -p --absolute-names "$CX_ROOT/$p" 2>/dev/null)
        if grep -qE "^user:$web:rwx" <<< "$acl"; then
            cx_ok "$p：web 可寫"
        else
            cx_warn "$p：web（$web）沒有寫入權的 ACL —— Laravel 會 permission denied"; rc=1
        fi
        # default ACL 才是重點：沒有它，**新建的**檔案仍然回到 umask
        if grep -qE "^default:user:$web:rwx" <<< "$acl"; then
            cx_ok "$p：新建檔案會繼承（default ACL）"
        else
            cx_warn "$p：沒有 default ACL —— 現有檔案沒問題，但新建的還是會踩 umask"; rc=1
        fi
        # others 必須是 0。storage 裡有 session / 快取 / 上傳檔，
        # 少了 default:other::--- 的話，新建的檔會帶著 umask 給的 other::r--。
        if grep -qE "^default:other::---" <<< "$acl"; then
            cx_ok "$p：新建檔案不對 others 開放"
        else
            cx_warn "$p：新建檔案會對 others 開放 —— session 與日誌同機可讀"; rc=1
        fi
    done

    (( rc == 0 )) && cx_ok "ACL 模型完整" || cx_dim "  修正： cx acl apply"
    return "$rc"
}

_acl_drop() {
    local -a paths=("$@")
    (( ${#paths[@]} )) || paths=("$CX_ROOT/backend" "$CX_ROOT/frontend")
    cx_confirm --danger "移除 ACL" \
        "將對下列路徑執行 setfacl -R -b（清空所有 ACL 條目）：\n\n$(printf '  %s\n' "${paths[@]}")\n\n之後權限回到純 chmod 的狀態。確定嗎？" \
        || return "$EX_ABORT"
    local p
    for p in "${paths[@]}"; do
        [[ -e $p ]] || continue
        cx_info "清除 ${p#$CX_ROOT/}"
        cx_run setfacl -R -b "$p" || return $?
    done
    cx_ok "已移除"
}

# ---------------------------------------------------------------------------
cmd_acl_main() {
    local -a rest=()
    while (( $# )); do
        case $1 in
            --web-user) [[ -n ${2:-} ]] || cx_die "$EX_USAGE" "--web-user 需要一個值"
                        CX_ACL_WEB_USER=$2; shift 2 ;;
            --dev-user) [[ -n ${2:-} ]] || cx_die "$EX_USAGE" "--dev-user 需要一個值"
                        CX_ACL_DEV_USER=$2; shift 2 ;;
            -h|--help|help) _acl_usage; return 0 ;;
            *)          rest+=("$1"); shift ;;
        esac
    done
    set -- "${rest[@]}"

    local sub=${1:-status}
    [[ $# -gt 0 ]] && shift

    # status / check 是唯讀的，不需要能寫；其餘都要先確認工具與檔案系統。
    case $sub in
        status|check) _acl_need_tools || return $? ;;
        *)            _acl_need_tools || return $?
                      _acl_need_fs "$CX_ROOT" || return $? ;;
    esac

    case $sub in
        status) _acl_status "$@" ;;
        check)  _acl_check ;;
        drop)   _acl_drop "$@" ;;
        user)   _acl_user "$@" ;;
        apply)
            case ${1:-} in
                backend)  _acl_apply_backend ;;
                frontend) _acl_apply_frontend ;;
                '')       _acl_apply_backend && _acl_apply_frontend ;;
                *) cx_error "apply 只接受 backend / frontend（收到：$1）"; return "$EX_USAGE" ;;
            esac
            ;;
        *) cx_error "未知的子指令：$sub"; _acl_usage; return "$EX_USAGE" ;;
    esac
}
