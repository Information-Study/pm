# syntax=docker/dockerfile:1
# ── pm app 映像（php-fpm + nginx + supervisord）─────────────────────────────
# build context 是專案根目錄，所以路徑寫 backend/... 與 docker/php/...
#
# 六個 stage：base → vendor-dev / vendor-prod → dev / test / prod
#
# 兩件絕對不能改的事：
#   1) 一律用 mlocati/php-extension-installer，不要用 pecl install。
#      PECL 已被 Xdebug 官方標為 deprecated，且在 Alpine PHP 8.4+ 有
#      "Constant E_STRICT is deprecated" → "Filename too long" 的已知失敗。
#   2) vendor-dev 不可加 --no-autoloader。Composer 文件明載該旗標會跳過
#      vendor/autoload.php 產生，而 dev stage 只 COPY --from=vendor-dev，
#      沒有任何步驟重新產生 autoloader → entrypoint 第一步就 fatal。

ARG PHP_IMAGE=php:8.5-fpm-alpine
# 後端的 Vite 資產要用 node 建置（見下面的 backend-assets stage）。
ARG NODE_IMAGE=node:24.20-alpine

# ════════════════════════════════════════════════════════════════════════════
# base —— 共用擴充、nginx、supervisor、composer
# ════════════════════════════════════════════════════════════════════════════
FROM ${PHP_IMAGE} AS base

ARG APP_UID=1000
ARG APP_GID=1000

# install-php-extensions 會自己處理 build deps 的裝與卸，不需要手動 .build-deps。
COPY --from=mlocati/php-extension-installer:2.11.12 /usr/bin/install-php-extensions /usr/local/bin/

# intl 是 Filament v5 的硬性需求（claude.md §0.5）。
# bcmath 雖然 Laravel 13 與 Filament v5 都沒要求，但成本極低且常被套件用到。
# pdo_sqlite 是給 backend/phpunit.xml 用的：它把測試導向 sqlite :memory:。
# 少了這個擴充，php artisan test 會是 "could not find driver"，而那看起來
# 完全不像「擴充沒裝」，比較像資料庫設定錯了。
RUN install-php-extensions \
        intl \
        mbstring \
        pdo_mysql \
        mysqli \
        gd \
        zip \
        exif \
        opcache \
        bcmath \
        pcntl \
        sockets \
        pdo_sqlite \
 && apk add --no-cache \
        nginx \
        supervisor \
        curl \
        mysql-client \
        tzdata \
        shadow \
 && rm -f /etc/nginx/http.d/default.conf

# 對齊容器內 www-data 與 host 端的 uid/gid。
# 不對齊的話 dev 模式 bind mount 進來的 backend/ 容器寫不進去（storage/logs 首當其衝），
# 而 host 端的你也刪不掉容器寫出來的檔。
# -o 允許 uid/gid 重複：Alpine 的 1000 可能已經被別的系統帳號佔用。
RUN set -eux; \
    cur_gid="$(getent group www-data | cut -d: -f3)"; \
    cur_uid="$(id -u www-data)"; \
    if [ "$APP_GID" != "$cur_gid" ]; then groupmod -o -g "$APP_GID" www-data; fi; \
    if [ "$APP_UID" != "$cur_uid" ]; then usermod -o -u "$APP_UID" -g "$APP_GID" www-data; fi

COPY --from=composer/composer:2.10.3-bin /composer /usr/local/bin/composer

COPY docker/php/php.ini          /usr/local/etc/php/conf.d/zz-pm.ini
COPY docker/php/www.conf         /usr/local/etc/php-fpm.d/zz-www.conf
COPY docker/php/nginx.conf       /etc/nginx/nginx.conf
COPY docker/php/default.conf     /etc/nginx/http.d/default.conf
# 放 /etc/supervisord.conf（Alpine supervisor 套件的預設路徑）。
# supervisorctl 讀的是它自己的預設設定檔，不是 supervisord 啟動時 -c 指定的那個，
# 所以放錯地方會讓 `exec app supervisorctl status` 找不到 socket —— 而那是 D5 的驗收指令。
COPY docker/php/supervisord.conf /etc/supervisord.conf
COPY docker/entrypoint/app.sh    /usr/local/bin/pm-entrypoint

# art / t 捷徑：舊專案的 dockerfile.development 就有，操作者已經習慣。
#   cx dev sh app        然後在容器裡打 art migrate / t --filter=User
# 用 echo 逐行寫檔而不是 printf 帶跳脫字元 —— 跳脫字元很容易在多層引號中被吃掉。
RUN set -eux; \
    { echo '#!/bin/sh'; echo 'exec php /var/www/html/artisan "$@"'; } > /usr/local/bin/art; \
    { echo '#!/bin/sh'; echo 'exec php /var/www/html/artisan test "$@"'; } > /usr/local/bin/t; \
    chmod +x /usr/local/bin/art /usr/local/bin/t

RUN chmod +x /usr/local/bin/pm-entrypoint \
 && mkdir -p /var/www/html /var/log/supervisor /etc/supervisor/conf.d /var/lib/nginx/tmp /var/run \
 && chown -R www-data:www-data /var/www/html /var/lib/nginx

ENV COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_MEMORY_LIMIT=-1 \
    COMPOSER_NO_INTERACTION=1

WORKDIR /var/www/html
EXPOSE 8080

# 不要在這裡宣告 ENTRYPOINT。
# 官方 php 映像的 ENTRYPOINT 是 docker-php-entrypoint，它會 exec 傳進來的 argv，
# 所以 --entrypoint composer 覆寫時 argv 是乾淨的。
# 啟動流程放 CMD，兩種用法就都成立。

# ════════════════════════════════════════════════════════════════════════════
# vendor-dev —— dev / test 的 vendor（含 dev 相依：larastan、phpunit、pint）
# ════════════════════════════════════════════════════════════════════════════
FROM base AS vendor-dev

COPY backend/composer.json backend/composer.lock ./
# --no-scripts：此時還沒有原始碼，post-autoload-dump 的
# artisan package:discover 與 artisan filament:upgrade 一定會失敗。
# 這兩件事改由 entrypoint 在有原始碼時做。
# 絕對不要加 --no-autoloader —— 見檔頭第 2 點。
RUN composer install \
        --no-interaction \
        --prefer-dist \
        --no-progress \
        --no-scripts \
 && test -f vendor/autoload.php \
 && composer clear-cache

# ════════════════════════════════════════════════════════════════════════════
# vendor-prod —— prod 的 vendor（--no-dev）
# ════════════════════════════════════════════════════════════════════════════
FROM base AS vendor-prod

COPY backend/composer.json backend/composer.lock ./
RUN composer install \
        --no-interaction \
        --prefer-dist \
        --no-progress \
        --no-scripts \
        --no-dev \
 && test -f vendor/autoload.php \
 && composer clear-cache


# ════════════════════════════════════════════════════════════════════════════
# backend-assets —— Laravel 端的 Vite 資產（public/build/）
# ════════════════════════════════════════════════════════════════════════════
# backend 有自己的 package.json（Vite + Tailwind），welcome.blade.php 用
# @vite(['resources/css/app.css','resources/js/app.js']) 引用建置結果。
# 沒有 public/build/manifest.json 時，渲染會直接丟 ViteManifestNotFoundException。
#
# 舊專案的 init.sh / refresh.sh 呼叫一個叫 npm-php 的 compose service 來做這件事，
# 但那個 service 從來沒有存在過（驗證文件的缺陷 D3）——
# 也就是說後端資產在舊專案裡從來沒被建置過。
FROM ${NODE_IMAGE} AS backend-assets

WORKDIR /app
COPY backend/package.json backend/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY backend/ ./
RUN npm run build && test -d public/build
# ════════════════════════════════════════════════════════════════════════════
# dev —— 開發
# ════════════════════════════════════════════════════════════════════════════
FROM base AS dev

RUN install-php-extensions xdebug

COPY docker/php/zz-mode-dev.ini /usr/local/etc/php/conf.d/zz-mode.ini

# 不 COPY 原始碼。dev 模式的 ./backend:/var/www/html bind mount 會把它蓋掉，
# 烘進來只是徒增 image 大小與「我改了檔怎麼沒生效」的困惑。
# vendor 例外：它要被烘進來，好讓 compose 的具名 volume 用 image 內容種子化。
COPY --from=vendor-dev --chown=www-data:www-data /var/www/html/vendor ./vendor

# 這個映像的 PID 1 是 supervisord，而它必須以 root 執行：
#   * nginx master 要 root 才能 bind 並把 worker 降權成 www-data
#   * php-fpm master 要 root 才能把 pool 降權成 www-data（www.conf 的 user=）
# 真正處理請求的 worker 全部是 www-data（uid 已對齊成 APP_UID）。
# 加上 USER 之後 supervisord 起不來，這不是「忘了加」而是架構決定。
# 對應的 Trivy DS-0002 例外記在 docker/security/trivy/.trivyignore.yaml，有到期日。
# nosemgrep: dockerfile.security.missing-user.missing-user
CMD ["pm-entrypoint"]

# ════════════════════════════════════════════════════════════════════════════
# test —— 受測物（不可變映像）
# ════════════════════════════════════════════════════════════════════════════
FROM base AS test

# xdebug 要裝，但預設關閉（env XDEBUG_MODE=off，entrypoint 據此不寫 ini）。
# 只在要收覆蓋率時才由 cx test 打開。常開會讓 ZAP 的時間量測全部失真。
RUN install-php-extensions xdebug

# ⚠ 不要在這裡沿用 zz-mode-dev.ini。test 是被 ZAP 掃、被 ModSecurity 擋的
# 那個模式，display_errors = On 會把路徑與堆疊直接寫進 HTTP 回應，
# 等於在 DAST 的攻擊面上多開一個資訊洩漏。APP_DEBUG=false 擋得住 Laravel 的
# 除錯頁，擋不住 PHP 自己的 fatal error 輸出。
COPY docker/php/zz-mode-test.ini /usr/local/etc/php/conf.d/zz-mode.ini

COPY --from=vendor-dev --chown=www-data:www-data /var/www/html/vendor ./vendor
COPY --chown=www-data:www-data backend/ ./
# 建好的 Vite 資產。放在 COPY backend/ 之後，才不會被原始碼覆蓋掉。
COPY --from=backend-assets --chown=www-data:www-data /app/public/build ./public/build

# 原始碼進來之後才重建 optimized autoloader（--no-scripts 同理）。
RUN composer dump-autoload --optimize --no-scripts \
 && mkdir -p storage/framework/cache storage/framework/sessions storage/framework/views storage/logs bootstrap/cache \
 && chown -R www-data:www-data storage bootstrap/cache

# 這個映像的 PID 1 是 supervisord，而它必須以 root 執行：
#   * nginx master 要 root 才能 bind 並把 worker 降權成 www-data
#   * php-fpm master 要 root 才能把 pool 降權成 www-data（www.conf 的 user=）
# 真正處理請求的 worker 全部是 www-data（uid 已對齊成 APP_UID）。
# 加上 USER 之後 supervisord 起不來，這不是「忘了加」而是架構決定。
# 對應的 Trivy DS-0002 例外記在 docker/security/trivy/.trivyignore.yaml，有到期日。
# nosemgrep: dockerfile.security.missing-user.missing-user
CMD ["pm-entrypoint"]

# ════════════════════════════════════════════════════════════════════════════
# prod —— 正式
# ════════════════════════════════════════════════════════════════════════════
FROM base AS prod

COPY docker/php/zz-mode-prod.ini /usr/local/etc/php/conf.d/zz-mode.ini

COPY --from=vendor-prod --chown=www-data:www-data /var/www/html/vendor ./vendor
COPY --chown=www-data:www-data backend/ ./
# 建好的 Vite 資產。放在 COPY backend/ 之後，才不會被原始碼覆蓋掉。
COPY --from=backend-assets --chown=www-data:www-data /app/public/build ./public/build

RUN composer dump-autoload --classmap-authoritative --no-dev --no-scripts \
 && mkdir -p storage/framework/cache storage/framework/sessions storage/framework/views storage/logs bootstrap/cache \
 && chown -R www-data:www-data storage bootstrap/cache \
 && rm -rf /root/.composer /tmp/*

# build 斷言：prod 映像絕對不能有 xdebug。
# 這一行會讓「不小心把 xdebug 加進 prod」的 build 直接失敗 —— 這是刻意的（D12）。
RUN if php -m | grep -qi "^xdebug$"; then \
        echo "BUILD ASSERT FAILED: prod 映像不得含 xdebug" >&2; exit 1; \
    fi

# 第二道斷言：vendor 不能含 dev 相依。larastan / phpunit 跑進正式映像
# 代表 --no-dev 沒生效，而那通常是 vendor stage 選錯了。
RUN if [ -d vendor/phpunit/phpunit ]; then \
        echo "BUILD ASSERT FAILED: prod vendor 含 dev 相依（phpunit）" >&2; exit 1; \
    fi

# 這個映像的 PID 1 是 supervisord，而它必須以 root 執行：
#   * nginx master 要 root 才能 bind 並把 worker 降權成 www-data
#   * php-fpm master 要 root 才能把 pool 降權成 www-data（www.conf 的 user=）
# 真正處理請求的 worker 全部是 www-data（uid 已對齊成 APP_UID）。
# 加上 USER 之後 supervisord 起不來，這不是「忘了加」而是架構決定。
# 對應的 Trivy DS-0002 例外記在 docker/security/trivy/.trivyignore.yaml，有到期日。
# nosemgrep: dockerfile.security.missing-user.missing-user
CMD ["pm-entrypoint"]
