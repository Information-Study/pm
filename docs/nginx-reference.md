# Nginx 設定說明：Docker 與原生部署的對照

這份文件給誰看：**要改 nginx 設定的人**，以及**想知道「為什麼 Docker 上好好的，
上線就壞了」的人**。

本專案有**兩套** nginx 設定，服務同一個應用：

| | 位置 | 誰產生 |
|---|---|---|
| Docker | `docker/edge/`（+ `docker/php/` 裡 app 容器自己的那一份） | 版控裡的靜態檔 |
| 原生 | `ansible/roles/nginx_myguard/templates/*.j2` | Ansible 從變數渲染 |

**兩套必須表現一致。** 不一致的症狀永遠是同一種：某個路徑在一邊正常、在另一邊
404 或 413，而且看起來像「應用壞了」，不像「路由設錯了」。
本文件的第 2 節就是那張對照表。

---

## 1. 拓撲：請求會經過誰

### Docker（三個模式都一樣）

```
瀏覽器
  │
  ├─ (test 模式才有) waf 容器  ModSecurity + OWASP CRS，:8080
  │       └─ BACKEND=http://edge:8080
  │
  └─ edge 容器  nginx:1.30-alpine，:8080
        ├─ PHP 前綴  → upstream pm_php  → app 容器 :8080
        │                                   └─ app 容器內還有一層 nginx
        │                                      （docker/php/nginx.conf）→ php-fpm 127.0.0.1:9000
        └─ 其餘全部  → upstream pm_nuxt → nuxt 容器 :3000
```

⚠ **app 容器裡還有一層 nginx。** 這是很容易忽略的一層：`docker/edge` 只是反向代理，
真正把請求交給 php-fpm 的是 `docker/php/nginx.conf`。所以「PHP 收到的 body 上限」
是這兩層的**較小值**，不是 edge 那一層。

### 原生（Ansible）

```
瀏覽器
  └─ nginx（系統套件，MyGuard 的 apt repo）:80/:443
        ├─ ModSecurity 動態模組（同一個 nginx 行程內，不是另一台）
        ├─ PHP 前綴  → fastcgi_pass unix:<php_fpm_socket>
        └─ 其餘全部  → proxy_pass upstream <slug>_frontend → PM2 的 127.0.0.1:3000
```

**最重要的結構差異**：Docker 的 WAF 是**獨立容器**（只有 test 模式有），
原生的 ModSecurity 是**載進同一個 nginx 行程的動態模組**。
所以原生沒有「WAF 那一跳」，`X-Forwarded-For` 的層數也少一層。

---

## 2. 逐項對照

下表每一列都對照過實際檔案。**「一致」代表兩邊的行為相同**，不代表字面相同。

### 2.1 路由：哪些路徑交給 PHP

| | Docker | 原生 |
|---|---|---|
| 來源 | `docker/edge/conf.d/default.conf` | `nginx_php_prefixes`（`group_vars/all/main.yml`）→ `vhost.conf.j2` |
| 前綴 | `api admin sanctum up filament login logout broadcasting` | 同左 |
| 邊界 | `^/(…)(/|$)` 正規式 | `^/(…)(/|$)` 正規式 |
| Livewire | `^/livewire(-[0-9a-zA-Z]+)?/` | `nginx_php_prefix_patterns` 折進同一條正規式 |
| 靜態資產 | `/js/ /css/ /fonts/ /images/ /vendor/ /build/ /storage/`、`= /favicon.ico`、`= /robots.txt` | `^/(css|js|fonts|images)/`、`/storage/` |

> **2026-09-05 修正的兩個不一致：**
> Docker 側原本少了 `/filament`、`/login`、`/logout`、`/broadcasting` 四個前綴，
> 實測 `/login` 與 `/filament/assets/app.js` 都回 Nitro 的 404 —— 也就是被 catch-all
> 交給了 Nuxt。`/login` 與 `/logout` 是 Laravel 預設的 auth 路由名，
> `/broadcasting/auth` 是 Laravel Echo 的授權端點。
> 另外少了 `/images/`，那是 Filament 的 `asset('images/…')` 會用到的路徑。
>
> 同時把 `^~ /admin` 改掉：`^~` 是純前綴比對，會連 `/admino` 一起吃走，
> 而原生的 `(/|$)` 不會。**邊界也要對齊，不只是清單。**
>
> 這一族由 `cx verify cli` 的 **`A13-parity`** 守著：它從
> `group_vars` 的 `nginx_php_prefixes` 推導出應有的集合，再比對 `default.conf`。

**Livewire 的前綴不能寫死。** Livewire v4（Filament v5 的底層）的端點是
`/livewire-<8 碼 hash>/`，hash 由 `APP_KEY` 推導：

```
substr(sha256(config('app.key') . 'livewire-endpoint'), 0, 8)
```

每個部署都不同，`key:generate` 之後還會變。寫 `^~ /livewire/` 的話一條都比對不到，
後台的每一次互動都會 404，而瀏覽器 console 只會說 `livewire.js` 載不到。

### 2.2 大小與逾時

| 項目 | Docker | 原生 | 一致？ |
|---|---|---|---|
| `client_max_body_size`（edge） | `64m`（`docker/edge/nginx.conf`） | `nginx_client_max_body_size` = `app_max_upload_mb + app_upload_nginx_overhead_mb` = `48m` | **否，刻意** |
| `client_max_body_size`（app 內層） | `64m`（`docker/php/nginx.conf`） | n/a（原生只有一層） | — |
| WAF 請求 body 上限 | `MODSEC_REQ_BODY_LIMIT` = `67108864`（64MB） | `waf_request_body_limit` = `(app_max_upload_mb + app_upload_waf_overhead_mb) × 1MiB` | 一致（見下） |
| PHP 逾時 | `fastcgi_read_timeout 120s`（app 內層） | `nginx_fastcgi_read_timeout 70s` | **否** |
| 前端 proxy 逾時 | `proxy_read_timeout 300s` | `nginx_proxy_read_timeout 60s` | **否** |
| `gzip_min_length` | `256` | `256` | 一致（2026-09-05 對齊，原本 512） |

#### A16：大小的順序不可以反過來

```
PHP upload_max_filesize ≤ PHP post_max_size ≤ nginx client_max_body_size ≤ WAF body limit
```

順序反了的後果**不是報錯，是難以歸因的 413**：檔案先通過 nginx，再被
ModSecurity 以 `SecRequestBodyLimitAction Reject` 擋掉，而訊息只會指向 ModSecurity。

> 2026-09-05 實測到 Docker 側是反的：edge `64m`，而 WAF 只有 `13107200`（12.5MB）。
> 也就是 12.5–64MB 的上傳會過了 edge 才被 WAF 擋。原生側從 `app_max_upload_mb`
> 推導整條鏈並在 A16 明文要求這個順序 —— 兩條路徑對同一件事的規則不一致，
> 而 Docker 是錯的那一邊。現在由 `cx verify static` 的 **`A16`** 檢查跨檔比對。

> ⚠ **在目標機上 `nginx -T | grep client_max_body_size` 會看到兩個值。**
> 發行版自己的 `nginx.conf` 在 `http{}` 宣告了 `16m`，而本專案的 vhost 在
> `server{}` 宣告 `48m` —— 後者覆蓋前者，所以**實際生效的是 48m**。
> `00-pm-http.conf` 的註解也記著「nginx.conf 的 http{} 已宣告，此處跳過」。
> 實測（2026-09-05，目標機）：POST 一個 20MB 的 body 得到 **404**（路由不存在）
> 而不是 413 —— body 是被收下的。看到 `16m` 就以為上限是 16MB 是很容易犯的誤判。

**為什麼 `client_max_body_size` 兩邊不同是可以接受的**：Docker 的 `64m` 是寫死的
上限，原生的 `48m` 是從 `app_max_upload_mb`（32MB）推導的。真正要成立的是
**順序**，不是數字相等。要讓兩邊數字一致，改 `app_max_upload_mb` 即可 ——
那是設計上的單一來源。

**逾時為什麼不同**：Docker 的 `300s` 是為了 Vite HMR 與 dev 的長連線；
正式機不需要那麼寬。這是刻意的，但**如果你的應用有長時間請求，
要記得正式機只有 60s／70s**。

### 2.3 安全標頭

| 標頭 | Docker | 原生 | 一致？ |
|---|---|---|---|
| `X-Frame-Options` | `SAMEORIGIN` | `SAMEORIGIN` | ✔ |
| `X-Content-Type-Options` | `nosniff` | `nosniff` | ✔ |
| `Referrer-Policy` | `strict-origin-when-cross-origin` | 同左 | ✔ |
| `Permissions-Policy` | `camera=(), microphone=(), geolocation=(), payment=(), usb=()` | 同一組（順序不同） | ✔ |
| `Cross-Origin-Opener-Policy` | `same-origin` | `nginx_coop` | ✔ |
| `Cross-Origin-Embedder-Policy` | `credentialless` | `nginx_coep` | ✔（2026-09-05 補） |
| `Cross-Origin-Resource-Policy` | `same-origin` | `nginx_corp` | ✔（2026-09-05 補） |
| `Content-Security-Policy` | 完整政策 | `nginx_csp` | ✔（2026-09-05 補） |
| `Strict-Transport-Security` | 無 | 有（`tls_enable` + 真憑證才送） | **否，正確** |

> CSP、COEP、CORP 原本**只有 Docker 有**，原生側 `nginx_csp` 是空字串、
> COEP/CORP 連變數都沒有。那正好是反過來的 —— 正式機才是真的會被打的那一邊。
> 2026-09-05 補齊，實測兩邊回應的標頭現在逐字相同（除了 Permissions-Policy 的排序）。
>
> HSTS 只有原生有是**正確的**：Docker 的 edge 從不終結 TLS（它 listen 純 8080），
> 對 HTTP 送 HSTS 沒有意義。

#### A14：`add_header` 不會繼承

nginx 的規則是：**只要一個 `location` 裡出現任何 `add_header`，
它就完全不繼承外層的 `add_header`。** 少了這個認知，加一個 header 會安靜地
把該 location 的所有安全標頭拿掉。

兩邊用同一個辦法解決：把標頭做成一個片段，在**每一個**會加自己 header 的
location 裡重新 include 一次。

* Docker：`pm-security-headers.inc`，在 `/healthz`、`location /`、以及
  `pm-php.inc`（每一個 PHP location）各 include 一次
* 原生：`snippet-security-headers.conf.j2`，server 層 include 一次，
  再在 `/_nuxt/` 與 `/storage/` 這兩個有自己 `expires` 的 location 重新 include

### 2.4 靜態資產與快取

| | Docker | 原生 |
|---|---|---|
| 解析方式 | 一律 proxy 給 app 容器，由容器內的 `try_files $uri $uri/ /index.php` 決定 | `try_files $uri @frontend`，直接從磁碟讀 `backend/current/public` |
| `expires` | 未設（走 upstream 的回應） | `nginx_static_expires 30d`、`/storage/` `7d`、`/_nuxt/` `immutable` |

**這是刻意的拓撲差異**：Docker 的 edge 容器**看不到** backend 的 `public/` volume，
所以它沒有辦法 `try_files` —— 只能把請求交給看得到那顆 volume 的 app 容器。
原生的 nginx 與 PHP 在同一台，直接讀磁碟更快。

代價：**Docker 上量不到正式機的靜態快取行為**。要驗快取標頭請用原生路徑
（或 `cx deploy check`）。

### 2.5 upstream

| | Docker | 原生 |
|---|---|---|
| PHP | `upstream pm_php { server app:8080; keepalive 16; }` | `fastcgi_pass unix:<socket>` |
| 前端 | `upstream pm_nuxt { server nuxt:3000; keepalive 16; }` | `least_conn` + 每個 PM2 fork 一個 `server 127.0.0.1:<port> max_fails=3 fail_timeout=10s`，`keepalive 32` |

原生的前端 upstream 有多個成員（`frontend_instances` / `pm2_instances` 決定），
Docker 只有一個容器。**這代表 Docker 量不到負載分配與單一 fork 掛掉的行為。**

---

## 3. WAF（ModSecurity + OWASP CRS）

### 3.1 兩邊的 CRS 大版本要一樣

| | 來源 | 版本 |
|---|---|---|
| Docker | `WAF_IMAGE`（`docker/compose/test.yml`） | 釘在 `4.28.0-nginx-alpine-…` |
| 原生 | MyGuard 的 apt repo | 目前 `4.30.0` |

> ⚠ 2026-09-05 之前 Docker 用的是 `owasp/modsecurity-crs:nginx-alpine` ——
> 那個 tag **完全沒有版本成分**，而它當時指向的是 **CRS 3.3.10**。
> 也就是說 Docker 側量到的 WAF 行為，跟實際上線的不是同一個大版本，
> 而 `docker/waf/.../main.conf` 從一開始就是照 CRS 4 寫的。
> 現在由 `cx verify static` 的 **`4b`** 檢查拒絕無版本／`latest` 的 tag。

### 3.2 載入順序是這件事唯一重要的東西

```
(1) 引擎設定（SecRuleEngine / body 上限 / 稽核）
(2) crs-setup.conf          ← tx.* 變數，必須在 CRS 之前
(3) exclusions-before/*.conf ← ctl:ruleRemoveByTag / ruleRemoveById 放這裡
(4) CRS 本體
(5) exclusions-after/*.conf  ← SecRuleUpdateTargetById 放這裡
```

**為什麼 (3) 一定要在 (4) 之前**：`ctl:ruleRemoveById` 只影響「同一個 phase 中
**尚未執行**」的規則。載在 CRS 之後等於什麼都沒做，**而且不會有任何錯誤訊息**。
反過來 `SecRuleUpdateTargetById` 是**載入期**指令，引用的規則必須已經存在，
所以只能放 (5)；放到 (3) 會讓 nginx 直接起不來。

另外：多個 `ctl:` 之間是**逗號**不是分號。分號會讓 ModSecurity 拒絕載入整份設定、
nginx 以 emerg 起不來，而錯誤訊息只會說 `Rules error`。

### 3.3 排除規則依 tag 而不是逐條列 ID

```
SecRule REQUEST_URI "@rx ^/livewire(-[0-9a-zA-Z]+)?/" \
    "id:10011,phase:2,pass,nolog,ctl:ruleRemoveByTag=attack-sqli,ctl:ruleRemoveByTag=attack-xss"
```

逐條列 ID 在這裡是**結構性錯誤**：兩條路徑本來就跑不同版的 CRS，
而 CRS 每次改版都會新增規則。2026-09-05 一天之內被咬兩次 ——
先是 CRS 4 才有的 `941390`（Javascript method detected），補上之後原生的 4.30
又冒出 `942550`（JSON-Based SQL Injection）。兩次的症狀都一樣：**後台的每一次
互動被擋成 403，而 audit log 只會指向 CRS 規則，不會說「你的排除清單少了一條」。**

範圍沒有變寬：原本列的 941/942 就是 `attack-xss` 與 `attack-sqli` 這兩個家族，
只是列不齊。**這兩條路徑之外的攻擊面完全沒有放寬** —— 主動探測打的是 `/`。

### 3.4 怎麼量 WAF 有沒有在做事

**不要用 ZAP baseline 的差異去量。** `zap-baseline.py` 是**被動**掃描，
它爬站、檢查回應標頭，不送任何攻擊 payload。拿 DetectionOnly 與 Blocking
兩份報告去比對，兩邊必然一樣，結論永遠是「WAF 擋下 0 項」——
那個數字不是「WAF 沒用」，是量錯了東西。

用 `bin/lib/waf_probe.py`（`cx scan dast` 會跑）：它真的送請求，並比較兩個引擎
模式下的狀態碼。它量**兩件事**：

| | 期望 |
|---|---|
| 攻擊請求（SQLi / XSS / traversal / cmd injection） | Blocking 模式下 403 |
| **正常請求**（含帶 body 的 Livewire POST） | 兩個模式都通過 |

**第二項比第一項更重要。** 正常請求在 Blocking 模式下被擋，代表排除規則沒生效
—— 那才是上線之後真正會痛的失敗模式。攻擊全擋 100% 與後台完全不能用，
是可以同時成立的。

最近一次實測（2026-09-05，引擎切到 `On`）：

| | Docker（CRS 4.28） | 原生（CRS 4.30） |
|---|---|---|
| 6 項攻擊 | 全部 403 | 全部 403 |
| 正常 Livewire POST | 通過 | 419（Laravel 自己擋 CSRF token —— 代表**過了 WAF**） |
| `/admin/login`、`/` | 通過 | 200 / 200 |

---

## 4. 改設定的時候要記得什麼

1. **改一邊就要改另一邊。** 路由前綴由 `A13-parity` 守著，上傳大小由 `A16` 守著，
   其餘目前靠這份文件。
2. **改完跑 `nginx -t`。** Docker：`cx <模式> dc exec edge nginx -t`；
   原生：role 的 handler 會先 `nginx -t` 再 reload，失敗就不會套用。
3. **加了 `add_header` 就要重新 include 安全標頭片段**（A14）。
4. **動到 WAF 的排除規則，要跑主動探測**，而且要看「正常請求」那一組。
5. **原生側的變數改在 `group_vars`，不要改 role 的 `defaults`** ——
   後者是給 role 單獨使用時的備援，會被前者蓋掉。

### 常用指令

```bash
# Docker：看合併後實際載入的設定
cx dev dc exec edge nginx -T | less
cx dev dc exec edge nginx -t

# 原生：看目標機上實際載入的設定（不加 -c，A12）
cx deploy apply staging --tags nginx
ansible -i ansible/inventory/hosts.yml staging -b -m command -a 'nginx -T'

# WAF 主動探測（需要 test 堆疊起著）
cx test up -d
cx scan dast
```

---

## 5. 已知的、刻意保留的差異

| 差異 | 為什麼不修 |
|---|---|
| Docker 沒有 HSTS | edge 不終結 TLS，對 HTTP 送 HSTS 沒有意義 |
| Docker 靜態資產不從磁碟讀 | edge 容器看不到 backend 的 `public/` volume |
| Docker 沒有 rate limit / conn limit | 那是對外那一層的事；Docker 的 edge 不對外 |
| Docker 前端 upstream 只有一個成員 | 一個 nuxt 容器；原生是多個 PM2 fork |
| `client_max_body_size` 64m vs 48m | 要成立的是**順序**不是數字；改 `app_max_upload_mb` 就會一致 |
| 逾時 300s vs 60s | Docker 那組是為了 dev 的 HMR |

**其餘任何差異都應該視為缺陷。** 發現的話請一併補上對應的跨檔檢查 ——
這個專案已知的缺陷有一半以上不是「程式寫錯」，而是兩個地方對同一件事的說法
不一致，而且沒有任何東西在盯著。
