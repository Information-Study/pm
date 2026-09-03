# ── 安全標頭 ────────────────────────────────────────────────────────────────
#
# ⚠ 這個檔必須被**每一個** location 各自 include 一次。
#
# nginx 的 add_header 繼承規則是：「當前層只要有任何一個 add_header，
# 就完全不繼承上層的 add_header」——不是合併，是整組丟掉。
# 所以在 server 層寫一次是不夠的：任何一個有自己 add_header 的 location
# 都會把整組安全標頭弄丟，而且不會有任何警告。
# 拆成片段、每個 location 都 include，是唯一不會漏的做法。
#
# 這一組與 ansible/roles/nginx_myguard/templates/snippet-security-headers.conf.j2
# 刻意保持一致 —— Docker 與原生部署的行為必須相同，否則在容器裡測過的東西
# 上真機會有不同表現。
#
# 這些標頭是 2026-09-04 的 ZAP baseline 掃描找出來的：
# 當時 edge 一個安全標頭都沒有，10 個 alert 裡有 6 個是這一類。

# 點擊劫持。CSP 的 frame-ancestors 是現代作法，X-Frame-Options 給舊瀏覽器。
add_header X-Frame-Options "SAMEORIGIN" always;

# 禁止瀏覽器用內容嗅探去猜 MIME type（會把上傳的檔案當成 script 執行）。
add_header X-Content-Type-Options "nosniff" always;

# Referer 只在同源時送完整路徑，跨源只送 origin。
add_header Referrer-Policy "strict-origin-when-cross-origin" always;

# 關閉不需要的瀏覽器功能。
add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=()" always;

# 跨源隔離。COEP 用 credentialless 而不是 require-corp ——
# require-corp 會擋掉沒有標註 CORP 的第三方資源（例如 CDN 上的字型）。
add_header Cross-Origin-Opener-Policy "same-origin" always;
add_header Cross-Origin-Embedder-Policy "credentialless" always;
add_header Cross-Origin-Resource-Policy "same-origin" always;

# CSP。
# 'unsafe-inline' 與 'unsafe-eval' 是 Nuxt 與 Filament（Livewire/Alpine）目前的需求：
#   * Nuxt 會 inline 一段 hydration payload
#   * Alpine.js 用 new Function() 求值 x-on / x-data
# 要收緊必須先在應用層導入 nonce，那是應用的工作不是 edge 的。
# 這裡先給一個「有比沒有好」的基準，並明確記下為什麼還不能更嚴。
add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self'; base-uri 'self'; form-action 'self'; object-src 'none'" always;

# 不要把後端用什麼寫的告訴全世界。
# php.ini 已經 expose_php=Off、app 的 nginx 也有 fastcgi_hide_header，
# 但 Nitro（Nuxt）自己會送 X-Powered-By，所以 edge 這一層要再擋一次。
proxy_hide_header X-Powered-By;
proxy_hide_header X-AspNet-Version;
# server_tokens off 已在 nginx.conf 設定，Server 標頭只會剩下 "nginx"。
# 要完全移除需要 headers-more 模組，官方映像沒有編進去。
