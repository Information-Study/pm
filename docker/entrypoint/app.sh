#!/bin/sh
# ── app 容器的啟動流程 ──────────────────────────────────────────────────────
# 這支腳本是 image 的 CMD，不是 ENTRYPOINT。
#
# 為什麼是 CMD：image 的 ENTRYPOINT 必須保持 docker-php-entrypoint 的 argv 直通，
# 否則 `compose run --rm --entrypoint composer app install` 會變成
# `<entrypoint> composer install`，composer 收到自己的名字當第一個參數。
# 把啟動流程放 CMD，就同時滿足「up 時要 bootstrap」與「run 時要能直接下別的指令」。
#
# 用 /bin/sh（Alpine 的 busybox ash），不是 bash —— base 映像沒有 bash。
set -eu

log() { printf '\033[34m▸\033[0m entrypoint: %s\n' "$*" >&2; }
die() { printf '\033[31m✘\033[0m entrypoint: %s\n' "$*" >&2; exit 1; }

APP_ROOT=/var/www/html
cd "$APP_ROOT"

# ── 1. vendor 保險 ─────────────────────────────────────────────────────────
# dev 模式把 ./backend bind mount 進來，會遮掉 image 裡的 vendor（舊 compose 的 D6）。
# compose 用具名 volume 掛回 vendor 來解決，但如果有人手動 down -v 過，
# 具名 volume 會是空的 —— 這時要能自己救回來，而不是在下一步 fatal。
if [ ! -f vendor/autoload.php ]; then
    log "vendor/autoload.php 不存在 → composer install（這通常代表 vendor volume 被清掉了）"
    composer install --no-interaction --prefer-dist --no-progress --no-scripts \
        || die "composer install 失敗，無法繼續"
fi
[ -f vendor/autoload.php ] || die "composer install 之後 vendor/autoload.php 仍不存在"

# ── 2. .env 與 APP_KEY ─────────────────────────────────────────────────────
# 舊版的 D2：初始化腳本既沒有 cp .env 也沒有 key:generate，
# 於是第一次啟動就是 "No application encryption key has been specified."
#
# 2026-09-05 起分成兩條路：
#
#   APP_KEY 由 compose 注入（test / prod）
#       完全不碰 .env。Laravel 讀得到環境變數就夠了，Dotenv 找不到檔案是容忍的。
#       這一條是必要的，因為 .env 現在被 .dockerignore 排除（否則開發者的
#       APP_KEY 與 DB_PASSWORD 會被烘進映像層），而容器裡的 .env 落在
#       writable layer、不在任何 volume 上 —— 每次 --force-recreate 都會
#       換一把新金鑰，把 session 與 encrypted cast 的資料變成解不開的亂碼。
#       順帶讓 read_only: true 變成可行（不再有啟動時的寫入）。
#
#   APP_KEY 沒有注入（dev，或有人手動 docker run）
#       維持舊行為：從 .env.example 複製並 key:generate。
#       dev 的 .env 是 host 上 bind mount 進來的真檔案，本來就要持久化。
if [ -n "${APP_KEY:-}" ]; then
    log "APP_KEY 由環境注入 —— 不建立也不修改 .env"
else
    if [ ! -f .env ]; then
        if [ -f .env.example ]; then
            log ".env 不存在 → 從 .env.example 複製"
            cp .env.example .env
        else
            log ".env 與 .env.example 都不存在 → 建立空的 .env"
            : > .env
        fi
    fi
    # compose 傳進來的真實環境變數優先於 .env（Laravel 的 Dotenv 預設不覆寫既有 env），
    # 所以 .env 裡只需要有 APP_KEY 這個「必須持久化」的值。
    if ! grep -q '^APP_KEY=base64:' .env 2>/dev/null; then
        log "產生 APP_KEY"
        php artisan key:generate --force --no-interaction || die "key:generate 失敗"
    fi
    # 這支腳本以 root 執行，而 dev 模式的 .env 其實是 host 上的檔案
    # （./backend bind mount 進來）。不 chown 的話 host 端的你會發現
    # backend/.env 是 root:root，改不動也刪不掉。
    # www-data 的 uid/gid 在 build 時已經對齊成 APP_UID/APP_GID。
    chown www-data:www-data .env 2>/dev/null || true
    chmod 640 .env 2>/dev/null || true
fi

# ── 3. 目錄權限 ────────────────────────────────────────────────────────────
# 不用 chmod 777（舊版做過，是必然的 Trivy/Semgrep misconfig finding）。
# 只把 owner 交給 www-data，權限維持 775 / 664。
for d in storage storage/logs storage/framework storage/framework/cache \
         storage/framework/sessions storage/framework/views bootstrap/cache; do
    [ -d "$d" ] || mkdir -p "$d"
done
chown -R www-data:www-data storage bootstrap/cache 2>/dev/null || true
chmod -R u+rwX,g+rwX,o-rwx storage bootstrap/cache 2>/dev/null || true

# ── 4. xdebug ──────────────────────────────────────────────────────────────
# ini 檔在這裡生成而不是烘進 image，因為 client_host / client_port 是 runtime 才知道的。
# PHP 的 ini 不支援環境變數插值，所以只能寫檔。
XDEBUG_MODE=${XDEBUG_MODE:-off}
if php -m 2>/dev/null | grep -qi '^xdebug$'; then
    if [ "$XDEBUG_MODE" = "off" ]; then
        rm -f /usr/local/etc/php/conf.d/zz-xdebug.ini
        log "xdebug 已安裝但 XDEBUG_MODE=off → 不載入設定"
    else
        log "xdebug 設定：mode=$XDEBUG_MODE start=${XDEBUG_START:-trigger}"
        # ⚠ 這裡不能寫 ${XDEBUG_LOG_LEVEL:+xdebug.log = …}。
        # ${var:+…} 判斷的是「字串非空」，而預設值 "0" 是非空字串 ——
        # 於是 log_level=0（不記錄）的時候仍然會寫出 xdebug.log 這一行。
        # 功能上無害（level 0 什麼都不寫），但設定檔會說謊：
        # php -i 顯示 xdebug.log => /var/log/xdebug.log，看起來像 log 開著。
        # 要判斷「數值大於 0」就得自己算。
        _XDEBUG_LOG_LINE=''
        if [ "${XDEBUG_LOG_LEVEL:-0}" -gt 0 ] 2>/dev/null; then
            _XDEBUG_LOG_LINE='xdebug.log = /var/log/xdebug.log'
            log "xdebug log_level=$XDEBUG_LOG_LEVEL → 寫 /var/log/xdebug.log"
        fi
        cat > /usr/local/etc/php/conf.d/zz-xdebug.ini <<XDEBUG
xdebug.mode = ${XDEBUG_MODE}
xdebug.start_with_request = ${XDEBUG_START:-trigger}
xdebug.client_host = ${XDEBUG_CLIENT_HOST:-host.docker.internal}
xdebug.client_port = ${XDEBUG_CLIENT_PORT:-9003}
xdebug.log_level = ${XDEBUG_LOG_LEVEL:-0}
${_XDEBUG_LOG_LINE}
xdebug.connect_timeout_ms = 200
XDEBUG
    fi
fi

# ── 5. 等 DB 就緒 ──────────────────────────────────────────────────────────
# compose 的 depends_on: service_healthy 已經等過一次，但 `compose run` 不吃
# depends_on 的 healthy 條件，所以這裡再等一次，成本很低。
DB_HOST=${DB_HOST:-mysql}
DB_PORT=${DB_PORT:-3306}
i=0
until mysqladmin ping -h "$DB_HOST" -P "$DB_PORT" --silent >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -ge 60 ] && die "等待 $DB_HOST:$DB_PORT 逾時（60 次 × 2s）"
    [ "$i" = 1 ] && log "等待 MySQL $DB_HOST:$DB_PORT ..."
    sleep 2
done
log "MySQL 就緒"

# ── 6. package:discover ────────────────────────────────────────────────────
# build 階段的 composer 都加了 --no-scripts（沒有原始碼時 artisan 跑不起來），
# 所以 bootstrap/cache/packages.php 要在這裡生成，否則 Laravel 開不了機。
php artisan package:discover --ansi --no-interaction >/dev/null 2>&1 \
    || log "package:discover 有警告（繼續）"
# 這支腳本以 root 執行（supervisord 需要），所以剛剛生出來的
# bootstrap/cache/packages.php 是 root:root —— 而 bootstrap/cache 是 bind mount。
# 後果有兩個，都實際發生過：
#   * host 上的你 chmod / setfacl 它會得到 Operation not permitted
#     （setfacl 需要擁有者或 root，同群組不算）
#   * 上面第 62 行的 chown -R 跑在**這一行之前**，蓋不到新生成的檔
chown www-data:www-data bootstrap/cache/packages.php 2>/dev/null || true

# ── 7. migration ───────────────────────────────────────────────────────────
# DB_FRESH 只有 test 模式會設 true，而且**必須一次性化**。
# base 是 restart: unless-stopped，這支腳本每次啟動都會跑；
# 沒有哨兵檔的話，一次 OOM kill 就會在 ZAP 掃描中途 migrate:fresh --seed，
# 掃描結果全部失真而且看不出原因。哨兵檔放在 storage（具名 volume），
# 跟著資料庫的生命週期一起活。
SENTINEL=storage/.pm-db-fresh-done
if [ "${DB_FRESH:-false}" = "true" ] && [ ! -f "$SENTINEL" ]; then
    log "DB_FRESH=true 且哨兵檔不存在 → migrate:fresh --seed（只做這一次）"
    php artisan migrate:fresh --seed --force --no-interaction || die "migrate:fresh 失敗"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$SENTINEL"
    chown www-data:www-data "$SENTINEL" 2>/dev/null || true
    log "哨兵檔已寫入：$SENTINEL（要再 fresh 一次請 cx db fresh 或刪掉這個檔）"
else
    log "migrate --force"
    php artisan migrate --force --no-interaction || die "migrate 失敗"
fi

# ── 8. 快取 ────────────────────────────────────────────────────────────────
# dev 不快取設定，否則改了 .env 完全沒反應，而且會是最難查的那種「沒反應」。
if [ "${APP_ENV:-local}" = "production" ] || [ "${APP_MODE:-dev}" = "prod" ]; then
    log "prod：config / route / view / event 快取"
    php artisan config:cache --no-interaction || die "config:cache 失敗"
    php artisan event:cache  --no-interaction || log "event:cache 有警告（繼續）"
    php artisan view:cache   --no-interaction || log "view:cache 有警告（繼續）"
    # route:cache 對含 closure 的路由會失敗。backend/routes/*.php 目前有 closure，
    # 所以刻意不做 —— 失敗訊息（"Unable to prepare route ... for serialization"）
    # 很容易被誤讀成路由壞了。
else
    log "非 prod：清掉可能殘留的快取"
    php artisan config:clear --no-interaction >/dev/null 2>&1 || true
    php artisan route:clear  --no-interaction >/dev/null 2>&1 || true
    php artisan view:clear   --no-interaction >/dev/null 2>&1 || true
fi

# storage:link 在 public/storage 已存在時會失敗，所以要判斷。
# 同樣以 root 建立，同樣要把 owner 交回去 —— 這是一個 symlink，
# 用 -h 才會改到 symlink 本身而不是它指向的目標。
if [ ! -e public/storage ]; then
    php artisan storage:link --no-interaction >/dev/null 2>&1 || true
    chown -h www-data:www-data public/storage 2>/dev/null || true
fi

log "啟動 supervisord（php-fpm + nginx + queue ×2 + schedule）"
exec supervisord -c /etc/supervisord.conf
