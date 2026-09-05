# pm 操作說明書

> 這份文件涵蓋從零開始到三個階段的完整流程。
> 逐個動詞的參數細節見 [`cx-reference.md`](cx-reference.md)。
> 出事的時候看 [`troubleshooting.md`](troubleshooting.md)。

---

## 1. 這是什麼

前後端分離的系統：

| 層 | 技術 | 版本 |
|---|---|---|
| 前端 | Vue 3 + Nuxt | 4.5.2 |
| 後端 | PHP + Laravel + Filament | 8.5 / 13 / v5 |
| 資料庫 | MySQL | 8.4 LTS |
| 反向代理 | Nginx | 1.30 stable |
| 測試環境的 WAF | ModSecurity + OWASP CRS | — |
| 容器 | Docker Compose | v2 |
| 部署 | Ansible | 原生，非容器 |
| 入口 | `./cx` | Bash + whiptail |

三個 git repo，主庫以 submodule 統籌：

```
pm/                ← 主庫    → Information-Study/pm
├── backend/       ← submodule → Information-Study/pm-backend
└── frontend/      ← submodule → Information-Study/pm-frontend
```

### 唯一入口是 `cx`

不要直接下 `docker compose`。四個合併陷阱（相對路徑基準、`ports:` 是附加合併、
顯式 `--env-file` 缺檔是硬錯誤、網路名會被命名空間化）全部集中在
`bin/lib/common.sh` 的 `cx_compose_init` 處理，繞過去幾乎一定會錯。

`cx` 可以從專案任何子目錄執行（向上搜尋 `.cxroot` 標記，**不用 `git rev-parse`** ——
因為 `cx fresh` 會刪掉 `.git`，用 git 當解析器會在流程中途壞掉）。
跑過 `cx install` 之後可以在任何地方直接打 `cx`。

---

## 2. 從零開始

### 2.1 前置需求

| 必要 | 用途 | 缺了會怎樣 |
|---|---|---|
| Docker Engine + Compose v2 | 三個模式的容器 | `cx dev/test/prod` 全部擋下 |
| git | 版本控制 | 什麼都不能做 |
| python3 | `cx` 的幾支輔助程式 | verify / lint / compose 掛載檢查失效 |
| bash 5.x | `cx` 本身 | — |

其餘（composer、node、ansible、trivy、gitleaks、semgrep）由 `cx setup tools`
免 root 安裝，不需要事先準備。

> **WSL 的常見卡點**：`sudo usermod -aG docker $USER` 之後**必須**在 Windows 端
> 執行 `wsl --shutdown` 再重開。`usermod` 只影響「之後才建立」的登入 session，
> 既有的 shell 不會生效 —— 而 `docker ps` 只會說
> `permission denied while trying to connect to the docker API`，
> 完全不會提示你「群組已經加好了，只是還沒生效」。

### 2.2 四行指令

```bash
git clone --recurse-submodules https://github.com/Information-Study/pm.git
cd pm
./cx setup                    # .env、目錄、collections，並盤點工具鏈
./cx dev up -d --build        # 起開發環境
```

`cx setup` 做的事：

1. 從 `.env.example` 產生 `.env`（隨機密碼、填入你的 UID/GID）
2. 建立 `reports/` 與 `.cx/` 的葉目錄（**必須由你建立**，讓 Docker 建會是 root:root）
3. ~~安裝三個 repo 的 pre-push hook~~ —— **已改為選用**，`cx setup` 不再自動安裝。
   要啟用白名單攔截： `cx git guard install`
4. 安裝 Ansible collections（`ansible/collections/` 不進版控）
5. 盤點缺少的工具並告訴你怎麼補

### 2.3 補齊工具鏈

```bash
./cx setup tools              # 全部
./cx setup tools composer node ansible   # 只裝指定的
./cx setup deps               # backend 的 composer install、兩邊的 npm
./cx doctor                   # 確認還缺什麼
```

`cx setup tools` 全程免 root，裝到 `~/.local`：

| 工具 | 來源 | 校驗 |
|---|---|---|
| composer | GitHub release | SHA256（校驗碼來自 getcomposer.org，交叉驗證） |
| node 24.20 | nodejs.org | SHA256（對 SHASUMS256.txt） |
| ansible / ansible-lint / yamllint | PyPI（`venv --without-pip` + get-pip.py） | pip |
| trivy / gitleaks | GitHub release | SHA256（對 checksums.txt） |
| semgrep | PyPI | pip |

### 2.4 開好之後

| | 網址 |
|---|---|
| 前端 | http://localhost:8080 |
| 後端 API | http://localhost:8080/api |
| Filament 後台 | http://localhost:8080/admin |
| Nuxt 直連（繞過 edge） | http://localhost:3000 |
| phpMyAdmin | http://127.0.0.1:8891 |

```bash
./cx db admin                 # 建立 Filament 管理員
```

### 2.5 互動選單：`cx tui`

不給動詞時的預設。除了把所有動詞包起來，還有三件命令列做不到的事：

| 主選單 | 作用 |
|---|---|
| `切換模式` | 之後每一個指令都帶 `--mode dev\|test\|prod`。標題會顯示目前狀態 |
| `環境 → 切換 runner` | 之後每一個指令都帶 `--runner auto\|docker\|native` |
| `環境 → 整備環境` | 對應 `cx setup` 的每一段：`native` / `system` / `tools` / `deps` / `env` / `dirs` / `guard` / `galaxy` |
| `自訂選單` | 讀 `.cx/menu.conf`，第一次進入自動產生範本 |

自訂選單的格式是每行 `標籤|要傳給 cx 的參數`：

```
重建 dev 並驗收|dev up -d --build
只掃祕密|scan secrets
後端測試（原生）|test back
```

`#` 是註解，空行忽略；參數會自動帶上目前的 `--mode` 與 `--runner`。
子選單最後一項直接開編輯器，存檔即生效。
`.cx/` 已被 `.gitignore` 排除，所以自訂選單是每台機器各自的。
路徑可用 `CX_MENU_FILE` 覆寫。

### 2.6 檔案權限：`cx acl`

```bash
./cx acl check                # 唯讀驗證（cx doctor 也會看這一項）
./cx acl apply                # 套用前後端的權限模型
./cx acl user add <帳號>      # 讓另一個開發者能改原始碼（--ro 只讀）
./cx acl fix-owner            # 把不屬於你的檔案要回來
```

需要 `setfacl`：`cx setup system acl`。

**為什麼需要**：setgid 只讓新建的目錄繼承群組，**不繼承權限位元** ——
位元仍由建立者的 umask 決定。所以 php-fpm 建的檔 deploy 寫不動、
deploy 建的檔 php-fpm 寫不動，兩邊互相踩。這就是 Laravel
「明明 chown 過了還是 permission denied」的成因。
default ACL 讓新建的檔案自動帶上兩邊的權限，而 others 仍然是 `0`。

本機開發常常用不到 —— 容器裡的 `www-data` 已被對齊成你的 uid，
`cx acl check` 會直接把這件事講出來。部署主機由 Ansible 的 common role
處理同一套模型。完整說明見
[`cx-reference.md`](cx-reference.md) 的 `cx acl` 與
[`ansible-reference.md`](ansible-reference.md) §6.6。

---

## 2.7 五種角色，五條路

`cx` 的動詞是照「開發 → 測試 → 部署」這條線排的，而不同角色走的是不同的
子集。這一節是索引：每一條的完整說明在對應的指南裡。

### ① 第一次啟動新專案

```bash
# 下載範本 → 改名、抹掉範本歷史、重建、接遠端（一個動詞做完）
cx init <新專案名> --org <GitHub 組織> --gh

cx setup env                 # ⚠ 重新產生 .env（新密碼；cx init 刻意不做這件事）
cx setup native              # 整套原生工具鏈 + 專案相依
cx acl apply                 # POSIX ACL（php-fpm 與你都要寫得進去）
cx dev up -d --build         # 起開發環境
cx verify                    # 驗收
cx git commit && cx git push # 推上去
```

`cx init` 底下是 `rename → fresh → remote` 三支，順序是**強制**的。
完整流程、兩種重建模式的差別、閘門文字、rollback：
[`guide-developer.md`](guide-developer.md) §0。

> 只想抹掉 git 歷史而**不重建**前後端（「這份程式碼要當新專案的起點」）：
> `cx fresh --mode git-only`。

### ② 人員接續專案

```bash
git clone --recurse-submodules <URL> && cd <repo>
cx status && cx doctor       # 先看現況，再看環境能不能用
cx setup native && cx setup env
cx git config identity && cx git sync
cx dev up -d --build
```

clone 之後有**五件事不會自動就緒**，而它們的失敗訊息都不會說出真正的原因。
完整流程：[`cx/onboarding.md`](cx/onboarding.md)。

### ③ 開發人員

```bash
cx git branch switch dev
cx dev up -d --build
cx git feature start <名稱> --repo backend|frontend    # 工作分支只開在子模組
# … 開發 …
cx lint && cx test && cx git scan-secrets
cx git commit --repo backend
cx git feature finish --repo backend                  # 合回 dev，主庫 gitlink 跟上
cx git push
```

完整說明：[`guide-developer.md`](guide-developer.md)。

### ④ 測試人員

```bash
cx git branch switch dev
cx test up -d --build              # 不可變映像 + ModSecurity WAF
cx test all && cx verify all && cx scan all
cx git hotfix start <名稱> --repo backend|frontend     # 缺陷用 hotfix/*
# … 修 …
cx git hotfix finish --repo backend
cx prod up -d --build && cx verify app                 # 正式模式也要能跑
cx git push
cx git release                     # 放行：dev → main（唯一會碰 main 的動作）
```

放行條件、報告判讀、五個最常見的誤讀：[`guide-tester.md`](guide-tester.md)。

### ⑤ 部署人員

```bash
cx git branch switch main          # 部署一律從 main
```

**Docker 路徑**：`cx prod up -d --build`

**Ansible 原生路徑**：
```bash
cx deploy hosts init --env production
cx deploy hosts add <名稱> --ip <IP> --user <帳號>   # --fe/--be/--db 決定跑什麼
cx deploy hosts check --ansible
cx deploy syntax && cx deploy lint && cx deploy check
cx deploy apply                    # ⚠ 真的部署，會列出目標主機並要求確認
```

前端、後端、資料庫**可以**分屬不同主機（`web_frontend` / `web_backend` /
`db_primary`），但那是架構變更不是旋鈕 —— FPM 要改成 TCP，而它沒有認證機制。
完整清單：[`guide-deployer.md`](guide-deployer.md) §3.3。

---

## 3. 三個階段

`cx` 的動詞是照「開發 → 測試 → 部署」這條線排的。

### 3.1 第一階段：開發

```bash
./cx dev up -d --build        # 起開發環境
./cx dev logs -f app          # 追 log
./cx dev sh app               # 進容器（裡面有 art / t 兩個捷徑）
./cx dev restart nuxt         # 只重啟前端
./cx dev down                 # 關閉（加 -v 連資料庫一起刪，會要求確認）
```

**dev 模式的特性**

| | |
|---|---|
| 原始碼 | bind mount（`./src/backend`、`./src/frontend`），改了立刻生效 |
| 前端 | Nuxt dev server + HMR |
| xdebug | 已載入，`start_with_request=trigger`（不是 `yes` —— 常開會讓每個請求都去連 IDE） |
| 額外服務 | phpMyAdmin（127.0.0.1:8891） |
| 快取 | 不做 config cache（否則改了 `.env` 完全沒反應，而且那是最難查的那種「沒反應」） |

`vendor/` 與 `node_modules/` 用**具名 volume 蓋回去**。這不是多此一舉：
`./src/backend:/var/www/html` 會把 image 裡烘好的 vendor 整個遮掉，容器在 entrypoint
就 `Failed opening required 'vendor/autoload.php'`。具名 volume 掛在
「image 中已存在的路徑」上時 Docker 會用 image 內容種子化它，所以掛上去反而救回 vendor。

副作用是容器內外各有一份 `vendor/`：容器內的是 Alpine（musl）編的，
host 上的是 Ubuntu（glibc）編的，給 IDE 與原生 `cx scan code` 用。
這是刻意的 —— 混用會踩到原生擴充的平台不符。

**日常指令**

```bash
./cx art migrate                  # php artisan
./cx art tinker
./cx composer require foo/bar     # composer（在 backend/）
./cx npm install pkg              # npm（在 frontend/）
./cx npm --backend run build      # npm（在 backend/，Laravel 的 Vite 資產）

./cx db status                    # 連線資訊、資料表、migration 狀態
./cx db shell                     # 進 mysql client
./cx db shell "SELECT COUNT(*) FROM users"
./cx db dump                      # 備份到 reports/db/
./cx db fresh                     # ⚠ 清空並重建（會要求確認）
./cx db admin                     # 建立 Filament 管理員
```

### 3.2 第二階段：測試與掃描

```bash
./cx test up -d --build       # 起測試環境（不可變映像 + ModSecurity WAF）
./cx test back                # 後端 PHPUnit
./cx test front               # 前端型別檢查（nuxt typecheck）
./cx test all
./cx test coverage            # 後端覆蓋率（臨時打開 xdebug）
```

**test 模式的特性**

| | |
|---|---|
| 原始碼 | **烘進映像**，沒有任何原始碼 bind mount —— 掃到的就是要上線的東西 |
| 對外入口 | **WAF**（18081），不是 edge：`ZAP → waf → edge → app/nuxt` |
| xdebug | 已安裝但 `XDEBUG_MODE=off`（常開會讓 ZAP 的時間量測失真） |
| 資料庫 | `DB_FRESH=true`，但用哨兵檔一次性化 |

`DB_FRESH` 的哨兵檔（`storage/.pm-db-fresh-done`）不是多餘的：
base 是 `restart: unless-stopped`，entrypoint 每次啟動都會跑 ——
沒有哨兵檔的話，一次 OOM kill 就會在 ZAP 掃描中途 `migrate:fresh --seed`，
掃描結果全部失真而且看不出原因。

**後端測試走 sqlite `:memory:`**，不需要 MySQL。這一點有個必須知道的細節：
`src/backend/phpunit.xml` 的每個 `<env>` 都帶 `force="true"`。
PHPUnit 的 `<env>` 預設語意是「既有的環境變數優先」，而 compose 會傳進
`DB_CONNECTION=mysql` —— 沒有 `force="true"` 的話測試會打到**真正的開發資料庫**，
而 `RefreshDatabase` 會把它清空。

**四道防線**

```bash
./cx scan code       # ① Quality  Larastan + SonarQube scanner
./cx scan sast       # ② SAST     Semgrep
./cx scan sca        # ③ SCA      Trivy + composer audit + npm audit
./cx scan dast       # ④ DAST     ZAP（DetectionOnly 與 On 各跑一次）+ 主動攻擊探測
./cx scan secrets    # gitleaks 全歷史祕密掃描
./cx scan all        # 依序全跑
```

閘門定義與報告格式見 [`devsecops.md`](devsecops.md)。

**SonarQube**（常駐，dev/test 共用）

```bash
./cx sonar up        # 啟動（獨立 compose project pm_devsecops）
./cx sonar token     # 產生分析 token，寫進 .cx/sonar-token
./cx scan code       # 之後會自動讀那個 token
```

**驗收**

```bash
./cx verify          # 靜態 + 應用端點 + Ansible
./cx verify all      # 加上執行期（需要三個模式都 up）
```

每次都會產生一份帶時間戳的報告到 `reports/verify/`。
**`SKIP` 不等於 `PASS`** —— 它的意思是「這次沒辦法驗」。

### 3.3 第三階段：部署

**容器化的正式環境**

```bash
./cx prod up -d --build       # 只發布 80，無管理工具、無 xdebug（build 時斷言）
```

**真機部署（Ansible，非容器）**

```bash
# 一次性準備
cp env/ansible/inventory/hosts.yml.example              env/ansible/inventory/hosts.yml
cp env/ansible/inventory/group_vars/staging.yml.example env/ansible/inventory/group_vars/staging.yml
ansible-vault create env/ansible/inventory/group_vars/all/vault.yml   # ⚠ 注意是 all/ 底下
ssh-keyscan -H <你的主機> >> ~/.ssh/known_hosts

# 流程
./cx deploy galaxy            # 安裝 collections（全新 clone 一定要先跑）
./cx deploy syntax            # ansible-playbook --syntax-check
./cx deploy lint              # ansible-lint（production profile）+ yamllint
./cx deploy ping staging      # 確認 SSH 與 become
./cx deploy check staging     # --check --diff 乾跑
./cx deploy apply staging     # ⚠ 真的部署（會列出目標主機並要求確認）
```

> **vault 的位置是 `group_vars/all/vault.yml`，不是 `group_vars/vault.yml`。**
> Ansible 把 `group_vars/<名字>.yml` 對應到「名為 `<名字>` 的群組」，
> 而沒有叫 `vault` 的群組 —— 放錯位置的話那個檔**永遠不會被載入**，
> 而且不會有任何警告。症狀是密碼像是沒設過。

> `--check` 不是萬能：`command` / `shell` 在 check 模式會被跳過，
> 所以「乾跑通過」不等於「實際跑一定會過」。

---

## 4. 三個模式可以同時運行

```bash
./cx dev up -d && ./cx test up -d && ./cx prod up -d
docker ps        # 三個模式共 15 個容器（dev 5 / test 6 / prod 4），零埠衝突
```

靠的是**兩件事同時成立**：

1. 不同的 compose project（`-p pm_dev|pm_test|pm_prod`）→ 隔離容器、網路、volume
2. 不同的 host 埠段（`env/docker/compose/<mode>.env`）→ 隔離埠

> `-p` **不隔離 host 埠**。只做第 1 件不做第 2 件，第二個模式會直接
> `Bind for 0.0.0.0:8080 failed: port is already allocated`。

| | dev | test | prod |
|---|---|---|---|
| HTTP（edge） | 8080 | 18080 | **80** |
| WAF | — | 18081 | — |
| Nuxt 直連 | 3000 | 13000 | 不發布 |
| MySQL | 127.0.0.1:3306 | 127.0.0.1:13306 | 不發布 |
| phpMyAdmin | 8891 | 18891 | — |
| compose project | `pm_dev` | `pm_test` | `pm_prod` |
| 網路名 | `pm_dev_net` | `pm_test_net` | `pm_prod_net` |

---

## 5. 架構

```
                     ┌──────────────────────────────┐
  瀏覽器 / ZAP ────▶ │ waf（僅 test）ModSecurity+CRS │
                     └───────────────┬──────────────┘
                                     ▼
                     ┌──────────────────────────────────────┐
                     │ edge  nginx 1.30                     │
                     │  /                            → nuxt │
                     │  /api /admin /up /storage            │
                     │  /sanctum /livewire-<hash>           │
                     │  /js /css /fonts /vendor /build → app │
                     └───────┬──────────────────────┬───────┘
                             ▼                      ▼
              ┌──────────────────┐  ┌────────────────────────┐
              │ nuxt  Nitro:3000 │  │ app                    │
              │ 或 nginx（static）│  │ supervisord（PID 1）    │
              └──────────────────┘  │  ├ php-fpm             │
                                    │  ├ nginx:8080          │
                                    │  ├ laravel-queue ×2    │
                                    │  └ laravel-schedule    │
                                    └───────────┬────────────┘
                                                ▼
                                        ┌──────────────┐
                                        │ mysql 8.4    │
                                        └──────────────┘
```

**edge 在三個模式都存在**，所以 Docker 拓撲與 Ansible 原生拓撲一致，
`NUXT_PUBLIC_API_BASE_URL=""`（同源）在兩邊都是正確預設。

### 為什麼 edge 要路由那麼多前綴給 PHP

| 前綴 | 為什麼 |
|---|---|
| `/api/` `/admin` `/up` `/storage/` | 顯而易見的後端路徑 |
| `/sanctum/` | SPA 認證的第一步是 `/sanctum/csrf-cookie`。漏掉它登入會在第一步 404，而症狀看起來像「CORS 壞了」 |
| `/livewire-<hash>/` | Livewire v4（Filament v5 的底層）把端點放在**帶 hash 的前綴**底下，hash 由應用的 key 推導、每個部署不同。寫死 `/livewire/` 一條都比對不到，後台的每一次互動都 404 |
| `/js/` `/css/` `/fonts/` | `artisan filament:assets` 發布的靜態資產。落到 Nuxt 就是 404 —— `/admin/login` 的 HTML 殼還是回 200，所以表面上看起來「有在跑」，實際上畫面沒有任何樣式與互動 |
| `/vendor/` `/build/` | 其他 Laravel 套件與 Vite 的發布位置 |

Nuxt 自己的資產全部在 `/_nuxt/` 底下，不會跟這幾個前綴衝突。

### 前端三模式

`FRONTEND_MODE` 決定建置方式，而 API base URL 的決定時機也跟著不同：

| 模式 | 建置 | 執行 | API base URL |
|---|---|---|---|
| `ssr` | `nuxt build` | Nitro 跑 `.output/server/index.mjs` | **啟動時**（可用環境變數） |
| `spa` | `nuxt build`（ssr:false） | 同上 | **build 時**（烘進 bundle） |
| `static` | `nuxt generate` | nginx 直送 `.output/public` | **build 時**（烘進 bundle） |

因為 spa / static 是 build 時烘進去的，**映像 tag 一定要含模式**
（`pm/nuxt:test-prod-ssr`）。test 與 prod 共用 tag 會讓 `cx test up`（沒加 `--build`）
拿到 prod 的 bundle，測試環境就會打到正式 API。
`-p` 隔離容器與網路，但**不隔離映像 tag**。

---

## 6. 紅線

1. **推送前先掃祕密。**（白名單 hook 已於 2026-09-04 移除，改為選用）
   唯一合法遠端是 `github.com/Information-Study/{pm,pm-backend,pm-frontend}`。
   舊的 `team-of-P/*` **永久禁止**，pre-push hook 不接受任何覆寫旗標。
   合法入口只有 `cx git push`。
2. **任何刪除都要互動確認**，不可逆的還要輸入確認字串。
3. **不要繞過 `cx`。** 直接下 `docker compose` 幾乎一定會錯。
4. **不要用 `--ignore-platform-reqs` 硬過相依衝突**（`cx composer` 會主動拒絕這個旗標）。

---

## 7. 檔案地圖

```
pm/
├── cx                       統一入口 dispatcher
├── .cxroot                  根目錄標記（專案名、GitHub 組織、repo 名）
├── .env                     ⚠ 不進版控。由 cx setup env 產生
├── .env.example             三個模式共用的值（映像 tag、DB 憑證、UID/GID）
├── .dockerignore            build context 排除清單（含祕密）
├── .semgrepignore           ⚠ 必須在專案根目錄，Semgrep 只在掃描目標的根目錄找它
├── docker-compose.yml       base（無 ports、無 container_name、無原始碼 mount）
├── bin/
│   ├── lib/                 common / ui / guard / archive + 五支 python 輔助
│   ├── cmd/                 每個動詞一個檔（18 個）
│   └── completion/cx.bash   bash 補全
├── docker/
│   ├── compose/             dev / test / prod / sonar 的 overlay
│   ├── env/                 各模式的埠段與 build target
│   ├── php/                 多階段 Dockerfile + nginx / php-fpm / supervisord
│   ├── nuxt/                多階段 Dockerfile（deps/dev/build/prod/static）
│   ├── edge/                反向代理設定
│   ├── entrypoint/          容器啟動流程
│   ├── waf/                 ModSecurity CRS 排除規則 + proxy 覆蓋
│   ├── security/            trivy / semgrep / zap / gitleaks 設定
│   └── legacy/              舊設定的 .orig 副本（只供對照，不參與建置）
├── ansible/                 12 個 role + site.yml + playbooks
├── docs/                    本文件集
├── reports/                 掃描與驗收輸出（目錄進版控，內容不進）
├── backend/                 submodule → Information-Study/pm-backend
└── frontend/                submodule → Information-Study/pm-frontend
```

---

## 8. 從舊專案來的人

| 舊做法 | 現在 |
|---|---|
| `dc up -d --build` | `cx dev up -d --build` |
| `dc down` | `cx dev down` |
| `dc restart nuxt` | `cx dev restart nuxt` |
| `dc build --no-cache` | `cx dev build --no-cache` |
| `dc run --rm artisan migrate:fresh --seed` | `cx db fresh` |
| `dc run --rm artisan tinker` | `cx art tinker` |
| `dc run --rm composer install` | `cx composer install` |
| `dc run --rm npm ci` | `cx npm ci` |
| `dc run --rm npm-php ci`（**這個 service 從來不存在**） | `cx npm --backend ci` |
| `sh init.sh` | `cx setup && cx dev up -d --build` |
| `sh refresh.sh -t=backend` | `cx git sync && cx setup deps && cx dev up -d --build` |
| `artisan nova:install` | 已改用 Filament：`cx db admin` |
| `git pull --recurse-submodules` | `cx git sync` |

---

## 9. 從子目錄執行

`cx` 可以從專案樹底下的**任何**目錄執行。搜尋順序：

1. 呼叫者的 cwd 往上找 `.cxroot`
2. 找不到才退回 `cx` 自身所在目錄往上找（處理 symlink，所以
   `~/.local/bin/cx` 也能正確定位）

```bash
cd backend                 && cx doctor
cd env/ansible/roles/mysql     && cx deploy syntax
cd docker/compose          && cx dev config
cd bin/lib                 && cx dev up -d
```

`cx install` 之後 `cx` 在 PATH 上，不必寫 `../../cx`。

### 相對路徑參數以「你所在的位置」解析

```bash
cd docs && cx verify static --report ./v.md      # 產生 docs/v.md，不是 pm/v.md
```

`CX_INVOKE_PWD` 在任何 `cd` 之前就記下來，`cx_resolve()` 用它把相對路徑
解析成呼叫者所在位置的路徑。

> 實測驗證過的一個相關缺陷：`cx doctor` 的執行位元檢查曾經用相對路徑做
> `[[ -x $f ]]`，而產生清單的 `cd "$CX_ROOT"` 只發生在 process substitution
> 的子 shell 裡 —— 於是從子目錄執行時 28 個檔案全部被誤報成
> 「磁碟未設執行位元」，在專案根目錄執行卻完全正常。
> **`< <(cd X && ...)` 不會改變迴圈本體的 cwd。**

### 唯一的例外

`--root` 明確指定時不搜尋：

```bash
cx --root ~/pm doctor        # 從專案外執行
```

`--root` 指到的目錄沒有 `.cxroot` 會直接 `EX_PRECOND`。

---

## 10. 三個 repo 一起操作

`cx git` 把「主庫 + 兩個 submodule」當成一個單位。手動對三個 repo 各下一次
git 指令**幾乎一定會弄錯順序**，而弄錯的後果通常不會當場報錯。

```bash
cx git status                 # 三個 repo 的分支 / 變更 / 上游 / 領先落後
cx git fetch                  # 三個一起 fetch --prune（唯讀）
cx git pull                   # 三個一起更新（主庫先、子模組後）
cx git commit -m "feat: ..."  # 子模組先、主庫 gitlink 後
cx git push                   # 子模組先、主庫後
cx git branch new feat/x      # 三個 repo 一起開分支
```

### 順序：commit / push 與 pull 是**相反**的

```
commit / push        pull
─────────────        ─────────────
backend   ┐          pm        ┐
frontend  ├─→ pm     ├─→ backend / frontend
```

**commit / push 是子模組先**：主庫的 gitlink 指向子模組的某個 commit，
那個 commit 必須先存在，否則主庫記錄的是一個「還不存在的東西」。
推錯順序的話別人 clone 下來會是

```
fatal: remote error: upload-pack: not our ref
```

而且看不出是誰造成的。`cx git push` 推完還會用 `git ls-remote` 驗證每個
gitlink 真的存在於對應的遠端。

**pull 是主庫先**：主庫的 gitlink 才是「這一版該用哪個子模組 commit」的
唯一真相。先拉子模組的話，它會被拉到**自己分支的尖端**，而那不一定是
主庫這一版記錄的 commit —— pull 完 `git status` 立刻顯示子模組
「有未提交的變更」，但你其實只是把子模組拉到了別的版本。

### `status` 的數字不連線

`vs origin` 那一行讀的是 remote-tracking ref，不問遠端，所以每一行都附上
**上次 fetch 的時間**。要拿到最新的數字先跑 `cx git fetch`。

### pull 不會自動處理分岔

本地與遠端都各有新 commit 時，`cx git pull` 直接停下來並告訴你三條路
（看差異 / `--allow-merge` / `reset --hard`）。

不自動合併的理由：主庫的**每一個 commit 都帶著子模組的 gitlink**，
自動合併很可能產生一個「backend 用 A 版、frontend 用 B 版」的組合。
那個組合從來沒有人測過，而且 `git status` 看起來完全正常。

### clone 之後第一件事

```bash
git clone --recurse-submodules https://github.com/Information-Study/pm.git
cd pm
./cx git sync          # 子模組從 detached HEAD 接回追蹤分支
```

`--recurse-submodules` 之後子模組一定是 detached HEAD。在那個狀態下提交的
commit 不屬於任何分支，下一次 `submodule update` 就變成孤兒。
`cx git sync` 用 `checkout -B` 把分支帶到目前的 HEAD ——
「回到分支上」與「不丟 commit」兩件事同時成立。
