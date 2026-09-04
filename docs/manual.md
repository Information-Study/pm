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
./cx setup                    # .env、目錄、push guard、collections，並盤點工具鏈
./cx dev up -d --build        # 起開發環境
```

`cx setup` 做的事：

1. 從 `.env.example` 產生 `.env`（隨機密碼、填入你的 UID/GID）
2. 建立 `reports/` 與 `.cx/` 的葉目錄（**必須由你建立**，讓 Docker 建會是 root:root）
3. 安裝三個 repo 的 pre-push hook（白名單防護）
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
| 原始碼 | bind mount（`./backend`、`./frontend`），改了立刻生效 |
| 前端 | Nuxt dev server + HMR |
| xdebug | 已載入，`start_with_request=trigger`（不是 `yes` —— 常開會讓每個請求都去連 IDE） |
| 額外服務 | phpMyAdmin（127.0.0.1:8891） |
| 快取 | 不做 config cache（否則改了 `.env` 完全沒反應，而且那是最難查的那種「沒反應」） |

`vendor/` 與 `node_modules/` 用**具名 volume 蓋回去**。這不是多此一舉：
`./backend:/var/www/html` 會把 image 裡烘好的 vendor 整個遮掉，容器在 entrypoint
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
`backend/phpunit.xml` 的每個 `<env>` 都帶 `force="true"`。
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
cp ansible/inventory/hosts.yml.example              ansible/inventory/hosts.yml
cp ansible/inventory/group_vars/staging.yml.example ansible/inventory/group_vars/staging.yml
ansible-vault create ansible/inventory/group_vars/all/vault.yml   # ⚠ 注意是 all/ 底下
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
docker ps        # 14 個容器，零埠衝突
```

靠的是**兩件事同時成立**：

1. 不同的 compose project（`-p pm_dev|pm_test|pm_prod`）→ 隔離容器、網路、volume
2. 不同的 host 埠段（`docker/env/<mode>.env`）→ 隔離埠

> `-p` **不隔離 host 埠**。只做第 1 件不做第 2 件，第二個模式會直接
> `Bind for 0.0.0.0:8080 failed: port is already allocated`。

| | dev | test | prod |
|---|---|---|---|
| HTTP（edge） | 8080 | 18080 | **80** |
| WAF | — | 18081 | — |
| Nuxt 直連 | 3000 | 13000 | 不發布 |
| MySQL | 127.0.0.1:3306 | 127.0.0.1:13306 | 不發布 |
| phpMyAdmin | 8891 | — | — |
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

1. **推送有白名單，預設拒絕。**
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
cd ansible/roles/mysql     && cx deploy syntax
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
