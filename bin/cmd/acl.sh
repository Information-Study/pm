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
  fix-owner               把不屬於你的檔案要回來（會列出並確認；需要 sudo）
  drop [路徑...]          移除 ACL，回到純 chmod 的狀態

旗標
  --web-user <名稱|uid>   網頁伺服器的執行身分（預設讀 .env 的 APP_UID）
  --dev-user <名稱|uid>   開發者身分（預設：你自己）

全域旗標（要寫在動詞**前面**，不是後面）
  cx --root <路徑> acl ...   指定專案根（預設：向上搜尋 .cxroot）
  cx --dry-run acl ...       只印出會執行的 setfacl，不執行
                             ⚠ 沒有 -n 這個短旗標；`cx acl -n` 會被當成子指令

為什麼是 ACL 不是 chmod
  setgid 只繼承群組，不繼承權限位元 —— 位元仍由建立者的 umask 決定。
  php-fpm 建的檔 deploy 不能寫，deploy 建的檔 php-fpm 不能寫，
  兩邊互相踩。default ACL 讓新檔一律帶上兩邊的權限，且 others 仍為 0。

範例
  cx acl check                     先看現況（唯讀）
  cx acl apply                     套用前後端的權限模型
  cx acl apply backend             只處理 Laravel
  cx acl user add alice            讓 alice 可以改原始碼
  cx acl status src/backend/storage    看單一路徑

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

# setfacl 需要「檔案的擁有者」或 root —— 同群組、甚至有寫入權都不夠。
# 樹裡只要有一個別人的檔案，setfacl -R 就會在那裡吐
#     setfacl: <path>: Operation not permitted
# 然後**中途停下**，前面設好的留著、後面的沒設到 —— 半套狀態最難查。
#
# 實際發生過的來源：容器的 entrypoint 以 root 執行，
# artisan package:discover 與 storage:link 在 bind mount 裡留下 root:root 的檔案。
# 所以先掃一遍再動手，並且把「哪些檔案、屬於誰、怎麼修」一次講完。
_acl_check_ownership() {
    # root 可以對任何檔案 setfacl，所以這個檢查對 root 沒有意義 ——
    # 而且會誤報整棵樹（find -not -user 0 會匹配所有非 root 的檔案）。
    # 這一行是必要的：錯誤訊息本身就建議「② sudo cx acl apply」，
    # 少了它那條建議會被自己的前置檢查擋住。
    (( $(id -u) == 0 )) && return 0
    local -a bad=()
    local d
    for d in backend frontend; do
        [[ -d $CX_ROOT/$d ]] || continue
        while IFS= read -r f; do bad+=("$f"); done \
            < <(find "$CX_ROOT/$d" -not -user "$(id -u)" -print 2>/dev/null)
    done
    (( ${#bad[@]} == 0 )) && return 0

    cx_error "有 ${#bad[@]} 個檔案不屬於你（uid $(id -u)）—— setfacl 會在它們上面失敗"
    local f
    for f in "${bad[@]:0:10}"; do
        cx_dim "  $(stat -c '%U:%G %A' "$f" 2>/dev/null)  ${f#$CX_ROOT/}"
    done
    (( ${#bad[@]} > 10 )) && cx_dim "  …還有 $(( ${#bad[@]} - 10 )) 個"
    cx_dim ""
    cx_dim "  setfacl 需要**擁有者或 root**，同群組不算。"
    cx_dim "  這些通常是容器以 root 執行 entrypoint 時留下的"
    cx_dim "  （artisan package:discover 與 storage:link）。"
    cx_dim ""
    cx_dim "  兩種修法，擇一："
    cx_dim "    ① 把擁有權要回來（推薦，一次解決）："
    cx_dim "         sudo chown -h $(id -un):$(id -gn) \\"
    local q
    for f in "${bad[@]:0:4}"; do q=${f#$CX_ROOT/}; cx_dim "           $q \\"; done
    (( ${#bad[@]} > 4 )) && cx_dim "           …（完整清單： cx acl check）"
    cx_dim "       或直接： cx acl fix-owner   （會列出並確認後才動手）"
    cx_dim "    ② 用 root 套 ACL： sudo cx acl apply"
    return "$EX_PRECOND"
}

# 把不屬於自己的檔案要回來。這是唯一需要 sudo 的動作，所以照紅線的規矩：
# 印出完整指令、要求確認，絕不偷偷跑。
_acl_fix_owner() {
    local -a bad=()
    local d
    for d in backend frontend; do
        [[ -d $CX_ROOT/$d ]] || continue
        while IFS= read -r f; do bad+=("$f"); done \
            < <(find "$CX_ROOT/$d" -not -user "$(id -u)" -print 2>/dev/null)
    done
    (( ${#bad[@]} )) || { cx_ok "所有檔案都已屬於你，不需要處理"; return 0; }

    cx_step "要回 ${#bad[@]} 個檔案的擁有權"
    local f
    for f in "${bad[@]}"; do
        cx_dim "  $(stat -c '%U:%G %A' "$f" 2>/dev/null)  ${f#$CX_ROOT/}"
    done
    cx_confirm --danger "變更檔案擁有者" \
        "將對上列 ${#bad[@]} 個檔案執行：\n\n  sudo chown -h $(id -un):$(id -gn) <檔案>\n\n這需要 sudo。確定嗎？" \
        || return "$EX_ABORT"

    # -h：清單裡可能有 symlink（public/storage 就是），
    # 不加的話 chown 會改到它指向的目標而不是 symlink 本身。
    if ! cx_run sudo chown -h "$(id -un):$(id -gn)" "${bad[@]}"; then
        cx_error "chown 失敗 —— sudo 不可用或被拒"
        cx_dim "  請自行執行："
        cx_dim "    sudo chown -h $(id -un):$(id -gn) ${bad[*]#$CX_ROOT/}"
        return "$EX_PRECOND"
    fi
    cx_ok "已取回擁有權，現在可以跑 cx acl apply"
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
#（見 env/docker/php/Dockerfile 的 groupmod/usermod），所以預設讀 .env 的 APP_UID。
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

# getfacl 預設印**名稱**（user:sixtou:rwx），而我們手上可能是 uid（來自 APP_UID）。
# 拿 uid 去 grep 名稱永遠不會中 —— 實測症狀是 apply 明明成功，
# check 卻回報「沒有讀取權的 ACL」，看起來像 apply 沒生效。
# 解法是兩邊都正規化成數字：比對時用 getfacl -n。
_acl_uid_of() {
    local who=$1
    [[ $who =~ ^[0-9]+$ ]] && { printf '%s' "$who"; return 0; }
    id -u "$who" 2>/dev/null || printf '%s' "$who"
}

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
    local b="$CX_ROOT/src/backend"
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
        cx_info "唯讀且不對外 → src/backend/.env"
        cx_run setfacl -m "u:$web:r--,u:$dev:rw-,o::---" "$b/.env" || return $?
    fi
    cx_ok "backend 完成"
}

_acl_apply_frontend() {
    local web dev
    web=$(_acl_resolve "$(_acl_web_id)") || return $?
    dev=$(_acl_resolve "$(_acl_dev_id)") || return $?
    local f="$CX_ROOT/src/frontend"
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
            # ⚠ web 與 dev 這兩個身分的 ACL 條目是**基礎模型**的一部分
            # （cx acl apply 設的），不是「授予其他開發者」的那一種。
            # 把它們 -x 掉會讓整個權限模型當場消失，而這個指令原本只會印
            # 「✔ <帳號> 的 ACL 已移除」，完全看不出剛剛拆掉了什麼。
            #
            # 這在本機特別容易發生：web 與 dev 常常都是你自己的 uid
            #（容器的 www-data 對齊成 APP_UID），於是
            #     cx acl user add 自己  →  cx acl user rm 自己
            # 這一組看起來完全無害的操作會把 cx acl apply 的成果整個抹掉。
            # 2026-09-05 實測踩到：rm 之後 cx acl check 從全綠變成四個警告。
            # 兩邊都要正規化成數字 uid 才比得起來：_acl_resolve 回傳的是**名稱**
            # （sixtou），而 _acl_web_id / _acl_dev_id 回傳的是 uid（1000）。
            # 這正是本檔 _acl_uid_of 上面那段註解講的同一個坑 —— 直接比會恆為
            # 不等，於是這道護欄形同不存在（第一版就是這樣寫的）。
            local rmid webid devid
            rmid=$(_acl_uid_of "$id"); webid=$(_acl_uid_of "$(_acl_web_id)")
            devid=$(_acl_uid_of "$(_acl_dev_id)")
            if [[ -n $rmid && ( $rmid == "$webid" || $rmid == "$devid" ) ]]; then
                cx_error "$who（uid $rmid）是本專案的 $( [[ $rmid == "$webid" ]] && printf 'web' || printf 'dev' ) 身分，不能用 acl user rm 移除"
                cx_dim "  那個條目是 cx acl apply 建立的基礎權限模型，不是額外授權。"
                cx_dim "  移除它會讓 web 讀不到程式碼／Laravel 寫不了 storage。"
                cx_dim "  真的要清掉整棵樹的 ACL： cx acl drop"
                cx_dim "  只是想改身分： cx acl apply --web-user <名稱|uid>"
                return "$EX_USAGE"
            fi
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
    for p in backend src/backend/storage src/backend/bootstrap/cache src/backend/.env frontend; do
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
    # 比對一律用數字 uid，輸出用 getfacl -n —— 見 _acl_uid_of 的說明。
    local webn devn
    webn=$(_acl_uid_of "$web"); devn=$(_acl_uid_of "$dev")
    cx_step "ACL 檢查（web=$web dev=$dev）"

    local -a want_ro=("backend" "frontend")
    local -a want_rw=("src/backend/storage" "src/backend/bootstrap/cache")
    local p acl

    for p in "${want_ro[@]}"; do
        [[ -d $CX_ROOT/$p ]] || continue
        acl=$(getfacl -pn --absolute-names "$CX_ROOT/$p" 2>/dev/null)
        if grep -qE "^user:$webn:r-x|^user:$webn:rwx" <<< "$acl"; then
            cx_ok "$p：web 可讀"
        else
            cx_warn "$p：web（$web）沒有讀取權的 ACL"; rc=1
        fi
    done

    for p in "${want_rw[@]}"; do
        [[ -d $CX_ROOT/$p ]] || continue
        acl=$(getfacl -pn --absolute-names "$CX_ROOT/$p" 2>/dev/null)
        if grep -qE "^user:$webn:rwx" <<< "$acl"; then
            cx_ok "$p：web 可寫"
        else
            cx_warn "$p：web（$web）沒有寫入權的 ACL —— Laravel 會 permission denied"; rc=1
        fi
        # default ACL 才是重點：沒有它，**新建的**檔案仍然回到 umask
        if grep -qE "^default:user:$webn:rwx" <<< "$acl"; then
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

    # 擁有權是 apply 的前置條件，check 應該先講 —— 否則使用者照著
    # 「修正： cx acl apply」去做，才在中途撞到 Operation not permitted。
    local -a bad=()
    if (( $(id -u) != 0 )); then          # root 不受此限，見 _acl_check_ownership
        for p in backend frontend; do
            [[ -d $CX_ROOT/$p ]] || continue
            while IFS= read -r f; do bad+=("$f"); done \
                < <(find "$CX_ROOT/$p" -not -user "$(id -u)" -print 2>/dev/null)
        done
    fi
    if (( ${#bad[@]} )); then
        cx_warn "有 ${#bad[@]} 個檔案不屬於你 —— cx acl apply 會在它們上面失敗"
        local f
        for f in "${bad[@]:0:5}"; do
            cx_dim "  $(stat -c '%U:%G' "$f" 2>/dev/null)  ${f#$CX_ROOT/}"
        done
        (( ${#bad[@]} > 5 )) && cx_dim "  …還有 $(( ${#bad[@]} - 5 )) 個"
        cx_dim "  先跑： cx acl fix-owner"
        rc=1
    fi

    # web 與 dev 是同一個 uid 時，ACL 在這台機器上不會有實際作用 ——
    # 該講出來，否則使用者會以為自己漏設了什麼。
    if [[ $webn == "$devn" ]]; then
        cx_dim "  註：web 與 dev 都是 $web（本機容器的 www-data 已對齊成你的 uid），"
        cx_dim "      所以本機其實不需要 ACL。規則仍然寫上去，之後 APP_UID 改了才不會突然壞掉。"
    fi

    (( rc == 0 )) && cx_ok "ACL 模型完整" || cx_dim "  修正： cx acl apply"
    return "$rc"
}

_acl_drop() {
    local -a paths=("$@")
    (( ${#paths[@]} )) || paths=("$CX_ROOT/src/backend" "$CX_ROOT/src/frontend")
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
        status|check)   _acl_need_tools || return $? ;;
        fix-owner)      : ;;   # 這一個的存在就是為了修好前置條件，不能被它擋住
        drop)           _acl_need_tools || return $? ;;
        *)              _acl_need_tools || return $?
                        _acl_need_fs "$CX_ROOT" || return $?
                        # apply / user 會遞迴下 setfacl，先確認整棵樹都是自己的。
                        # 不先檢查的話會在中途 EPERM 停下，留下半套 ACL。
                        _acl_check_ownership || return $? ;;
    esac

    case $sub in
        status)    _acl_status "$@" ;;
        check)     _acl_check ;;
        fix-owner) _acl_fix_owner ;;
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
