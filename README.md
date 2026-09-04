# pm

前後端分離：**Nuxt 4（Vue 3）** + **Laravel 13（PHP 8.5）+ Filament v5**，
資料庫 **MySQL 8.4 LTS**，反向代理 **Nginx 1.30**，
測試環境前面再加一層 **ModSecurity + OWASP CRS**。

所有操作都經過單一入口 **`./cx`**。不要直接下 `docker compose` —— 見 [claude.md §4](claude.md) 的四個陷阱。

```
git clone --recurse-submodules https://github.com/Information-Study/pm.git
cd pm
./cx setup                 # .env、目錄、push guard，並盤點缺少的工具
./cx setup tools           # 免 root 安裝 composer / node / ansible / trivy / gitleaks / semgrep
./cx dev up -d --build     # 起開發環境
```

開好之後：

| | 網址 |
|---|---|
| 前端 | http://localhost:8080 |
| 後端 API | http://localhost:8080/api |
| Filament 後台 | http://localhost:8080/admin |
| Nuxt 直連（繞過 edge） | http://localhost:3000 |
| phpMyAdmin | http://127.0.0.1:8891 |

建立後台管理員：`./cx db admin`

常用的三個捷徑：

```bash
./cx code            # 用 VS Code 開整個專案（從任何子目錄都是開專案根）
./cx pma             # 開 phpMyAdmin（只有 dev 有）
./cx php -v          # 直接跑 php
```

### 不想用 Docker？

每一個功能都有**原生工具鏈**的路徑，用 `--runner` 強制：

```bash
./cx --runner native composer install
./cx --runner native npm ci
./cx --runner native test front
./cx setup system                 # 需要 root 的系統套件（會先列指令再問你）
```

被指定的那一邊不可用時會**硬失敗**，不會偷偷換另一邊跑。
兩條路各自需要什麼、產出為何不可互換，見 [`docs/runners.md`](docs/runners.md)。

---

## 三個階段

`cx` 的動詞是照「開發 → 測試 → 部署」這條線排的。

### 第一階段：建立與開發

```bash
./cx setup                    # 初始化（冪等，可以重複跑）
./cx setup tools [名稱...]    # composer node ansible trivy gitleaks semgrep
./cx setup deps               # backend 的 composer install、兩邊的 npm
./cx doctor                   # 檢查還缺什麼、哪裡被擋住

./cx dev up -d --build        # 起開發環境
./cx dev logs -f app          # 追 log
./cx dev sh app               # 進容器（裡面有 art / t 兩個捷徑）
./cx dev down                 # 關閉（加 -v 連資料庫一起刪，會要求確認）

./cx art migrate              # php artisan
./cx composer require foo/bar # composer（在 backend/）
./cx npm install pkg          # npm（在 frontend/）
./cx npm --backend run build  # npm（在 backend/，Laravel 的 Vite 資產）

./cx db status                # 連線資訊、資料表、migration 狀態
./cx db shell                 # 進 mysql client
./cx db dump                  # 備份到 reports/db/
./cx db fresh                 # ⚠ 清空並重建（會要求確認）
./cx db admin                 # 建立 Filament 管理員
```

**dev 模式的特性**：原始碼 bind mount（改了立刻生效）、Nuxt HMR、xdebug（`start_with_request=trigger`）、
phpMyAdmin。`vendor/` 與 `node_modules/` 用具名 volume 蓋回去，所以容器內用的是 Alpine 上編譯的版本，
不會跟 host 的混在一起。

### 第二階段：測試與掃描

```bash
./cx test up -d --build       # 起測試環境（不可變映像 + ModSecurity WAF）
./cx test back                # 後端 PHPUnit（sqlite :memory:，不需要 MySQL）
./cx test front               # 前端型別檢查
./cx test coverage            # 後端覆蓋率（臨時打開 xdebug）

./cx scan code                # ① Quality  Larastan + SonarQube scanner
./cx scan sast                # ② SAST     Semgrep
./cx scan sca                 # ③ SCA      Trivy + composer audit + npm audit
./cx scan dast                # ④ DAST     ZAP（DetectionOnly 與 On 各跑一次做對照）
./cx scan secrets             # gitleaks 全歷史祕密掃描
./cx scan all                 # 依序全跑

./cx sonar up                 # 常駐 SonarQube（獨立 project，dev/test 共用）
./cx sonar token              # 產生分析 token

./cx verify                   # 跑驗收清單，產出 reports/verify/<時間戳>.md
./cx verify all               # 含執行期與 Ansible
```

**test 模式的特性**：原始碼烘進映像（沒有任何原始碼 bind mount，掃到的就是要上線的東西）、
對外入口是 WAF（`ZAP → waf:18081 → edge → app/nuxt`）、
xdebug 有裝但預設關閉（常開會讓 ZAP 的時間量測失真）。

### 第三階段：部署

容器化的正式環境：

```bash
./cx prod up -d --build       # 只發布 80，無管理工具、無 xdebug（build 時斷言）
```

真機部署（Ansible，非容器）：

```bash
./cx deploy syntax            # ansible-playbook --syntax-check
./cx deploy lint              # ansible-lint（production profile）+ yamllint
./cx deploy ping staging      # 確認 SSH 與 become
./cx deploy check staging     # --check --diff 乾跑
./cx deploy apply staging     # ⚠ 真的部署（會列出目標主機並要求確認）
./cx deploy app production    # 只跑應用層，不碰系統層
./cx deploy rollback staging  # 互動式回滾
```

第一次用要先準備 inventory（不進版控）：

```bash
cp ansible/inventory/hosts.yml.example              ansible/inventory/hosts.yml
cp ansible/inventory/group_vars/staging.yml.example ansible/inventory/group_vars/staging.yml
ansible-vault create ansible/inventory/group_vars/vault.yml
```

完整步驟與變數表見 [`ansible/README.md`](ansible/README.md)。

---

## 三個模式可以同時運行

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

---

## 架構

```
                     ┌──────────────────────────────┐
  瀏覽器 / ZAP ────▶ │ waf（僅 test）ModSecurity+CRS │
                     └───────────────┬──────────────┘
                                     ▼
                     ┌──────────────────────────────┐
                     │ edge  nginx 1.30             │
                     │  /                    → nuxt │
                     │  /api /admin /up /storage    │
                     │  /livewire /sanctum   → app  │
                     └───────┬──────────────┬───────┘
                             ▼              ▼
              ┌──────────────────┐  ┌────────────────┐
              │ nuxt  Nitro:3000 │  │ app            │
              │ 或 nginx（static）│  │ supervisord    │
              └──────────────────┘  │  ├ php-fpm     │
                                    │  ├ nginx:8080  │
                                    │  ├ queue ×2    │
                                    │  └ schedule    │
                                    └───────┬────────┘
                                            ▼
                                     ┌────────────┐
                                     │ mysql 8.4  │
                                     └────────────┘
```

**edge 在三個模式都存在**，所以 Docker 拓撲與 Ansible 原生拓撲一致，
`NUXT_PUBLIC_API_BASE_URL=""`（同源）在兩邊都是正確預設。

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

---

## 檔案地圖

```
pm/
├── cx                       統一入口 dispatcher
├── .cxroot                  根目錄標記（含專案名、GitHub 組織、repo 名）
├── .env                     ⚠ 不進版控。由 cx setup env 產生
├── .env.example             三個模式共用的值（映像 tag、DB 憑證、UID/GID）
├── docker-compose.yml       base（無 ports、無 container_name、無原始碼 mount）
├── bin/
│   ├── lib/                 common / ui / guard / archive + 幾支 python 輔助
│   ├── cmd/                 每個動詞一個檔
│   └── completion/cx.bash   bash 補全
├── docker/
│   ├── compose/             dev / test / prod / sonar 的 overlay
│   ├── env/                 各模式的埠段與 build target
│   ├── php/                 多階段 Dockerfile + nginx / php-fpm / supervisord 設定
│   ├── nuxt/                多階段 Dockerfile（deps/dev/build/prod/static）
│   ├── edge/                反向代理設定
│   ├── entrypoint/          容器啟動流程
│   ├── waf/                 ModSecurity CRS 排除規則
│   ├── security/            trivy / semgrep / zap / gitleaks 設定
│   └── legacy/              舊設定的 .orig 副本（只供對照）
├── ansible/                 12 個 role + site.yml + playbooks
├── docs/                    說明書、參考手冊、驗收與進度追蹤
├── reports/                 掃描與驗收輸出（目錄進版控，內容不進）
├── backend/                 submodule → Information-Study/pm-backend
└── frontend/                submodule → Information-Study/pm-frontend
```

---

## 常用對照（從舊專案來的人看這裡）

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

## 紅線

1. **推送有白名單，預設拒絕。** 唯一合法遠端是 `github.com/Information-Study/{pm,pm-backend,pm-frontend}`。
   舊的 `team-of-P/*` **永久禁止**，pre-push hook 不接受任何覆寫旗標。
   合法入口只有 `cx git push`。
2. **任何刪除都要互動確認**，不可逆的還要輸入確認字串。
3. **不要繞過 `cx`。** 直接下 `docker compose` 幾乎一定會錯。
4. **不要用 `--ignore-platform-reqs` 硬過相依衝突**（`cx composer` 會主動拒絕這個旗標）。

完整原理、每個坑的來由、以及未驗證項目清單見 [`claude.md`](claude.md)。
驗收狀態見 [`docs/docker-verification.md`](docs/docker-verification.md) 與 `reports/verify/`。

---

## 文件

| 文件 | 內容 |
|---|---|
| [`docs/manual.md`](docs/manual.md) | **完整操作說明書**，從零開始到三個階段全流程 |
| [`docs/cx-reference.md`](docs/cx-reference.md) | `cx` 每一個動詞的完整參考 |
| [`docs/docker-reference.md`](docs/docker-reference.md) | 合併鏈、三模式差異、多階段映像、edge / WAF |
| [`docs/ansible-reference.md`](docs/ansible-reference.md) | play 結構、12 個 role、vault、實測踩過的坑 |
| [`docs/runners.md`](docs/runners.md) | 兩條 runner：容器與原生各自獨立運作 |
| [`docs/devsecops.md`](docs/devsecops.md) | 四道防線的原理、閘門定義、退出碼 |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | 症狀 → 原因 → 解法 |
| [`docs/reports.md`](docs/reports.md) | 測試與掃描的報告怎麼看 |
| [`docs/template.md`](docs/template.md) | 拿這個 repo 當新專案範本 |
| [`docs/progress.md`](docs/progress.md) | 進度追蹤與「還沒驗證什麼」 |
| [`claude.md`](claude.md) | 設計原理（`docs/` 是「怎麼用」，這份是「為什麼這樣設計」） |

索引與閱讀順序見 [`docs/README.md`](docs/README.md)。
