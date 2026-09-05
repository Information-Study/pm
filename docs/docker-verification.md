# Docker 設定驗證需求

> 對象：負責 Docker 驗證的對話 / 人員
> 專案：`pm`（本機 `~/pm`）
> 前置閱讀：根目錄 `claude.md` §0 紅線、§4 Docker 三模式、§5 DevSecOps

---

## 0. 背景

本專案的 Docker 設定經過一輪 10-agent 的設計與對抗驗證。**設計被判定為 `has_blocking_flaws`**，
下列項目是驗證者實際追出失敗路徑後提出的修正。**本文件不是建議清單，是必須逐項確認的驗收條件。**

舊的設定檔已保留在 `env/docker/legacy/`：

| 檔案 | 說明 |
|---|---|
| `env/docker/legacy/docker-compose.yml.orig` | 原始 compose（8 個 service，無模式區分） |
| `env/docker/legacy/dockerignore.orig` | 原始 .dockerignore |
| `env/docker/legacy/init.sh.orig` / `refresh.sh.orig` | 原始初始化腳本（已知壞掉） |
| `env/docker/legacy/README.md.orig` | 原始 README |
| `env/docker/php/*` | 原始 PHP 容器設定（nginx.conf、supervisord.conf、xdebug.ini 等） |
| `env/docker/nuxt/dockerfile` | 原始 Nuxt Dockerfile |

---

## 1. 舊設定的 15 項已確認缺陷（D1–D15）

新設定必須全數修掉。驗證時請逐項確認**新設定沒有重蹈覆轍**。

| # | 缺陷 | 驗收條件 |
|---|---|---|
| D1 | compose 寫 `nuxt/Dockerfile`，實檔是 `nuxt/dockerfile`（小寫） | 檔名大小寫與 compose 引用完全一致 |
| D2 | `backend/.env` 不存在，初始化腳本未 `cp` 也未 `key:generate` | entrypoint 會確保 `.env` 與 `APP_KEY` |
| D3 | 腳本呼叫不存在的 service `vue`、`npm-php` | 所有腳本引用的 service 都存在 |
| D4 | 仍執行 `artisan nova:install`（專案早已改用 Filament） | 無任何 Nova 殘留 |
| D5 | `CMD ["sh","-c","php-fpm -D && nginx …", "supervisord …"]` 第 4 元素成為 `$0` | **supervisord 真的啟動，`docker exec <app> supervisorctl status` 看得到 queue worker** |
| D6 | image 內 vendor 被 `./backend` bind mount 蓋掉 | vendor 用具名 volume 種子化，`docker exec <app> ls vendor/autoload.php` 存在 |
| D7 | `php` 無 `depends_on: mysql`、無 healthcheck | mysql 有 healthcheck，app `depends_on: condition: service_healthy` |
| D8 | `nuxt` 未注入 `NUXT_PUBLIC_API_BASE_URL` | 前端能打到後端 API |
| D9 | `.env.example` 是 sqlite，環境卻是 MySQL | `DB_CONNECTION=mysql` |
| D10 | `image: composer`(latest) PHP 版本不定 | composer 來自專案自己的 PHP 8.5 映像，**不得使用 `--ignore-platform-reqs`** |
| D11 | 每個 service 寫死 `container_name` | 完全沒有 `container_name:` |
| D12 | xdebug 永久啟用 | prod 映像 build 時斷言 `! php -m \| grep -qi xdebug` |
| D13 | mysql/phpmyadmin 對外開埠 | prod 不發布 DB 與管理工具的埠 |
| D14 | `dockerfile.development` 卻做 `COPY backend/` | dev target 不 COPY 原始碼 |
| D15 | `nuxt/dockerfile` 只有 `npm run dev` | 有 dev / build / prod 三個 target |

---

## 2. 阻斷級驗收項目（對抗驗證確認）

### 2.1 dev 映像必須能開機

`vendor-dev` 階段**不可以帶 `--no-autoloader`**。Composer 文件明載該旗標會跳過
`vendor/autoload.php` 產生。dev target 只 `COPY --from=vendor-dev`，沒有任何步驟重新產生 autoloader。

**失敗表現**：`cx dev up` 在 entrypoint 第 3 步 `php artisan key:generate --force` 炸掉：
```
PHP Fatal error: Uncaught Error: Failed opening required '/var/www/html/vendor/autoload.php'
```
容器 exit 255，`edge` 因為 `app` 永遠不健康而起不來。

**驗收**：
```bash
docker compose ... exec app test -f vendor/autoload.php && echo OK
```
entrypoint 另需有保險：`[ -f vendor/autoload.php ] || composer install`。

### 2.2 `-p` 不隔離 host 埠 —— 必須有獨立埠段

`-p pm_dev` / `-p pm_test` 只隔離容器、網路、volume，**不隔離已發布的 host 埠**。

**失敗表現**：`cx dev up -d` 之後 `cx test up -d` →
```
Error response from daemon: Ports are not available: bind for 0.0.0.0:8080 failed: port is already allocated
```

**驗收**：三個模式同時 `up`，全部成功。建議埠段：

| | dev | test | prod |
|---|---|---|---|
| HTTP / edge | 8080 | 18080 | 80 |
| Nuxt | 3000 | 13000 | — |
| MySQL | 127.0.0.1:3306 | 127.0.0.1:13306 | 不發布 |
| phpMyAdmin | 8891 | 18891 | 不發布 |
| WAF | — | 18081 | — |

**base 檔完全不能有 `ports:`** —— compose 的 ports 以 `{ip,target,published,protocol}` 為鍵**附加**合併，不是覆寫。

### 2.3 相對路徑解析

Compose v2 把 project directory 設為**第一個 `-f` 檔案所在的目錄**。
`env/docker/compose/test.yml` 裡寫 `./env/docker/waf/rules/xxx.conf` 會被展開成
`<root>/env/docker/compose/env/docker/waf/rules/xxx.conf`。

**失敗表現**：路徑不存在 → Docker 可能**靜默建立一個空目錄**並掛載上去，
於是 CRS 排除規則從未載入，Livewire/Filament 流量被 941xxx/942xxx 擋掉且毫無線索。

**驗收**：`cx` 必須一律傳 `--project-directory "$CX_ROOT"`。
```bash
docker compose --project-directory "$CX_ROOT" -p pm_test \
  -f "$CX_ROOT/docker-compose.yml" -f "$CX_ROOT/env/docker/compose/test.yml" config --quiet
```
並確認每個 bind mount 來源都真的存在（`cx doctor` 應該做這件事）。

### 2.4 顯式 `--env-file` 缺檔是硬錯誤

Compose v2 對**顯式** `--env-file` 缺檔會直接報錯（隱式 `./.env` 才會靜默略過）。

**失敗表現**：fresh clone 上每一個 docker 動詞在做任何事之前就死掉：
```
open /home/n126226695/pm/.env: no such file or directory
```

**驗收**：`cx` 的 env-file 清單必須條件式組出（只加存在的檔）；且 `cx doctor` 對缺少 `.env` 應該是**硬失敗**，不是 warning。

### 2.5 網路名會被命名空間化

compose 宣告 `networks: { pm_test_net: {} }` 在 project `pm_test` 下，實際建立的網路叫
`pm_test_pm_test_net`。

**失敗表現**：`docker run --network pm_test_net` →
```
docker: Error response from daemon: network pm_test_net not found.
```
ZAP 是唯一能打到 WAF 的東西，整條 DAST 因此死掉。

**驗收**：compose 裡明寫 `name:`，並在使用前 `docker network inspect` 確認。

---

## 3. 重大驗收項目

| # | 項目 | 驗收條件 |
|---|---|---|
| 3.1 | **映像 tag 必須含模式** | tag 形如 `pm/nuxt:${APP_MODE}-${NUXT_TARGET}-${FRONTEND_MODE}`。spa/static 的 API base URL 是 build 時烘進 bundle 的；test 與 prod 共用 tag 會讓 `cx test up`（未加 `--build`）拿到 prod bundle → **測試環境打到正式 API** |
| 3.2 | **不要用 `pecl install`** | 改用 `mlocati/php-extension-installer`。PECL 已被 Xdebug 官方標為 deprecated，且在 Alpine PHP 8.4+ 有 `Constant E_STRICT is deprecated` → `Filename too long` 的已知失敗 |
| 3.3 | **`php` service 不可宣告 `entrypoint:`** | image ENTRYPOINT 保持 `docker-php-entrypoint` 的 argv 直通，否則 `compose run --rm php composer …` 變成 `<entrypoint> composer …` |
| 3.4 | **test 的 `DB_FRESH` 要用哨兵檔一次性化** | base 是 `restart: unless-stopped`，entrypoint 每次啟動都跑 → 一次 OOM kill 就在 ZAP 掃描中途 `migrate:fresh --seed`，掃描結果全部失真 |
| 3.5 | **dev 的 `NUXT_SSR` 走 runtime `environment:`** | build arg 進不了 `nuxt dev`。否則 `FRONTEND_MODE=spa` 在 dev 被靜默忽略 |
| 3.6 | **prod 的 TLS 與 cookie 要一致** | 若發布 8443 就要有 `listen ssl` 區塊；否則拿掉 8443 並讓 `SESSION_SECURE_COOKIE` 預設 false。目前設計會讓 Filament 登入陷入無限 419 |
| 3.7 | **PM2 用 `fork` 不用 `cluster`** | cluster 走 CJS `require()` 載不動 Nuxt 的 ESM `.mjs`（`ERR_REQUIRE_ESM`；pm2#5946、nuxt#13916）。要擴充就開多個 fork 到多個埠 |
| 3.8 | **掃描容器不要固定 `--name`** | `--rm` 在 CLI 被 SIGKILL / daemon 重啟 / OOM 時不會執行，下次就 `Conflict. The container name is already in use` |
| 3.9 | **快取與報告目錄由 cx 預先建立** | 掛在「image 中不存在的路徑」上的具名 volume 一律被建成 root:root 0755 → 非 root 的 Trivy/Semgrep/PHPStan/ZAP 全部 EACCES |
| 3.10 | **SonarQube healthcheck 用 `curl` 不用 `wget`** | 該映像基於 `eclipse-temurin:25-jdk-noble`，只裝了 `bash curl fonts-dejavu`，**沒有 wget** → healthcheck 永遠 unhealthy，`service_healthy` 依賴死鎖。另需 `/tmp` 可讀寫（2026.1+） |
| 3.11 | **ModSecurity audit 從 stdout 取** | 預設 `SecAuditLogType Serial` 只寫 stdout，`MODSEC_AUDIT_STORAGE_DIR` 的 volume 是空的 → WAF↔ZAP 對照沒有資料 |
| 3.12 | **CRS 排除規則載入在 CRS 之前** | `ctl:ruleRemoveById` 只影響同 phase 尚未執行的規則。另外兩個 `ctl:` 之間是**逗號**不是分號 —— 分號會讓 ModSecurity 拒絕載入、nginx 起不來 |

---

## 4. 版本鎖定（LTS 政策）

| 元件 | 必須採用 | 理由 |
|---|---|---|
| PHP | `php:8.5-fpm-alpine` | PHP 無 LTS 制度。8.5 active 到 2027-12-31 / security 到 2029-12-31，**是支援期最長的**。降到 8.4 反而只到 2026-12-31 |
| Node | `node:24.20-alpine` | Node 24 = Active LTS 至 2028-04-30 |
| MySQL | `mysql:8.4` | **8.4 = LTS**（至 2032-04）。**禁止 9.x** —— Innovation track 每版僅 8 個月支援 |
| Nginx | `nginx:1.30-alpine` | stable 分支。1.29 **已 EOL**，會變成自家 Trivy 掃出的最大漏洞來源 |
| SonarQube | `sonarqube:2026-lta-community` | LTA 2026.1，每個 LTA 活躍 18 個月 |
| PostgreSQL | `postgres:17` | 支援中 |
| ZAP | `ghcr.io/zaproxy/zaproxy:stable` | 容器內 uid 1000，工作目錄 `/zap/wrk` |
| CRS WAF | `owasp/modsecurity-crs:nginx-*` | 反向代理形態，必須給 `BACKEND` |

> Laravel / Nuxt / Filament 同樣**沒有 LTS 制度**，維持 13 / 4 / 5。

---

## 5. 端到端驗收腳本

```bash
# 先決條件
docker version --format '{{.Server.Version}}'   # 必須成功，否則先開 WSL integration
./cx doctor                                      # 全綠才往下

# 三模式並存
./cx dev  up -d && ./cx --mode dev  ps
./cx test up -d && ./cx --mode test ps
./cx prod up -d --build
docker ps --format '{{.Names}}\t{{.Ports}}'      # 確認無埠衝突、無 container_name

# 功能
curl -fsS http://localhost:8080/up               # Laravel health（dev）
curl -fsS http://localhost:3000/                 # Nuxt（dev）
curl -fsS http://localhost:18081/                # 經過 ModSecurity WAF（test）
./cx art migrate:status

# D5 專項：supervisord 真的在管 queue worker
docker compose --project-directory "$PWD" -p pm_dev \
  -f docker-compose.yml -f env/docker/compose/dev.yml exec app supervisorctl status

# D6 專項：vendor 沒被 bind mount 蓋掉
docker compose ... exec app test -f vendor/autoload.php && echo "D6 OK"

# D12 專項：prod 沒有 xdebug
docker compose ... -p pm_prod exec app sh -c '! php -m | grep -qi xdebug' && echo "D12 OK"

# 掃描
./cx scan all && ls -R reports/
```

---

## 6. 驗證結果

> 驗證日期：**2026-09-04**
> 環境：WSL2 Ubuntu 26.04.1 / Docker Engine 29.7.2 / Compose v5.5.0 / 10 vCPU / 12.5 GB
> 執行方式：`cx verify all`，報告在 `reports/verify/`
> （**2026-09-04 當時**是 52 項、0 失敗、0 未驗。項數之後隨著新增檢查一直在變，
>   這裡保留當時的數字當作歷史紀錄，不要拿它跟現在比。）
>
> 這一輪之前，Docker daemon 在本機不可用；`sudo usermod -aG docker $USER` +
> `wsl --shutdown` 之後才第一次真的跑起來。

| 項目 | 結果 | 備註 |
|---|---|---|
| D1 Dockerfile 大小寫 | ✅ | 舊的小寫 `env/docker/nuxt/dockerfile` 已移至 `env/docker/legacy/`。**它原本與新的 `Dockerfile` 並存**，正是 D1 陷阱本身 |
| D2 `.env` 與 `APP_KEY` | ✅ | entrypoint 產生並 `chown www-data`，三個模式都驗過 |
| D3 幽靈 service | ✅ | 不再有 `vue` / `npm-php`。後端的 npm 由 `cx npm --backend` 提供 |
| D4 Nova 殘留 | ✅ | 全庫無 Nova 字樣；管理員改用 `cx db admin`（`make:filament-user`） |
| D5 supervisord 真的啟動 | ✅ | `supervisorctl status` 在三個模式都看到 **5 個 RUNNING**（php-fpm、nginx、queue ×2、schedule） |
| D6 vendor 沒被蓋掉 | ✅ | 三個模式的 `vendor/autoload.php` 都存在；dev 靠具名 volume 種子化 |
| D7 mysql healthcheck | ✅ | `mysqladmin ping` + `depends_on: condition: service_healthy` |
| D8 前端拿得到 API | ✅ | 同源（`NUXT_PUBLIC_API_BASE_URL=""`），edge 分流 |
| D9 `DB_CONNECTION=mysql` | ✅ | 三個模式的合併設定都確認 |
| D10 composer 版本固定 | ✅ | 來自 `composer/composer:2-bin`；`cx composer` 主動拒絕 `--ignore-platform-req*` |
| D11 無 `container_name` | ✅ | 合併後設定 0 筆 |
| D12 prod 無 xdebug | ✅ | build 斷言 + 執行期 `php -m` 複驗 |
| D13 prod 不開 DB/管理埠 | ✅ | prod 只發布 80 |
| D14 dev 不 COPY 原始碼 | ✅ | dev stage 只 COPY vendor |
| D15 nuxt 多 target | ✅ | deps / dev / build / prod / static |
| 2.1 dev 映像能開機 | ✅ | `vendor-dev` 無 `--no-autoloader`；entrypoint 另有 `composer install` 保險 |
| 2.2 三模式並存 | ✅ | **三個模式同時運行、零埠衝突**；base 檔無 `ports:`（2026-09-04 當時 14 個；test 之後加了 phpMyAdmin，現在是 15） |
| 2.3 相對路徑 | ✅ | 一律 `--project-directory "$CX_ROOT"`；`cx up` 會先斷言每個 bind mount 來源存在 |
| 2.4 env-file | ✅ | 條件式組出清單；`cx doctor` 對缺 `.env` 是**硬失敗** |
| 2.5 網路名 | ✅ | `pm_dev_net` / `pm_test_net` / `pm_prod_net` / `pm_devsecops_net` 都明寫 |
| 3.1 tag 含模式 | ✅ | 6 個 tag 互不重複 |
| 3.2 不用 pecl | ✅ | `mlocati/php-extension-installer:2` |
| 3.3 app 無 `entrypoint:` | ✅ | 啟動流程放 CMD，`--entrypoint composer` 仍可覆寫 |
| 3.4 `DB_FRESH` 一次性化 | ✅ | 哨兵檔 `storage/.pm-db-fresh-done`（跟著 storage volume 的生命週期） |
| 3.5 dev 的 `NUXT_SSR` | ✅ | runtime `environment:`，不是 build arg |
| 3.6 TLS / cookie 一致 | ✅ | 刻意不發布 8443；`SESSION_SECURE_COOKIE=false`。TLS 由 Ansible 那條路的 certbot 負責 |
| 3.7 PM2 用 fork | ✅ | `ecosystem.config.cjs.j2` 寫死 `exec_mode: fork`（Ansible 側；容器側用 Nitro，無 PM2） |
| 3.8 掃描容器不固定 name | ✅ | `scan.sh` 全庫無 `--name` |
| 3.9 目錄由 cx 預建 | ✅ | `cx setup dirs` 與 `cx up` 都會建；**另外修掉 dev 的具名 volume 掛在 bind mount 底下會被建成 root:root 的問題** |
| 3.10 Sonar healthcheck 用 curl | ✅ | `env/docker/compose/sonar.yml` 用 curl（該映像沒有 wget） |
| 3.11 ModSec audit 從 stdout | ✅ | `MODSEC_AUDIT_LOG=/dev/stdout` + JSON，實測 `cx --mode test logs waf \| grep '^{'` 取得到 |
| 3.12 CRS 排除順序 | ✅ | 走映像的 plugins 機制，`94-activate-plugins.sh` 實測把兩行 Include 取消註解 |
| 4. 版本鎖定 | ✅ | php 8.5 / node 24.20 / mysql 8.4 / nginx 1.30 / sonarqube 2026-lta |
| 5. 端到端 | ✅ | 三個模式的 `/up`、`/`、`/healthz`、`/admin/login`、`/sanctum/csrf-cookie`、`/api/user` 全數符合預期 |

### DAST 實測

`cx scan dast` 會做兩件事：

1. **ZAP baseline**（被動）在 `MODSEC_RULE_ENGINE=DetectionOnly` 與 `On` 各跑一次
2. **主動攻擊探測**（`bin/lib/waf_probe.py`）—— 這是量 WAF 攔截率的唯一有效方法

| | 結果 |
|---|---|
| ZAP FAIL-NEW（High risk） | **0** —— 符合 §5「無 High risk alert」的閘門 |
| ZAP WARN-NEW | 3（補上 edge 的安全標頭之前是 8） |
| ZAP PASS | 64 |
| 主動探測：攻擊 6 項 | **6 項全擋（100%）** |
| 主動探測：正常請求 4 項 | **0 誤擋** |

> ⚠ `zap-baseline.py` 是**被動**掃描，不送攻擊 payload。
> 拿兩份 baseline 報告直接相減，結論永遠是「WAF 擋下 0 項」——
> 那不是 WAF 沒用，是量錯了東西。攔截率必須用主動探測量。

### WAF 逐項（手動複驗）

| 請求 | DetectionOnly | On |
|---|---|---|
| `?id=1' OR '1'='1` | 200（記錄） | **403** |
| `?q=<script>alert(1)</script>` | 200（記錄） | **403** |
| `?f=../../../../etc/passwd` | 200（記錄） | **403** |
| `/up` | 200 | 200 |
| `/admin/login` | 200 | **200**（排除規則 10012/10013 有效） |
| `/` | 200 | 200 |

## 7. 追加發現

驗證過程中找到的、原始清單裡沒有的問題。每一項都已修正。

| # | 問題 | 為什麼原本抓不到 | 修正 |
|---|---|---|---|
| A1 | **`cx` 在 git index 裡是 `100644`** | 磁碟上是 755，`git diff` 看不出差異。但任何人 clone 下來打 `./cx` 都是 `Permission denied` —— 單一入口在第 0 步就壞了 | `git update-index --chmod=+x`；`cx doctor` 已有這項檢查（本次讓它真的通過） |
| A2 | **`bin/cmd/compose.sh` 不存在** | dispatcher 的 `CX_CMD_FILE_OF` 把 8 個動詞指到它，於是 `cx up` 回「未知的指令」 | 寫出該檔；`cx doctor` 新增「動詞實作檔完整性」檢查 |
| A3 | **supervisorctl 找不到 socket** | `supervisord -c` 指定的路徑不影響 `supervisorctl`，它讀自己的預設 `/etc/supervisord.conf`。而 D5 的驗收指令正是 `exec app supervisorctl status` | 設定檔改放 Alpine 的預設路徑 |
| A4 | **具名 volume 掛在 bind mount 底下 → host 上出現 root:root 目錄** | 只在 dev 模式發生。`frontend/{node_modules,.nuxt,.output}`、`backend/vendor`、`backend/.env` 全部變成 root 所有，非 root 的操作者既寫不進去也刪不掉 | `cx up` 先以呼叫者身分建立這些掛載點；entrypoint 把 `.env` chown 回 www-data |
| A5 | **`phpunit.xml` 的 `<env>` 沒有 `force="true"`** | PHPUnit 的 `<env>` 預設**既有環境變數優先**。compose 傳進 `DB_CONNECTION=mysql`，於是 sqlite 設定被靜默忽略，測試會打到真正的開發資料庫 —— 而 `RefreshDatabase` 會把它清空 | 14 個 `<env>` 全部加上 `force="true"`；`cx test back` 另外再傳一次 `-e` 覆蓋 |
| A6 | **缺 `pdo_sqlite`** | `phpunit.xml` 指向 sqlite `:memory:`，但映像沒裝這個擴充 → `could not find driver`，看起來像資料庫設定錯 | 加進 base stage |
| A7 | **`Route [login] not defined` → HTTP 500** | 帶 `Accept: application/json` 時是正確的 401，用瀏覽器開同一個網址卻是 500。看起來像 API 壞了，其實是找不到重導目標 | `bootstrap/app.php` 加 `redirectGuestsTo` |
| A8 | **沒有 `trustProxies`** | 應用永遠在反向代理後面，不信任 `X-Forwarded-*` 會讓 `request()->ip()` 全是容器 IP、`isSecure()` 永遠 false | `bootstrap/app.php` 信任私有網段 |
| A9 | **後端的 Vite 資產從來沒被建置過** | 舊 `init.sh` 呼叫一個叫 `npm-php` 的 service，但那個 service 從來不存在（缺陷 D3）。`welcome.blade.php` 有 `@vite(...)`，沒有 `public/build/manifest.json` 會丟 `ViteManifestNotFoundException` | 新增 `backend-assets` build stage 與 `cx npm --backend` |
| A10 | **WAF 掛載點錯誤 → 容器無限重啟** | 把排除規則掛在 `modsecurity-override.conf` 上是錯的：映像的 `90-copy-modsecurity-config.sh` 會 touch 並覆寫那個檔，`:ro` 之下它 exit 1 | 改用映像的 plugins 機制（`/opt/owasp-crs/plugins/*-{before,after}.conf`） |
| A11 | **Semgrep 靜靜地失敗（exit 7）** | `p/laravel` 與 `p/vue` 在 registry 上已經是 HTTP 404。而 `--sarif --output` 把 stdout 全導進檔案，終端機上看不到任何錯誤 | 移除失效的規則集並換上等效的；`cx scan sast` 對 exit ≥2 給出可行動訊息 |
| A12 | **SAST 閘門與文件不符** | `--error` 是「有任何 finding 就失敗」，包含 warning。而 claude.md §5 寫的是「無 ERROR 等級 finding」。用 `--error` 當閘門的結果是這條 lane 永遠紅燈，於是沒有人會再看它 | 改由 `bin/lib/sarif_gate.py` 依嚴重度判定，warning 仍然完整顯示 |
| A13 | **`.trivyignore.yaml` 從未被引用** | 檔案存在、內容也寫好了，但 `trivy.yaml` 沒有 `ignorefile:` —— 於是「無 HIGH/CRITICAL 除非有到期日的例外」這個閘門其實不成立 | 接上 `ignorefile:`，並補上兩筆有 `expired_at` 的例外 |
| A14 | **`.semgrepignore` 放錯位置** | Semgrep 只在「掃描目標的根目錄」找它。原本放在 `env/docker/security/semgrep/` 底下，從來沒被讀到 | 移到專案根目錄 |
| A15 | **Trivy 掃到 `ansible/collections/`** | 那是 ansible-galaxy 下載的上游程式碼，回報的是別人測試夾具裡的問題 | 加入 `skip-dirs` |
| A16 | **ZAP 的 `baseline.conf` 路徑指向未掛載的位置** | `-c /zap/wrk/../../../docker/...` 在容器內解析成 `/docker/...`，而只有 `reports/dast/<mode>` 被掛到 `/zap/wrk` | 多掛一個唯讀 volume 並改用容器內絕對路徑 |
| A17 | **`scan.sh` 的兩個累加器缺陷** | `_scan_code` 把 SonarQube 的 rc 寫進呼叫者的 `worst` 但 return 的是 `_lane_worst`；`_scan_secrets` return 一個在該函式裡不存在的變數 | 兩處都改成回傳自己的 lane 累加器 |
| A18 | **H2C smuggling** | edge 的 `map $http_upgrade $connection_upgrade { default upgrade; }` 會把 `Upgrade: h2c` 也轉給上游 | 改成白名單，只有 `websocket` 放行 |
| A19 | **`include_role` 不能當 handler** | ansible-core 2.21 直接拒絕載入。這是實跑 `--syntax-check` 才發現的 —— 靜態 YAML 檢查看不出來，因為語法本身完全合法 | certbot 的重新渲染改成一般 task |
| A20 | **37 個 inventory 變數不被任何 role 讀取** | 值剛好都與真正的變數相同，所以第一次部署會「看起來正常」。危險的是第二次：改了文件上的旋鈕卻沒有任何反應 | 全部接上真正的名字，詳見下節 |

### A20 的細節：三個載重最重的死變數

| 變數 | 原本的行為 | 修正 |
|---|---|---|
| `production.yml.example` 的 `waf_exclusions_before: []` | inventory group_vars 優先權高於 role defaults，照抄這個檔會**在 `waf_rule_engine` 切成 `On` 的同一刻**抹掉 5 條研究過的 Livewire/Filament 排除規則（id 10010–10014）。結果是 Filament 後台被 941/942 擋死，而且沒有任何線索指向 WAF | 從範例檔移除該行，改成一段說明「為什麼刻意不定義它」 |
| `releases_prune: false` | 只出現在 debug 橫幅裡。設成 false 會印出 `prune=False` 然後照樣 prune —— 這是「看起來已經關掉了」最糟的一種形式 | `backend_prune_enabled` / `frontend_prune_enabled` 改讀它 |
| `backend_branch: "release/x"` | 同樣只在橫幅裡。會印出 `release/x` 然後 clone `main` | `backend_repo_version` 改讀它 |

其餘：`waf_repo_*`（8 個，README §5.2 把 `waf_repo_manage: false` 當逃生門介紹，但那個名字不被讀取）、
`waf_crs_paranoia_level` 等 3 個（role 讀的是 `waf_crs_setup_vars` 這個扁平 dict）、
`tls_hsts_max_age`（文件寫 180 天，實際送出 1 年 —— HSTS 的 max-age 送出去就收不回來）、
`deploy_backend_migrate` 等 9 個 deploy 旋鈕。全部已接上。

## 8. Ansible 的驗證狀態

claude.md §12.5 原本寫「連 `ansible-playbook --syntax-check` 都跑不了」。
`cx setup tools ansible` 用 `python3 -m venv --without-pip` + `get-pip.py` 免 root 裝起來之後：

| 項目 | 結果 |
|---|---|
| `site.yml --syntax-check` | ✅ |
| `playbooks/deploy-only.yml --syntax-check` | ✅ |
| `playbooks/rollback.yml --syntax-check` | ✅ |
| `ansible-lint`（**production profile**） | ✅ 0 failures / 0 warnings（181 個檔案） |
| `yamllint` | ✅ 0 |

起點是 739 個 finding。其中 673 個是 `var-naming[no-role-prefix]`，
與本專案「用 `group_vars/all/main.yml` 當單一事實來源」的架構直接衝突，已在
`env/ansible/.ansible-lint` 中附理由關閉。其餘逐一修正或以 inline `noqa` 加註理由。

**仍然沒有驗證的**：任何需要真實目標主機的東西 —— MyGuard 套件解析、
MySQL 8.4 from Oracle repo、certbot 的 snakeoil bootstrap、release prune 的
current-aware 行為、PM2 跑 Nuxt `.output`。這些要等 `cx deploy check <限制>`
對一台真的 staging 機器跑過才算數。
