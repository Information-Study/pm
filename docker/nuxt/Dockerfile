# syntax=docker/dockerfile:1
# ── pm nuxt 映像 ────────────────────────────────────────────────────────────
# build context 是專案根目錄，路徑寫 frontend/...
#
# 五個 stage：deps → dev / build → prod / static
#
# 舊版（docker/legacy/nuxt-dockerfile.orig）的問題（D15）：
# 只有一個 stage、只有 npm run dev、用 npm install 而非 npm ci、
# node:24-alpine 是浮動 tag、以 root 執行、沒有注入 NUXT_PUBLIC_API_BASE_URL（D8）。
#
# 三個前端模式與 API base URL 的決定時機：
#   ssr    nuxt build     Nitro 跑 .output/server/index.mjs   啟動時（可用環境變數）
#   spa    nuxt build     同上（ssr:false）                    build 時（烘進 bundle）
#   static nuxt generate  nginx 直送 .output/public            build 時（烘進 bundle）
# 所以 image tag 一定要含 FRONTEND_MODE，否則 test 會拿到 prod 的 bundle。

ARG NODE_IMAGE=node:24.20-alpine
ARG NGINX_IMAGE=nginx:1.30-alpine

# ════════════════════════════════════════════════════════════════════════════
# deps —— 只裝相依，讓 lockfile 沒變時可以命中快取
# ════════════════════════════════════════════════════════════════════════════
FROM ${NODE_IMAGE} AS deps

WORKDIR /app
COPY frontend/package.json frontend/package-lock.json ./
# npm ci 而非 npm install：ci 嚴格照 lockfile，install 會在 lockfile 過期時
# 悄悄改版本 —— 而 vue-router 一旦被 dedupe 到 v4，首次導航就壞。
RUN npm ci --no-audit --no-fund

# ════════════════════════════════════════════════════════════════════════════
# dev —— 開發（HMR）
# ════════════════════════════════════════════════════════════════════════════
FROM ${NODE_IMAGE} AS dev

WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY docker/entrypoint/nuxt.sh /usr/local/bin/pm-nuxt-entrypoint
RUN chmod +x /usr/local/bin/pm-nuxt-entrypoint

# 不 COPY 原始碼 —— dev 模式 ./frontend:/app bind mount 會蓋掉。

# .nuxt 與 .output 掛的是**具名 volume**，而具名 volume 只有在
# 「映像裡那個路徑存在」的時候才會用映像的內容與擁有者去種子化。
# 這兩個目錄在映像裡本來不存在 → Docker 直接建成 root:root 0755 →
# 以 node 身分跑的 nuxt dev 寫不進去，而錯誤訊息是
#     EACCES: permission denied, open '/app/.nuxt/nuxt.json'
# 完全不會提到 volume 或權限來源。更糟的是 volume 會**留著**：
# 一旦被種成 root:root，之後每一次 cx dev up 都會用同一個壞掉的 volume，
# 重建映像也救不回來，只能 docker volume rm。
# 2026-09-05 實測到這個狀態（volume 內容 root:root、日期是三天前）。
#
# 先建好並 chown，volume 就會用正確的擁有者種子化。
RUN mkdir -p /app/.nuxt /app/.output /app/node_modules \
 && chown -R node:node /app
USER node

EXPOSE 3000
CMD ["pm-nuxt-entrypoint"]

# ════════════════════════════════════════════════════════════════════════════
# build —— 產生 .output（ssr / spa / static 共用這個 stage）
# ════════════════════════════════════════════════════════════════════════════
FROM ${NODE_IMAGE} AS build

ARG FRONTEND_MODE=ssr
ARG NUXT_PUBLIC_API_BASE_URL=

WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY frontend/ ./

# spa / static 的 API base URL 在這裡被烘進 bundle。
ENV NUXT_PUBLIC_API_BASE_URL=${NUXT_PUBLIC_API_BASE_URL}
ENV NODE_OPTIONS=--max-old-space-size=2048

# nuxt.config.ts 讀 process.env.NUXT_SSR，所以三個模式在這裡分流。
RUN set -eux; \
    case "$FRONTEND_MODE" in \
      ssr)    npm run build ;; \
      spa)    NUXT_SSR=false npm run build ;; \
      static) NUXT_SSR=false npm run generate ;; \
      *)      echo "FRONTEND_MODE 只接受 ssr|spa|static" >&2; exit 1 ;; \
    esac

# 產出物斷言。build 靜默成功但沒有產出，是最難查的一種失敗。
RUN set -eux; \
    if [ "$FRONTEND_MODE" = "static" ]; then \
        test -d .output/public; \
    else \
        test -f .output/server/index.mjs; \
    fi

# ════════════════════════════════════════════════════════════════════════════
# prod —— Nitro（ssr / spa）
# ════════════════════════════════════════════════════════════════════════════
FROM ${NODE_IMAGE} AS prod

WORKDIR /app
COPY --from=build --chown=node:node /app/.output ./.output

ENV NODE_ENV=production \
    NITRO_HOST=0.0.0.0 \
    NITRO_PORT=3000

# Nitro 的 .output 是完全獨立的 bundle，不需要 node_modules。
USER node
EXPOSE 3000
CMD ["node", ".output/server/index.mjs"]

# ════════════════════════════════════════════════════════════════════════════
# static —— nginx 直送 .output/public
# ════════════════════════════════════════════════════════════════════════════
# 為什麼還是包一層 nginx 而不是把 .output/public 交給 edge：
# 這樣 edge 的設定在三個前端模式下完全一致（永遠 proxy_pass 到 nuxt:3000），
# 不需要在 edge 裡分「這個模式要 proxy、那個模式要 root」。
# 拓撲不變，也就少一個只有 static 模式才會踩到的坑。
# nosemgrep: dockerfile.security.missing-user.missing-user
# nginx 的 master 必須以 root 啟動才能 bind 並把 worker 降權成 nginx 使用者；
# 官方映像已經做好這件事，硬加 USER 反而會讓它起不來。
FROM ${NGINX_IMAGE} AS static

COPY --from=build /app/.output/public /usr/share/nginx/html
COPY docker/nuxt/static.conf /etc/nginx/conf.d/default.conf

EXPOSE 3000
