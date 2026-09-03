# 轉給 app 容器的共用片段。被 default.conf 的多個 location include。
#
# 為什麼拆成片段而不是複製七次：nginx 的 add_header 繼承規則是
# 「當前層有 add_header 就完全不繼承上層」，所以每個 location 都必須
# 自己帶齊所有 header。拆片段是唯一不會漏的做法。
proxy_pass http://pm_php;
proxy_http_version 1.1;
# nosemgrep: nginx.security.request-host-used.request-host-used
# 轉發 $host 是反向代理的標準作法，這裡是刻意的：
#   * edge 是唯一入口，容器內的 app / nuxt 都沒有對外發布埠
#   * Laravel 端已設定 TrustProxies（backend/bootstrap/app.php），
#     而且 APP_URL / SANCTUM_STATEFUL_DOMAINS 都是明確值
#   * 真正要收緊 Host 的地方是最前面那一層：Ansible 的 nginx_myguard
#     有真實的 server_name（來自 app_domain），不吃未知的 Host
# 改成寫死 Host 會讓同一份設定無法在 dev(8080) / test(18081) / prod(80) 共用。
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host  $host;
proxy_set_header X-Forwarded-Port  $server_port;
proxy_set_header Connection        "";
proxy_read_timeout 300s;
proxy_send_timeout 300s;
proxy_buffer_size 16k;
proxy_buffers 8 16k;

# 安全標頭。nginx 的 add_header 不會繼承 —— 每個 location 都要自己帶。
include /etc/nginx/conf.d/pm-security-headers.inc;
