# Docker 設定驗證需求

> 對象：負責 Docker 驗證的對話 / 人員
> 專案：`pm`（本機 `~/pm`）
> 前置閱讀：根目錄 `claude.md` §0 紅線、§4 Docker 三模式、§5 DevSecOps

---

## 0. 背景

本專案的 Docker 設定經過一輪 10-agent 的設計與對抗驗證。**設計被判定為 `has_blocking_flaws`**，
下列項目是驗證者實際追出失敗路徑後提出的修正。**本文件不是建議清單，是必須逐項確認的驗收條件。**

舊的設定檔已保留在 `docker/legacy/`：

| 檔案 | 說明 |
|---|---|
| `docker/legacy/docker-compose.yml.orig` | 原始 compose（8 個 service，無模式區分） |
| `docker/legacy/dockerignore.orig` | 原始 .dockerignore |
| `docker/legacy/init.sh.orig` / `refresh.sh.orig` | 原始初始化腳本（已知壞掉） |
| `docker/legacy/README.md.orig` | 原始 README |
| `docker/php/*` | 原始 PHP 容器設定（nginx.conf、supervisord.conf、xdebug.ini 等） |
| `docker/nuxt/dockerfile` | 原始 Nuxt Dockerfile |

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
`docker/compose/test.yml` 裡寫 `./docker/waf/rules/xxx.conf` 會被展開成
`<root>/docker/compose/docker/waf/rules/xxx.conf`。

**失敗表現**：路徑不存在 → Docker 可能**靜默建立一個空目錄**並掛載上去，
於是 CRS 排除規則從未載入，Livewire/Filament 流量被 941xxx/942xxx 擋掉且毫無線索。

**驗收**：`cx` 必須一律傳 `--project-directory "$CX_ROOT"`。
```bash
docker compose --project-directory "$CX_ROOT" -p pm_test \
  -f "$CX_ROOT/docker-compose.yml" -f "$CX_ROOT/docker/compose/test.yml" config --quiet
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
  -f docker-compose.yml -f docker/compose/dev.yml exec app supervisorctl status

# D6 專項：vendor 沒被 bind mount 蓋掉
docker compose ... exec app test -f vendor/autoload.php && echo "D6 OK"

# D12 專項：prod 沒有 xdebug
docker compose ... -p pm_prod exec app sh -c '! php -m | grep -qi xdebug' && echo "D12 OK"

# 掃描
./cx scan all && ls -R reports/
```

---

## 6. 驗證結果（請接手者回填）

| 項目 | 結果 | 備註 |
|---|---|---|
| D1–D15 | ⬜ | |
| 2.1 dev 映像開機 | ⬜ | |
| 2.2 三模式並存 | ⬜ | |
| 2.3 相對路徑 | ⬜ | |
| 2.4 env-file | ⬜ | |
| 2.5 網路名 | ⬜ | |
| 3.1–3.12 | ⬜ | |
| 4. 版本鎖定 | ⬜ | |
| 5. 端到端 | ⬜ | |

## 7. 追加發現

（請接手者補充驗證過程中發現的新問題）
