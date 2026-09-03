# pm 原生部署指南（Ansible）

把 `pm` 部署到一台**全新的 Ubuntu/Debian 機器**上，不使用 Docker。
一次 `ansible-playbook site.yml` 從空機器到可服務。

> ⚠ **本目錄的所有內容從未在真實主機上執行過。**
> 本機裝不了 ansible（無 pip、sudo 需密碼），連 `--syntax-check` 都跑不了。
> 目前只做過替代性靜態檢查（`cx lint`：114 個 YAML 全部剖析成功、無語法錯誤、
> 無 `git push`、無未 gate 的破壞性操作）。
> 未驗證項目的完整清單見專案根目錄 `claude.md` §12.5。
> **第一次部署請務必先對 staging 跑 `--check --diff`。**

---

## 1. 這套東西會做什麼

| 層 | 內容 |
|---|---|
| 系統 | 時區 Asia/Taipei、locale、deploy 使用者、完整目錄骨架、日誌目錄、（選用）swap / unattended-upgrades |
| PHP | 8.5-FPM（Ubuntu 走 ondrej PPA、Debian 走 sury）、opcache + JIT、pool 依 CPU/記憶體調校 |
| Composer | 從 GitHub release 取 phar 並校驗 |
| 資料庫 | MySQL 8.4 LTS（Oracle repo，鎖系列）、utf8mb4、備份 cron |
| Node | Node 24 LTS（NodeSource）+ PM2（systemd） |
| Web | MyGuard 版 Nginx + ModSecurity + OWASP CRS |
| TLS | Let's Encrypt（webroot 模式）+ systemd timer 自動續期 |
| 應用 | backend / frontend 各自 `releases/` + `shared/` + `current` symlink |
| 收尾 | healthcheck、（選用）ufw / fail2ban / sshd 強化 |

---

## 2. 快速開始

```bash
# ── 控制端（你的電腦，不是目標主機）──
sudo apt install -y ansible-core            # 需要 ansible-core >= 2.17
cd ansible
ansible-galaxy collection install -r requirements.yml

# ── 準備 inventory ──
cp inventory/hosts.yml.example inventory/hosts.yml
$EDITOR inventory/hosts.yml                  # 填入主機位址
cp inventory/group_vars/staging.yml.example inventory/group_vars/staging.yml
$EDITOR inventory/group_vars/staging.yml     # 至少要填 app_domain

# ── 祕密（絕不進版控，.gitignore 已擋）──
ansible-vault create inventory/group_vars/vault.yml
#   vault_mysql_root_password: <強密碼>
#   vault_mysql_app_password:  <強密碼>
#   vault_app_key:             <留空，第一次部署會自動產生>

# ── 連通性 ──
ssh-keyscan -H <目標主機> >> ~/.ssh/known_hosts   # ansible.cfg 沒有關掉 host key 檢查
ansible -i inventory/hosts.yml pm_servers -m ping

# ── 先試跑，不要直接來真的 ──
ansible-playbook -i inventory/hosts.yml site.yml --check --diff --limit staging

# ── 正式部署 ──
ansible-playbook -i inventory/hosts.yml site.yml --limit staging
```

> **一律在 `ansible/` 目錄底下執行。** `ansible.cfg` 的相對路徑
> （`./roles`、`./inventory`、`./collections`）以本檔所在目錄為基準。

---

## 3. 部署流程與原理

`site.yml` 有四個 play，依序執行：

### Play 1 — 產生 release_id（在控制端）

```
hosts: localhost
```
用控制端的時間產生一次 `YYYYMMDD-HHMMSS`，再分發給所有目標主機。

**為什麼要在控制端算**：如果讓每台主機各自 `date`，多台部署時會拿到不同的
release_id，`current` symlink 指向的目錄名就對不起來，rollback 時無從對照。

### Play 2 — preflight（全部主機都通過才開始動手）

```
any_errors_fatal: true
```
只做斷言、不改變任何狀態，目標是**5 秒內失敗**。檢查：

- ansible-core ≥ 2.17（`deb822_repository` 需要 2.15，`systemd_service` 需要 2.17）
- 發行版在支援矩陣內；Debian 需 `mysql_repo_source=oracle`（見 §5.3）
- `app_domain` 已填且不是佔位值
- `app_root` 不在系統目錄黑名單內、深度至少 2 層（release prune 的最上層防線）
- A16 上傳限制的推導鏈數值遞增正確
- `groups['db_primary']` 至多一台（A15）
- 磁碟 ≥ 5 GB、記憶體 + swap ≥ 1.8 GB（Nuxt build 尖峰約 1.5 GB）

**為什麼 `any_errors_fatal: true`**：preflight 是「先看清楚再動手」。
一台不合格就全部停下，比部署到一半才發現好。

接著是**編排斷言**，這幾條是對抗驗證抓出來的：
- `db_primary` 必須同時在 web 群組裡，否則 migration 永遠不會跑（A15）
- `pm2_instances` 必須等於 `frontend_instances`，否則 nginx upstream 會指向不存在的埠（A10）
- `tls_enable` 為真時 `certbot_email` 必填 —— 在這裡擋，不要等跑到 certbot role 才失敗

### Play 3 — 系統層與應用層部署

Role 順序是有意義的，不可調換：

```
common → php → composer → mysql → nodejs_pm2
       → nginx_myguard → certbot
       → deploy_backend → deploy_frontend → healthcheck → hardening
```

**為什麼 nginx 在 certbot 之前**：certbot 用 webroot 模式，需要 nginx 已經在服務
`:80` 的 `/.well-known/acme-challenge/`。standalone 模式會撞埠。

**為什麼 hardening 在最後**：ufw 一開，如果規則沒算對就可能把自己鎖在門外。
放最後至少前面的東西都裝好了。

### Play 4 — TLS 收尾檢查

用 `nginx -T`（dump 實際載入的設定，不加 `-c`）確認 nginx 真的在用正式憑證，
而不是還停在 snakeoil。詳見 §4。

---

## 4. Nginx + PM2 的整合機制

### 為什麼需要一個反向代理

前端和後端是兩個不同的東西：

- **後端** Laravel 走 PHP-FPM，透過 unix socket
- **前端** Nuxt 依 `frontend_mode` 而定：Node 程序（`ssr`/`spa`）或純靜態檔（`static`）

Nginx 把它們縫成**單一來源（same-origin）**。這一點很重要 ——
同源之後 `NUXT_PUBLIC_API_BASE_URL` 可以留空，前端不需要處理 CORS 與 cookie 的跨源問題。
Docker 環境的 `edge` service 做的是同一件事，兩邊拓撲刻意保持一致。

### 路由順序（A13）

vhost 的 location 順序**不是風格問題**：

```nginx
# 1. Laravel public 底下實際存在的檔案優先
location ~ ^/(css|js|fonts|images)/ { try_files $uri @frontend; expires 30d; }
location = /favicon.ico { try_files $uri @frontend; }
location = /robots.txt  { try_files $uri @frontend; }

# 2. 後端路徑
location ~ ^/(api|admin|livewire|up|filament|sanctum|broadcasting|storage)(/|$) { ... }

# 3. 其餘一律交給前端
location / { ... @frontend ... }
```

**為什麼不能寫成 `^/(css|js|images)/filament/`**：Filament 的面板 logo 用
`asset('images/pwg-badge.png')`，路徑裡**沒有** `filament/` 這一段。
寫成那樣的話 `/images/pwg-badge.png` 不會匹配，會被代理到 Nuxt → 404 破圖。

### 安全標頭與 snippet（A14）

nginx 的 `add_header` 繼承規則很容易踩雷：
**只要當前 location 有任何 `add_header`，就完全不繼承上層的。**

所以 `/storage/` 與 `/_nuxt/` 這種自己加 `Cache-Control` 的 location，
如果不做處理，就會**沒有** HSTS、`X-Content-Type-Options`、CSP —— 而且完全無聲。
（然後你自己的 ZAP 掃描會把它報成漏洞，你還會以為是誤判。）

這就是 template 拆成 snippet 的理由：

```nginx
location ^~ /storage/ {
    include {{ nginx_snippet_security_headers }};   # ← 必須重新 include
    add_header Cache-Control "public" always;
    expires 7d;
}
```

### PM2 為什麼是 fork 而不是 cluster

**PM2 的 cluster 模式載不動 Nuxt 的 ESM 進入點。**
cluster 透過 CJS 的 `ProcessContainer` 用 `require()` 載入 `.output/server/index.mjs`，
會得到 `ERR_REQUIRE_ESM`。Node 24 上就算 `require(esm)` 過了，
Nitro 產物裡的 top-level await 又會變成 `ERR_REQUIRE_ASYNC_MODULE`。
上游 pm2#5946、nuxt#13916 都還沒解。

所以要水平擴充就開 **N 個獨立的 fork**，每個綁自己的埠：

```nginx
upstream pm_frontend {
    least_conn;
    server 127.0.0.1:3000;
    server 127.0.0.1:3001;
    keepalive 32;
}
```

`frontend_instances` 與 `pm2_instances` 必須相等 —— preflight 會擋。
另外 `instances` 絕不能用 `'max'`：PM2 會去讀 `os.cpus().length`，在容器或
cgroup 限制下會讀到宿主機的核心數。

### TLS 的先有雞先有蛋（A5）

nginx role 跑在 certbot **之前**，但 vhost 需要引用憑證檔。
第一次部署時 `/etc/letsencrypt/live/<domain>/fullchain.pem` **還不存在** →
`nginx -t` 會 emerg → `any_errors_fatal` 讓 certbot 永遠跑不到 → 死鎖。

解法是兩段式：

1. `nginx_myguard/tasks/facts.yml` 用 `stat` 判斷正式憑證是否存在。
   不存在就用 `ssl-cert` 套件的 snakeoil 自簽憑證，讓 nginx 起得來。
2. certbot 簽發成功後 notify handler，重新渲染 vhost 換成正式憑證，
   `nginx -t` 通過才 reload。

Play 4 會再用 `nginx -T` 確認一次。如果停在「憑證有了但 nginx 還在用 snakeoil」
（例如憑證是上一次跑就簽好的、本次沒有 changed 所以 handler 沒觸發），
它會印出可行動的提示：`ansible-playbook site.yml --tags nginx`。

### 為什麼所有片段都不加 `validate:`（A12）

`validate: nginx -t -c %s` **不能用來驗證 vhost 片段**。
`-c` 會把該檔當成**完整的主設定**，而片段裡沒有 `events {}` 區塊，
所以一個完全正確的 vhost 也會驗證失敗，template 任務永遠寫不進去。

正確做法：片段模板一律不加 `validate:`，最後跑**一次** `nginx -t`（不帶 `-c`），
它會讀 `/etc/nginx/nginx.conf` 並看到片段在真實的上下文裡。

---

## 5. MyGuard APT 與 ModSecurity

### 5.1 為什麼用 MyGuard

Ubuntu/Debian 官方的 nginx 沒有 ModSecurity 動態模組。MyGuard
（<https://deb.myguard.nl/>）提供帶模組的建置。

```bash
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://deb.myguard.nl/deb.myguard.nl.gpg \
  | tee /etc/apt/keyrings/deb.myguard.nl.gpg >/dev/null
CODENAME=$(lsb_release -cs)
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/deb.myguard.nl.gpg] \
https://deb.myguard.nl/apt/dists/$CODENAME $CODENAME main" \
  > /etc/apt/sources.list.d/deb.myguard.nl.list
```

### 5.2 套件名歧異 —— 這是本專案最不確定的一塊

MyGuard 的文件與站台描述**不一致**：
- 一組說法：`libnginx-mod-http-modsecurity` + `libmodsecurity3` + `modsecurity-crs`
- 另一組（較新）：`libnginx-mod-http-coraza`（Coraza WAF，宣稱 libmodsecurity 相容、CRS-ready）

再加上發行版差異（noble 的是 `libmodsecurity3t64`、部分版本把 CRS 改名 `coreruleset`），
**寫死任何一組名稱都會在某些平台上失敗**。

所以 `roles/nginx_myguard/tasks/packages.yml` 的做法是：

1. 對 `waf_packages` 的每個「角色」，用 `apt-cache policy` **真的探測**
2. 主要名稱沒有候選版本，就依 `waf_packages_alternates` 對照表往下試
3. 全部落空才 `fail`，而且訊息裡附上這台機器 `apt-cache search` 的**實際輸出**，
   以及三個可行選項（覆寫變數 / 改用發行版套件 / 暫時 `waf_enabled=false`）

> ⚠ 這段探測邏輯**本身也從未在真實機器上跑過**。第一次部署時請留意它的輸出。

### 5.3 CRS 排除規則的載入順序（A11）

**`ctl:ruleRemoveById` 只影響同一個 phase 裡「尚未執行」的規則。**
規則按檔案載入順序執行，所以排除規則載在 CRS **之後**等於完全沒寫 ——
Livewire/Filament 的流量照樣被 941xxx/942xxx 擋掉，而且毫無線索。

正確順序（`waf-main.conf.j2` 是唯一來源）：

```
Include /etc/nginx/waf/exclusions-before/*.conf   ← ctl:ruleRemoveById 放這裡
Include <CRS 主檔>
Include /etc/nginx/waf/exclusions-after/*.conf    ← SecRuleUpdateTargetById 放這裡
```

另外：**多個 `ctl:` 之間用逗號，不是分號。**
分號會讓 ModSecurity 拒絕載入設定，nginx 直接起不來。

```
SecRule REQUEST_URI "@beginsWith /livewire/" \
    "id:1000101,phase:1,pass,nolog,\
     ctl:ruleRemoveById=920420,ctl:ruleRemoveById=942100"
```

### 5.4 上傳限制的四個值（A16）

四個值必須遞增，否則會出現「過了 nginx 和 PHP 才被 WAF 擋掉」的靜默 413：

```
php_upload_max_filesize (32M)
  ≤ php_post_max_size (40M)
    ≤ nginx_client_max_body_size (48m)
      < waf_request_body_limit (64MiB)
```

**唯一來源是 `inventory/group_vars/all.yml` 的 `app_max_upload_mb`**，
其餘三個由它推導。preflight 會驗證遞增關係。

> 這裡曾經出過事：`app_max_upload_mb` 在 5 個 role defaults 各有一份，
> 其中 php 是 64、其他是 32。有 inventory 時看不出來（group_vars 優先權較高），
> 一旦沒帶 inventory 就會靜默產生 413。現在正本統一在 group_vars，
> role defaults 只留一致的 fallback 並加了警語。

---

## 6. 前端三模式

用 `frontend_mode` 選擇，**部署時才決定**：

| 模式 | 建置 | 執行 | Nginx | API base URL 決定時機 |
|---|---|---|---|---|
| `ssr` | `nuxt build` | PM2 fork 跑 `.output/server/index.mjs` | 反代 upstream | **啟動時**（環境變數） |
| `spa` | `NUXT_SSR=false nuxt build` | PM2 fork 跑 Nitro | 反代 upstream | **build 時**（烘進 bundle） |
| `static` | `NUXT_SSR=false nuxt generate` | **不用 PM2** | `root .output/public` 直送 | **build 時**（烘進 bundle） |

**`spa` 與 `static` 的 API base URL 是 build 時烘進 bundle 的**，
不是啟動時讀環境變數。所以改了 `NUXT_PUBLIC_API_BASE_URL` 必須**重新 build**，
只重啟 PM2 沒有用。`deploy_frontend` 會在建置後 grep `.output/public/_nuxt/`
驗證烘進去的值是否正確。

切換模式時 `nodejs_pm2` 會清掉前一個模式留下的 PM2 程序
（`static` 模式不該有任何 PM2 程序在跑）。

三種模式都已在本機**實測建置通過**（見 `claude.md` §0.5）。
但「PM2 實際跑起來」從未驗證過。

---

## 7. 部署後的操作

```bash
# 只重新部署應用（跳過系統層，快很多）
ansible-playbook -i inventory/hosts.yml playbooks/deploy-only.yml

# 回滾到指定的 release
ansible-playbook -i inventory/hosts.yml playbooks/rollback.yml \
  -e rollback_to=20260903-143000

# 只跑某一層
ansible-playbook -i inventory/hosts.yml site.yml --tags nginx
ansible-playbook -i inventory/hosts.yml site.yml --tags certbot

# 看會改什麼但不真的改
ansible-playbook -i inventory/hosts.yml site.yml --check --diff
```

### releases 佈局

```
/srv/pm/backend/
├── releases/
│   ├── 20260903-120000/
│   └── 20260903-143000/     ← 新的
├── shared/
│   ├── .env                 ← 憑證放這裡，不隨 release 更換
│   └── storage/             ← 上傳的檔案
└── current -> releases/20260903-143000
```

`current` symlink 是**最後一步**才切換（先建臨時 symlink 再 `mv -T`，保證原子性）。

**release prune 不會刪掉 `current` 指向的目錄。**
用 `find` + `stat` 解析實體路徑再 `reject`，而不是靠 `ls -1dt` 的排序 ——
後者在 rollback 之後會把正在服務的版本排到後面而刪掉它。
`releases_prune` 預設開啟，`releases_keep` 預設 5。

---

## 8. 變數參考

完整清單在 `inventory/group_vars/all.yml`（193 個變數，含註解）。
下面是**你最可能需要改的**：

### 必填

| 變數 | 說明 |
|---|---|
| `app_domain` | 網站網域。preflight 會擋掉佔位值 |
| `certbot_email` | Let's Encrypt 到期通知信箱。90 天效期 + timer 靜默失敗時，這封信是唯一會發現的管道 |
| `vault_mysql_root_password` | 放在 vault 裡 |
| `vault_mysql_app_password` | 放在 vault 裡 |

### 常改

| 變數 | 預設 | 說明 |
|---|---|---|
| `frontend_mode` | `ssr` | `ssr` / `spa` / `static` |
| `frontend_instances` | `1` | PM2 fork 數；必須等於 `pm2_instances` |
| `app_max_upload_mb` | `32` | 上傳上限的**唯一來源**，其他三個值由它推導 |
| `releases_keep` | `5` | 保留幾個 release |
| `tls_enable` | `true` | 關掉的話整個 certbot role 乾淨跳過 |
| `certbot_staging` | `false` | 先用 staging 把流程跑通，不吃正式 rate limit |
| `mysql_repo_source` | `oracle` | Debian 一定要 `oracle`（發行版的是 MariaDB） |
| `waf_enabled` | `true` | WAF 套件解析不出來時可先關掉讓 nginx 上線 |
| `waf_mode` | `DetectionOnly` | 先觀察再改 `On`。直接上 `On` 很可能誤擋 Filament |

### 預設關閉（要用再開）

| 變數 | 說明 |
|---|---|
| `mysql_drop_test_db` | 刪除 `test` schema。三重 gate：變數、schema 存在、table 數為 0 |
| `certbot_force_renewal` | 強制重簽。**最容易把 rate limit 用完的動作** |
| `certbot_renew_dry_run` | 部署時跑一次續期演練 |
| `hardening_ufw_enabled` / `hardening_fail2ban_enabled` | 防火牆與封鎖 |

---

## 9. 疑難排解

| 症狀 | 原因與處理 |
|---|---|
| `couldn't resolve module/action 'community.mysql.mysql_user'` | collection 沒裝或 `collections_path` 被覆蓋。`ansible-galaxy collection install -r requirements.yml` |
| `Failed to import the required Python library (python3-debian)` | 目標機缺 `python3-debian`。`common` role 會裝，但你如果跳過了 common 就會遇到 |
| `composer install` 死在 `The Process class relies on proc_open` | `disable_functions` 含了 `proc_open`。本專案的 `composer.json` 有 `post-autoload-dump` 腳本，需要它。預設已排除，檢查有沒有被覆寫 |
| `SQLSTATE[HY000] [1045] Access denied for user 'pm'@'localhost'` | `skip-name-resolve` 下 MySQL 不做反解，`DB_HOST=127.0.0.1` 比對的是字面 `127.0.0.1`。grant 要同時建兩個 host —— `mysql` role 預設會做 |
| `E: Unable to locate package mysql-server` | 在 Debian 上用了發行版來源。設 `mysql_repo_source=oracle` |
| `nginx: [emerg] cannot load certificate` | A5 的死鎖。確認 `ssl-cert` 有裝、`facts.yml` 有正確 fallback 到 snakeoil |
| `ERROR: FPM initialization failed` + `Unable to create or open slowlog` | `/var/log/php` 不存在。缺 slowlog 目錄對 FPM 是**硬錯誤**，不是警告 |
| PM2 顯示 `errored`，log 是 `ERR_REQUIRE_ESM` | `exec_mode` 被改成 `cluster` 了。必須是 `fork` |
| Filament 面板 logo 破圖 | vhost 的 asset location 寫成 `^/(css\|js\|images)/filament/`。見 §4 |
| ZAP 報 `/storage/` 缺安全標頭 | A14。那個 location 自己加了 `add_header` 卻沒重新 include snippet |
| 26–32 MB 的上傳莫名 413 | A16 的四個值沒有遞增。檢查 `waf_request_body_limit` |
| Livewire/Filament 被 WAF 擋 | A11 的載入順序，或 `ctl:` 之間用了分號 |
| certbot 失敗 | `issue.yml` 會把 DNS / 80 埠 / rate limit 三種原因分類並用 ★ 標出命中的那條 |

---

## 10. 給接手者

**這套東西沒有在真機上跑過。** 第一次部署請按這個順序：

1. `cd ansible && ansible-playbook site.yml --syntax-check`
2. `ansible-lint ansible/`，與 `cx lint` 的結果對帳
3. 對 staging `--check --diff`，逐一看 diff
4. 設 `certbot_staging=true` 先把 TLS 流程跑通
5. 設 `waf_mode=DetectionOnly` 先觀察 CRS 會擋掉什麼，
   把誤擋的規則加進 `exclusions-before`，確認乾淨了再改 `On`
6. 真的部署

驗證完的項目請回填到根目錄 `claude.md` §12.5，
並註明驗證日期與方式。**不要只因為程式碼看起來對就標成已驗證。**
