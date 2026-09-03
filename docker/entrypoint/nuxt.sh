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

exec npm run dev -- --host 0.0.0.0 --port 3000
