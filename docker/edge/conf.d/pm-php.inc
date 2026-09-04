# 轉給 app 容器的共用片段。被 default.conf 的多個 location include。
#
# 為什麼拆成片段而不是複製十幾次：nginx 的 add_header 繼承規則是
# 「當前層有 add_header 就完全不繼承上層」，所以每個 location 都必須
# 自己帶齊所有 header。拆片段是唯一不會漏的做法。
proxy_pass http://pm_php;
proxy_http_version 1.1;
# nosemgrep: nginx.security.request-host-used.request-host-used
# 見 default.conf 中同一組 header 的說明：edge 是唯一入口，
# Laravel 端有 TrustProxies，真正收緊 Host 的是最前面那一層。
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host  $host;

# ⚠ 不能用 $server_port。
#
# $server_port 是「edge 自己監聽的埠」= 8080，不是使用者連進來的埠。
# dev 剛好也發布 8080，所以看起來是對的；但 test 發布 18080、
# WAF 發布 18081、prod 發布 80 —— 三者都會讓 Laravel 以為自己在 8080。
# 2026-09-04 實測：從 18080 / 18081 / 80 打 /admin，302 全部指向
#   http://localhost:8080/admin/login
# 而 prod 根本沒有發布 8080，使用者會被導到一個連不上的網址。
# 同樣的錯誤也會出現在密碼重設信、Filament 的絕對連結、分頁連結上。
#
# 正確來源是使用者送來的 Host 標頭裡的埠（nginx.conf 的 map 解析）。
# Host 沒帶埠時（80/443 的預設情形）退回 $server_port。
proxy_set_header X-Forwarded-Port  $pm_forwarded_port;

proxy_set_header Connection        "";
proxy_read_timeout 300s;
proxy_send_timeout 300s;
proxy_buffer_size 16k;
proxy_buffers 8 16k;

# 安全標頭。nginx 的 add_header 不會繼承 —— 每個 location 都要自己帶。
include /etc/nginx/conf.d/pm-security-headers.inc;
