#!/bin/sh
# ── nuxt 容器的啟動流程（dev target 專用）────────────────────────────────────
# prod / static target 不用這支，它們直接跑 node .output/server/index.mjs 或 nginx。
set -eu

log() { printf '\033[34m▸\033[0m entrypoint: %s\n' "$*" >&2; }

cd /app

# frontend/ 是 bind mount 進來的，node_modules 則是具名 volume。
# 具名 volume 被 down -v 清掉時要能自己復原，否則 nuxt dev 直接 MODULE_NOT_FOUND。
if [ ! -d node_modules/nuxt ]; then
    log "node_modules 不完整 → npm ci"
    if [ -f package-lock.json ]; then
        npm ci
    else
        npm install
    fi
fi

# NUXT_SSR 必須走 runtime 環境變數。build arg 進不了 nuxt dev，
# 於是 FRONTEND_MODE=spa 在 dev 模式會被靜默忽略 —— 這是驗收項目 3.5。
log "NUXT_SSR=${NUXT_SSR:-true} FRONTEND_MODE=${FRONTEND_MODE:-ssr}"

# 直接 exec nuxt，不要 exec npm。
#
# `npm run dev` 會讓 **npm** 成為 PID 1，而 npm 不可靠地轉發 SIGTERM ——
# 於是 dev 容器每次都是被 SIGKILL 的（Docker 預設 10 秒後）。
# 少一層行程比在 compose 加 init: true 更根本，兩者都做。
exec npx nuxt dev --host 0.0.0.0 --port 3000
