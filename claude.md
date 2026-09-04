# claude.md — pm 專案指南

> 專案代號 **pm**（原 pm）。
> 本機路徑 `~/pm`；遠端 `github.com/Information-Study/{pm, pm-backend, pm-frontend}`。

> 給 AI 助理與開發者閱讀。動手改任何東西之前，先讀完「紅線」與「守則」兩節。
>
> 本文件中所有標註「實測」「已驗證」的結論，都是對抗驗證階段實際在本機或上游原始碼／registry
> 確認過的，不是推測。遇到與此處敘述衝突的直覺，請先相信本文件。

---

## 0. 紅線（Hard Rules）

1. **推送有嚴格白名單，預設拒絕。**
   唯一合法的遠端是 `github.com/Information-Study/{pm, pm-backend, pm-frontend}`。
   舊的 `team-of-P/*` 遠端**永久禁止推送**。
   三個 repo 都裝了 `pre-push` hook，會同時檢查兩件事：
   (a) 目標 URL 必須落在 Information-Study 白名單內；(b) `CX_ALLOW_PUSH=1` 必須顯式設定。
   **AI 助理不得在使用者未於當次對話明確指示的情況下推送**，也不得為了繞過失敗而放寬白名單。
   合法入口只有 `cx git push`（會要求確認）。

2. **任何刪除必須有互動確認。**
   刪檔、`DROP DATABASE`、`rm -rf`、`docker volume rm`、release prune —— 全部要先 Y/n；
   不可逆的還要輸入確認字串。
   **不得在對話中要求使用者盲目執行刪除指令**，必須封裝進有確認閘門的腳本。

3. **不要繞過 `cx`。**
   直接下 `docker compose` 幾乎一定會錯（見 §4 的四個陷阱）。

4. **不要用 `--ignore-platform-reqs` 或 `-W` 硬過相依衝突。**
   正確診斷是 `composer why-not <pkg> <ver>`。

5. **不要在容器裡裸跑 `php artisan test`，一律用 `cx test`。**
   `backend/phpunit.xml` 的 `<env force="true">` 在容器裡**是無效的**：
   PHPUnit 的 force 只寫 `putenv()` 與 `$_ENV`，不寫 `$_SERVER`，
   而 Laravel 的 `Env` 讀 `$_SERVER` 優先 —— compose 的 `environment:`
   永遠贏。實測裸跑會打到真正的 dev MySQL，而不是 `sqlite :memory:`。
   目前沒有測試用 `RefreshDatabase`，一旦有人加了，裸跑就會清空開發資料庫。
   真正的保護在 `bin/cmd/test.sh` 的 `_test_env_pairs`（用 `-e` 蓋掉 `$_SERVER`）。

6. **Agent 併發上限：同時最多 5 個，同類型最多 3 個。**
   使用 Workflow 時要把 `parallel()` / `pipeline()` 的項目分批送出，每批不超過 5；
   同一批內相同角色（例如多個 `verify:*`）不超過 3。

---

## 0.5 目前進度

> 逐項的機器可驗狀態見 [`docs/progress.md`](docs/progress.md) 與 `cx verify` 的輸出。
> 本節只記結論。

| Phase | 內容 | 狀態 |
|---|---|---|
| 0 | 本文件 | ✅ 完成 |
| 1 | 更名 `~/PSYOP_DutyManager` → `~/pm`；`cx` 骨架；備份；刪除舊紀錄 | ✅ 完成 |
| 2 | `docker/` 三模式 + 多階段 Dockerfile + 新 `docker-compose.yml` | ✅ **完成並實測**（2026-09-04） |
| 3 | 重建前後端 + 三 Git 初始化 + 推送 | ✅ 完成；migration / 測試 / 端點皆已實跑 |
| 4 | DevSecOps 工具鏈 + `cx scan` | ✅ 四道防線全部跑得動 |
| 5 | Ansible roles + playbook | ⚠ 靜態全綠（syntax-check + lint），**尚未上真機** |
| 6 | `README.md`、`ansible/README.md`、`docs/progress.md` | ✅ 完成 |

### 2026-09-04 的環境變更（重要）

這一天之前，本專案是在「**沒有 Docker、沒有資料庫、沒有 pip**」的環境下開發的，
所以 §12 有一份很長的未驗證清單。當天解除的阻擋：

| 阻擋 | 解除方式 |
|---|---|
| Docker daemon 不可用 | 安裝 Docker Engine 29.7.2 + `sudo usermod -aG docker $USER` + **`wsl --shutdown` 再重開** |
| 無 pip / venv → 裝不了 ansible | `python3 -m venv --without-pip` + `get-pip.py`，全程免 root（`cx setup tools ansible`） |
| 無 composer / node | `cx setup tools composer node`，從官方 release 下載並核對 SHA256 |
| `pdo_sqlite` 缺席擋住 `artisan test` | 加進容器映像（host 端仍缺，但 `cx test back` 走容器） |

> ⚠ `usermod -aG docker` **只影響之後才建立的登入 session**。
> 在 WSL 上一定要 `wsl --shutdown`（Windows 端）再重開，否則 `docker ps` 仍是
> `permission denied while trying to connect to the docker API`，而那個訊息
> 完全不會提示你「群組已經加好了，只是還沒生效」。這是本專案卡最久的環境問題。

### 已完成的清理（2026-09-03）

封存於 `~/pm_archive/<timestamp>/`，**已做過獨立復原演練，113 個 commit 全數可還原**：

| 檔案 | 內容 |
|---|---|
| `git-{main,backend,frontend}.bundle` | 完整 git 歷史（6 / 69 / 38 commits） |
| `gitdir-{main,backend,frontend}.tar.gz` | 真實 gitdir（含 config/hooks/logs） |
| `src-{backend,frontend}.tar.gz` | 原始碼（排除 node_modules/vendor/.nuxt/.output） |
| `MANIFEST.txt` + `SHA256SUMS` | 還原中繼資料與校驗碼 |

已刪除：`.git`、`.gitmodules`、`backend/`、`frontend/`、`php/`、`nuxt/`、
`init.sh`、`refresh.sh`、`README.md`、`docker-compose.yml`、`.dockerignore`。

**Docker 自定義設定全部保留**（使用者明確要求），遷移至 `docker/php/`、`docker/nuxt/`、
`docker/legacy/*.orig`。Phase 2 完成後，舊的單階段檔已全數移入 `docker/legacy/`：

| 舊檔 | 現況 |
|---|---|
| `docker/php/dockerfile.development` | → `docker/legacy/php-dockerfile.development.orig` |
| `docker/nuxt/dockerfile`（小寫） | → `docker/legacy/nuxt-dockerfile.orig`。**它原本與新的 `Dockerfile` 並存，正是缺陷 D1 的陷阱本身** |
| `docker/php/xdebug.ini` | → `docker/legacy/php-xdebug.ini.orig`（改由 entrypoint 依環境變數生成） |
| `docker/php/laravel-queue.conf` | 併入 `docker/php/supervisord.conf`（原本寫死 `--queue=media-library`，是別的專案的殘留） |

### 已完成的重建（2026-09-03，原生方式）

Docker daemon 不可用，因此改以原生工具鏈建立。**遠端已上線**：

| Repo | URL | 檔案數 |
|---|---|---|
| 主庫 | https://github.com/Information-Study/pm | 34 |
| 後端 | https://github.com/Information-Study/pm-backend | 101 |
| 前端 | https://github.com/Information-Study/pm-frontend | 10 |

已用 `git clone --recurse-submodules` 從遠端實際驗證：submodule 相對 URL 解析正確、
內容完整、無 `.env`／金鑰外洩、`reports/` 目錄有跟著 clone 下來。

#### 實際解析到的版本（與規劃階段的假設有出入處已標註）

| 元件 | 版本 | 備註 |
|---|---|---|
| PHP | 8.5.4（系統） | Ubuntu 26.04.1 LTS 內建 |
| Composer | 2.10.3 | `~/.local/bin/composer`（免 root） |
| Node | 24.20.0 | `~/.local/node`，SHA256 對過 nodejs.org 官方 SHASUMS256.txt |
| npm | 11.19.0 | |
| Laravel | 13.17 | |
| Filament | 5.7.8 | 需要 `ext-intl` |
| Larastan | 3.11.0 | level 5 + `checkModelProperties`，**0 errors** |
| Nuxt | 4.5.2 | 精確鎖版 |
| vue-router | **5.3.1** | ⚠ 因為沒有手寫進 dependencies，npm 才解對。手寫 `^4` 會被 Vite dedupe 到 v4，首次導航就壞 |
| pinia | **4.0.3** | ⚠ 與規劃假設（pinia 3 + `@pinia/nuxt` 0.11.3）不同 |
| `@pinia/nuxt` | **1.0.2** | ⚠ 生態系已前進，peer 相容，無需手動鎖 pinia 版本 |

#### 前端三模式皆已實測建置

| 模式 | 指令 | 產出 |
|---|---|---|
| ssr | `nuxt build` | `.output/server/index.mjs` → PM2 fork |
| spa | `NUXT_SSR=false nuxt build` | `.output/server/index.mjs`（ssr 關閉） |
| static | `NUXT_SSR=false nuxt generate` | `.output/public/` → Nginx 直送 |

#### PHP 擴充現況

| 擴充 | 狀態 | 需要嗎 |
|---|---|---|
| `intl` | ✅ 已安裝（ICU 78.2） | **Filament v5 硬性需求** |
| `bcmath` | ✘ 未安裝 | Laravel 13 與 Filament v5 皆未要求 |
| `sqlite3` / `pdo_sqlite` | ✘ 未安裝 | 本專案用 MySQL，非必要；但 `artisan test` 若用記憶體 sqlite 會需要 |

> 補裝：`sudo apt install -y php8.5-bcmath php8.5-sqlite3`（sudo 需要人工輸入密碼）

#### push guard 已實測 7 種情境

| 情境 | 結果 |
|---|---|
| 黑名單 `team-of-P/*` | 擋下 |
| 黑名單 + `CX_ALLOW_PUSH=1` | **仍擋下**（黑名單不接受覆寫） |
| 第三方組織 | 擋下 |
| 白名單但未解鎖 | 擋下（預設拒絕） |
| 白名單 + 解鎖 | 放行 |
| SSH 形式白名單 | 放行 |
| 前綴繞過 `Information-Study-Evil` / `pm-other` | 擋下 |

---

## 1. 技術棧

| 層 | 技術 |
|---|---|
| 前端 | Vue 3 + Nuxt 4（Node 24 **Active LTS**；原生部署由 PM2 守護） |
| 後端 | PHP 8.5 + Laravel 13 + Filament v5（Composer） |
| 靜態分析 | Larastan（PHPStan 2.x） |
| 資料庫 | MySQL 8.4 **LTS** |
| 網頁伺服器 | Nginx **1.30 stable**（Docker 內為 edge；原生為 MyGuard 版 + ModSecurity） |
| 容器 | Docker Compose v2，三模式 dev / test / prod |
| 部署 | Ansible（原生，非容器） |
| 工具 | `./cx`（Bash + whiptail） |

### 版本相容性（已驗證）

| 項目 | 事實 |
|---|---|
| `laravel/laravel` v13.10.1 | `php ^8.3`、`laravel/framework ^13.17`、`laravel/tinker ^3.0` |
| `filament/support` v5.7.8 | `illuminate/contracts: ^11.28\|^12.0\|^13.0` → **確認支援 Laravel 13** |
| `filament/filament` v5.7.8 | `require` 只有 `php ^8.2` 與自家子套件 |
| `larastan/larastan` v3.11.0 | `illuminate/* ^11.44.2 \|\| ^12.4.1 \|\| ^13`、`phpstan/phpstan ^2.2.2` |
| `php:8.5-fpm-alpine` | 存在（registry HTTP 200） |
| nuxt dist-tags | `latest: 4.5.2`，無 5.x on latest —— 但仍須鎖版 |
| nuxt 4.5.2 | 需 `vue-router ^5.2.0`；`engines.node: ^22.19.0 \|\| ^24.11.0 \|\| >=26.0.0` |
| `@pinia/nuxt` 0.11.3 | `peerDependencies: pinia ^3.0.4`（pinia latest 已是 4.0.3） |
| `vuedraggable` 4.x | **是 Vue 3 線**，不是 Vue 2 遺物，要保留 |

> Composer 的 `^8.2` 語意是 `>=8.2.0 <9.0.0`，**包含 PHP 8.5**。
> 看到 `"php": "^8.2"` 不要誤判成「不支援 8.5」。

### LTS 政策（重要：有三個技術棧根本沒有 LTS 制度）

| 元件 | 採用 | LTS 狀態 |
|---|---|---|
| Node.js | **24.20-alpine** | **Active LTS**，維護到 2028-04-30。26 是 Current，2026-10 才進 LTS，不採用 |
| MySQL | **8.4** | **LTS**，支援到 2032-04。9.x 是 Innovation track，每版只有 8 個月支援，**不可採用** |
| Nginx | **1.30-alpine** | **stable 分支**（nginx 沒有 LTS，stable 是其對應物）。1.29 已 EOL，1.31 是 mainline |
| SonarQube | **2026-lta-community** | **LTA**（Long-Term Active）2026.1，每個 LTA 活躍 18 個月 |
| PostgreSQL | **17** | 支援中（每個 major 5 年） |
| Ubuntu（Ansible 目標） | **24.04 LTS (noble)** | 26.04 LTS (Resolute Raccoon) 已於 2026-04-23 釋出，為選項但需先確認 MyGuard 支援該 codename |

**沒有 LTS 可選的三個**，不要浪費時間找：

- **PHP 沒有 LTS 制度。** 每個 branch 是 2 年 active + 2 年 security。
  而且**往回退更糟**：PHP 8.4 的 active support 只到 2026-12-31，
  8.5 則是 active 到 2027-12-31、security 到 2029-12-31。
  **8.5 是目前支援期最長的選擇**，這就是採用它的理由。
- **Laravel 自第 7 版起取消 LTS**（最後一個 LTS 是 Laravel 6）。
  現在全部統一 18 個月 bugfix + 2 年 security。Laravel 13 是支援期最長的。
- **Nuxt 與 Filament 沒有 LTS 概念。**

> 若有人要求「全部改用 LTS」，正確回答是：可調整的只有 nginx 與 SonarQube 兩個 tag，
> 其餘不是已經是 LTS（Node / MySQL），就是該技術棧沒有 LTS（PHP / Laravel / Nuxt / Filament）。

---

## 2. Git 結構

三個獨立 repo，main 大庫以 submodule 統籌：

```
~/pm/                     ← main 大庫 → Information-Study/pm
├── backend/              ← submodule       → Information-Study/pm-backend
└── frontend/             ← submodule       → Information-Study/pm-frontend
```

三個 repo 都是 **public**，都在 `Information-Study` 組織下。
舊的 `team-of-P/*` 三個遠端在重建時一併移除，且列入 push hook 的黑名單。

### ⚠ 最重要的一件事

**`backend/.git` 與 `frontend/.git` 是指標檔，不是目錄。**

```
$ cat backend/.git
gitdir: ../.git/modules/backend        # 32 bytes
```

真正的物件庫在 `.git/modules/backend` 與 `.git/modules/frontend`。
**任何備份腳本若只 `tar` 子目錄，只會封存那個指標檔，全部 commit 歷史會消失。**

正確做法是兩者並用：

```bash
git -C backend bundle create "$ARCHIVE/git-backend.bundle" --all HEAD
gd=$(git -C backend rev-parse --absolute-git-dir)
tar -czf "$ARCHIVE/gitdir-backend.tar.gz" -C "$(dirname "$gd")" -- "$(basename "$gd")"
echo "backend_gitdir=$(realpath --relative-to="$PWD" "$gd")" >> "$ARCHIVE/MANIFEST.txt"
```

MANIFEST 一定要記錄 gitdir 的位置：`git submodule add` 對「已經是有效 repo」的目錄
**不會 clone、也不會 absorb gitdir**，所以重建後 `.git` 可能是真目錄而非指標檔，
還原路徑會跟備份時不同。

### submodule 的三個坑，以及 cx 怎麼幫你藏起來

| 坑 | `cx` 的處理 |
|---|---|
| clone 後子模組是 detached HEAD | `cx git sync` 自動 checkout 追蹤分支 |
| 每次都要多一個「更新子模組指標」commit | `cx git save` 一次做完子模組 commit + 大庫指標 commit |
| 掃描 / CI 需要 `--recurse-submodules` | `cx` 所有掃描動詞都以大庫為根，自然涵蓋 |

### 其他 git 注意事項

- 根 `.gitignore` **不可**列入 `backend/` 或 `frontend/` —— 被 ignore 的路徑會讓
  `git submodule add` 失敗（除非 `--force`）。

### 推送流程（只在重建完成後執行一次）

順序是**強制**的：舊 git 紀錄必須先徹底移除、三個 repo 重新初始化完成，才建立遠端。

```bash
# 1) 重建完成、三個本地 repo 都有 initial commit 之後
cx git remote-init          # 用 gh 建立三個 public repo 並設定 origin

# 實際執行的等價指令：
gh repo create Information-Study/pm-backend  --public --disable-wiki -d "pm 後端 — Laravel 13 + Filament v5"
gh repo create Information-Study/pm-frontend --public --disable-wiki -d "pm 前端 — Vue 3 + Nuxt 4"
gh repo create Information-Study/pm          --public --disable-wiki -d "pm — 統籌大庫"

# 2) 推送（子模組先、大庫後，因為大庫的 gitlink 指向子模組的 commit）
cx git push                 # 會逐一確認，並自動處理子模組先後順序
```

**推送前 `cx` 一定會做的三件事**（`cx git push` 內建，不可跳過）：

1. **遠端白名單檢查** —— URL 必須是 `github.com/Information-Study/pm{,-backend,-frontend}`。
2. **祕密掃描** —— 因為三個 repo 都是 **public**。至少要擋掉：
   `.env`、`*.key`、`*.pem`、`.secrets/`、`auth.json`、以及舊 README 那種
   明文帳密（舊版 README 曾寫過真實的管理帳號與密碼）。用 Trivy secret scan + gitleaks 規則。
3. **子模組順序** —— 先 `pm-backend`、`pm-frontend`，最後才 `pm`。
   反過來會讓大庫的 gitlink 指向遠端不存在的 commit。

**永久黑名單**：`team-of-P/PSYOP_DutyManager{,-backend,-frontend}.git`。
pre-push hook 對這三個 URL 一律拒絕，不接受任何覆寫旗標。
- 本地無 remote 時 `git submodule add ./backend` 可行。git-submodule(1) 明文：
  superproject 未設定預設 remote 時，以自身為權威上游、用當前工作目錄。
- 未來要接真 remote 時，相對 URL 要寫 `../foo.git` 而非 `./foo.git`。

---

## 3. 全新初始化守則

```bash
./cx fresh                      # 預設 carryover：重建骨架後把業務碼搬回
./cx fresh --mode backup-only   # 只備份，不刪任何東西 —— 先用這個確認封存可用
./cx fresh --mode scaffold      # 純淨重建，需額外輸入 NO CARRYOVER
./cx fresh --rollback [--from <dir>]
```

執行順序是**固定**的，不可調換：

```
preflight → 備份（原始碼 + git bundle + 真實 gitdir + mysqldump）
          → 驗證封存（sha256sum / git bundle verify / tar -t）
          → 確認閘門（whiptail Y/n + 輸入確認字串）   ← 在此之前不刪任何東西
          → 刪除 → 重建前後端 → 三 Git 初始化 → 裝 push guard
```

### 守則

- **驗證要排在確認之前。** 這樣壞掉的封存會在樹還完整時就中止，而不是刪完才發現。
- **確認閘門的 UI 必須畫在真 tty。** whiptail 把對話框畫在 **stdout**
  （實測 `whiptail --infobox` 在 stdout 回傳 597 bytes 逸出序列，這正是
  `3>&1 1>&2 2>&3` 慣用法存在的原因）。若先做了 `exec > >(tee log)` 再叫 whiptail，
  對話框會被寫進 log 檔，操作者面對的是**凍結的空白畫面**卻被要求輸入確認字串。
  正解：

  ```bash
  exec 8>&1 9>&2                                   # 先存下真 tty
  exec > >(tee -a "$ARCHIVE/fresh.log") 2>&1
  wt_yesno(){ whiptail "$@" 1>&8 2>&9; }
  wt_input(){ local f; f=$(mktemp); whiptail "$@" 2>"$f" 1>&8; local rc=$?
              cat "$f"; rm -f "$f"; return $rc; }
  ```
  判斷是否互動要用 `[ -t 8 ]`，不能用 `[ -t 1 ]`（fd1 現在永遠是 pipe）。

- **封存必須包含 `mysqldump`。** 只備份原始碼會漏掉 `mysql-data` volume 裡的資料，
  而重建後 `migrate --force` 會撞上倖存的資料表（`Table 'users' already exists`）；
  若 compose project name 改變，整份資料會在舊 project name 底下**無聲孤兒化**。
  確認對話框的刪除清單必須列出資料庫。

- **封存放在專案外**（`~/pm_archive/<timestamp>/`），
  這樣刪除 `.git` 不會波及它。路徑要 `readlink -f` 正規化成絕對路徑。
- **資料夾改名 `~/PSYOP_DutyManager` → `~/pm` 是 Phase 1 的第一步**，要獨立確認閘門。
  改完之後你的 shell 需要 `cd ~/pm`，IDE 專案路徑也要重開。
- **舊 git 紀錄必須在建立任何遠端之前徹底移除**（使用者明確要求）。
  順序：封存 → 刪 `.git` → 重建三 repo → `cx git remote-init` → `cx git push`。

- **scaffold 指令一律鎖版**：`laravel/laravel:^13.0`、`filament/filament:^5.0`、
  `larastan/larastan:^3.11`、nuxt 精確版本。
  `npm create nuxt@latest` 今天還是給 Nuxt 4（dist-tag `latest: 4.5.2`），但遲早會翻到 5。

### 重建過程的六個陷阱

1. **Laravel scaffold 必須在單一容器內完成。**
   `docker compose run --rm` 每次都是新的可拋容器，`/tmp/skel` 隨 A 容器一起消失：
   ```bash
   phpsh 'set -e
     composer create-project laravel/laravel:^13.0 /tmp/skel --no-interaction --prefer-dist --no-scripts
     cp -a /tmp/skel/. /var/www/html/
     rm -rf /tmp/skel
     composer install --no-interaction --prefer-dist'
   ```

2. **`--no-deps` 不可用於碰資料庫的指令。** 要拆兩個 helper：
   `phpsh`（`--no-deps`，只跑 composer / key:generate / storage:link）與
   `phpdb`（不加 `--no-deps`，跑 install:api / migrate / make:filament-user），
   並在 `phpdb` 之前加 `mysqladmin ping` 就緒等待。
   注意 Laravel 13 的 `install:api` 會**預設 true** 詢問要不要 migrate，
   `--no-interaction` 下會直接對著沒起來的 DB 跑。

3. **刪除後要先 `mkdir -p backend frontend` 再叫 compose。**
   否則 Docker 會以 root:root 0755 自動建立 bind mount 來源，
   容器內的 uid 1000 寫不進去，非 root 的操作者也刪不掉。

4. **`docker-compose.yml` 是 MIGRATE 目標，不是 PRESERVE 目標。**
   舊檔指向 `php/dockerfile.development`，而 `php/` 正要被刪。

5. **不要用 `sed` 套用密碼。** base64 會產生 `/` 與 `+`，`&` 是 sed 的整段回填 →
   密碼被靜默竄改，一小時後才以 `Access denied` 現形。用 bash 字面替換：
   ```bash
   line=${line//__DB_PASSWORD__/$CX_DB_PASSWORD}
   ```
   並把生成字元集限制在 `A-Za-z0-9`。

6. **要發布並設定 `config/cors.php`。** Laravel 11+ 不再內建該檔，
   框架預設是 `allowed_origins: ['*']` + **`supports_credentials: false`** →
   dev 的跨源 Sanctum SPA 在 `/sanctum/csrf-cookie` 就被 CORS 擋死，Sanctum 怎麼設都沒用。
   （test/prod 走同源 edge，此項無害，所以只需要 dev 正確。）

### 三 Git 初始化順序

```
backend  git init → commit          # submodule 不能加在未出生的 HEAD 上
frontend git init → commit
main     git init → git submodule add ./backend → ./frontend → commit
         → 三個 repo 都裝 push guard
```

---

## 4. Docker 三模式

```bash
./cx dev  up -d        # 開發：bind mount、HMR、xdebug、phpMyAdmin
./cx test up -d        # 測試：不可變映像、ModSecurity WAF、掃描工具
./cx prod up -d        # 正式：錯誤關閉、無管理工具、無掃描器
```

三個模式**可以同時運行**，靠的是兩件事同時成立：

1. 不同的 compose project（`-p pm_dev|pm_test|pm_prod`）→ 隔離容器、網路、volume。
2. 不同的 **host 埠段**（`docker/env/<mode>.env`）→ 隔離 port。

> **`-p` 不會隔離 host 埠。** 只做 1 不做 2，第二個模式會直接
> `Bind for 0.0.0.0:8080 failed: port is already allocated`。

| | dev | test | prod |
|---|---|---|---|
| HTTP | 8080 | 18080 | 80 |
| Nuxt | 3000 | 13000 | — |
| MySQL | 127.0.0.1:3306 | 127.0.0.1:13306 | **不開** |
| phpMyAdmin | 8891 | 18891 | **不開** |
| WAF | — | 18081 | — |
| SonarQube | 9000（共用常駐 stack） | 同左 | — |

### 直接下 docker compose 的四個陷阱

1. **相對路徑以「第一個 `-f` 檔案的目錄」為基準**，不是你的 cwd。
   `cx` 一律加 `--project-directory "$CX_ROOT"` 當作順序無關的錨點。
2. **`ports:` 是附加合併**（鍵為 `{ip,target,published,protocol}`），不是覆寫
   → base 檔**完全不能有 `ports:`**，否則 overlay 的埠會被「加上去」而非取代。
3. **顯式 `--env-file` 缺檔是硬錯誤**（隱式 `./.env` 才會靜默略過）
   → `cx` 條件式組出清單，只加存在的檔。
4. **網路名會被命名空間化成 `<project>_<key>`**
   → compose 裡要明寫 `name:`，否則 `docker run --network pm_test_net` 找不到網路。

### 映像 tag 必須含模式

```yaml
image: ${IMAGE_PREFIX:-pm}/nuxt:${APP_MODE:-dev}-${NUXT_TARGET:-dev}-${FRONTEND_MODE:-ssr}
image: ${IMAGE_PREFIX:-pm}/app:${APP_MODE:-dev}-${APP_TARGET:-dev}
```

spa / static 的 API base URL 是 **build 時**烘進 bundle 的。
若 test 與 prod 共用同一個 tag，`cx test up`（未加 `--build`）會拿到 prod 的 bundle，
**測試環境就會打到正式 API**。`-p` 隔離容器與網路，但**不隔離映像 tag**。

### Dockerfile stage 對照

| stage | 用途 | 關鍵點 |
|---|---|---|
| `base` | 共用擴充、nginx、supervisor、composer | 用 `mlocati/php-extension-installer`，**不要用 `pecl install`**（已被 Xdebug 官方標為 deprecated，且在 Alpine PHP 8.4+ 有 `Constant E_STRICT is deprecated` → `Filename too long` 的已知失敗） |
| `vendor-dev` | dev/test 的 vendor | **不可加 `--no-autoloader`** —— 否則 `vendor/autoload.php` 不存在，容器在 entrypoint 就 fatal |
| `vendor-prod` | prod 的 vendor | `--no-dev`，之後由 prod stage 跑 `dump-autoload --classmap-authoritative` |
| `dev` | 開發 | **不 COPY 原始碼**（bind mount 會蓋掉）；只烘 vendor 供具名 volume 種子化 |
| `test` | 受測物 | COPY 原始碼；xdebug 裝但 `XDEBUG_MODE=off`（僅供覆蓋率觸發） |
| `prod` | 正式 | COPY 原始碼；opcache + preload；**build 斷言 `! php -m \| grep -qi xdebug`** |

其他必守事項：

- `CMD` 交給 supervisord，由它同時管 php-fpm、nginx、queue worker、scheduler。
  舊版的 `CMD ["sh","-c","php-fpm -D && nginx …", "supervisord …"]` 第 4 個元素會變成
  `sh -c` 的 `$0`，supervisord 從未啟動 —— queue worker 從來沒跑過。
- **`php` service 不可宣告 `entrypoint:`**，image ENTRYPOINT 要保持
  `docker-php-entrypoint` 的 argv 直通，否則 `compose run --rm php composer …`
  會變成 `<entrypoint> composer …`。
- **test 模式的 `DB_FRESH` 必須用哨兵檔一次性化。**
  base 是 `restart: unless-stopped`，entrypoint 每次啟動都跑 →
  一次 OOM kill 就會在 ZAP 掃描中途 `migrate:fresh --seed`，掃描結果全部失真。
- **dev 的 `NUXT_SSR` 走 runtime `environment:`，不是 build arg**（build arg 進不了 `nuxt dev`）。
- `NGINX_IMAGE` 至少 `nginx:1.30-alpine`。1.29 已 EOL，會變成自家 Trivy 掃出的最大漏洞來源。

### 前端三模式

| 模式 | 建置 | 執行 | API base URL 決定時機 |
|---|---|---|---|
| `ssr` | `nuxt build` | Node/PM2 跑 `.output/server/index.mjs` | **啟動時**（可用環境變數） |
| `spa` | `nuxt build`（ssr:false） | Node/PM2 跑 Nitro | **build 時**（烘進 bundle） |
| `static` | `nuxt generate` | Nginx 直送 `.output/public` | **build 時**（烘進 bundle） |

**PM2 一律用 `exec_mode: 'fork'`。** cluster 模式走 CJS `ProcessContainer` 的 `require()`，
載不動 Nuxt 的 ESM `.mjs`（`ERR_REQUIRE_ESM`；Node 24 上就算 `require(esm)` 過了，
Nitro 的 top-level await 會變 `ERR_REQUIRE_ASYNC_MODULE`）。上游 pm2#5946、nuxt#13916 均未解。
要水平擴充就開多個 fork 到多個埠，讓上游 nginx `least_conn`；Docker 端用 `--scale`。

`edge` nginx 在**三個模式都存在**，路由 `/` → Nuxt、`/api|/admin|/up|/storage|/livewire` → PHP。
這讓 Docker 拓撲與 Ansible 原生拓撲一致，也讓 `NUXT_PUBLIC_API_BASE_URL=""`（同源）成為正確預設。

---

## 5. DevSecOps —— 四道防線

```
① Quality ── SonarQube(常駐) + Larastan
② SAST    ── Semgrep(短暫)
③ SCA     ── Trivy(短暫)
④ DAST    ── OWASP ZAP(短暫) + ModSecurity WAF
```

| 防線 | 抓什麼 | 何時跑 | 閘門 | 報告 |
|---|---|---|---|---|
| ① Quality | 型別錯誤、複雜度、重複、覆蓋率、歷史趨勢 | commit 前 / PR | Larastan level 達標 + Sonar Quality Gate PASSED | `reports/quality/` |
| ② SAST | 注入、XSS、硬編憑證、不安全 API 用法 | commit 前 / PR | 無 ERROR 等級 finding | `reports/sast/` |
| ③ SCA | 相依 CVE、憑證外洩、IaC 錯配、映像漏洞 | PR / 每日 | 無 HIGH/CRITICAL（除非在 `docker/security/trivy/.trivyignore.yaml` 且有到期日） | `reports/sca/` |
| ④ DAST | 執行期真實攻擊面 | 合併前 / 發版前 | 無 High risk alert | `reports/dast/` |

### 為什麼是這個順序

**由內而外、由便宜到昂貴。**
①②③ 不需要啟動應用，秒到分鐘級；④ 需要完整環境跑起來，分鐘到小時級。
前三道先擋掉大部分問題，ZAP 才不會把時間浪費在明顯的低級錯誤上。

**ModSecurity 的雙重角色**：正式環境的防護層；同時是 test 模式下的對照組 ——
同一份 ZAP 掃描分別在 `MODSEC_RULE_ENGINE=DetectionOnly` 與 `On` 各跑一次，
兩者的差異就是 WAF 的實際攔截率。

```bash
./cx scan code     # ① Larastan + SonarQube scanner
./cx scan sast     # ② Semgrep
./cx scan sca      # ③ Trivy（fs + secret + misconfig + image）
./cx scan dast     # ④ ZAP（先 DetectionOnly 再 On，輸出對照）
./cx scan all      # 依序全跑
./cx sonar up      # 啟動常駐 SonarQube（dev/test 共用）
./cx sonar token   # 產生／輪替分析 token
```

### 掃描工具的共通陷阱

- **掃描器都以 uid 1000 執行。** 掛在「image 中不存在的路徑」上的具名 volume
  一律被 Docker 建成 root:root 0755 → 非 root 的 Trivy / Semgrep / PHPStan / ZAP 全部 EACCES。
  所有輸出與快取目錄由 `cx` 以呼叫者身分預先 `mkdir -p`，並用專案內 bind 目錄而非具名 volume。

- **`.gitignore` 要寫 `/reports/*` 加負向規則，不能寫 `/reports/`。**
  gitignore(5) 明文：父目錄被排除就無法 re-include 子檔案，git 甚至不會進去讀巢狀 .gitignore。
  寫錯的話 `reports/` 不進版控 → fresh clone 沒這個目錄 → Docker 以 root:root 建立 →
  ZAP `PermissionError`，還在工作目錄留下 root 所有的垃圾。
  ```gitignore
  /reports/*
  !/reports/.gitignore
  !/reports/README.md
  ```

- **短暫容器不要固定 `--name`。** `--rm` 在 CLI 被 SIGKILL、daemon 重啟、OOM 時不會執行，
  下一次就 `Conflict. The container name is already in use`。

- **「找到東西」和「工具當掉」是不同的事。** 在 `set -Eeuo pipefail` + ERR trap 下，
  Trivy 找到一個 HIGH CVE 就會噴 stack dump 並 `exit 1`。`cx` 顯式捕捉 exit code
  並映射到專屬的 `EX_SCAN_*`，把 exit 2（工具內部錯誤）與 exit 1（有 finding）分開。

- **SonarQube 容器只有 `curl` 沒有 `wget`**（基於 `eclipse-temurin:25-jdk-noble`，
  只裝了 `bash curl fonts-dejavu`）。healthcheck 寫成 wget 會永遠 unhealthy，
  任何 `condition: service_healthy` 依賴都會死鎖。2026.1+ 另需 `/tmp` 可讀寫。

- **`sonar-scanner` 要加入 sonar 網路並用 `http://sonarqube:9000`。**
  傳 `localhost` 進容器指的是容器自己。

- **`sonar.sources` / `sonar.tests` 只能列實際存在的目錄。**
  路徑不存在是 scanner 的 ERROR 中止，不是 warning ——
  但看起來會很像「Quality Gate 失敗」，其實根本沒分析。

- **`SEMGREP_RULES_CACHE_DIR` 不是 Semgrep 的環境變數**（原始碼 `env.py` 無此名）。
  要快取就把 `HOME` 指到快取目錄。

- **Trivy 的 `ignorefile:` / `secret.config:` 相對容器 CWD 解析**，
  而 `aquasec/trivy` 沒有 WORKDIR（CWD 是 `/`）→ 必須寫容器內絕對路徑並固定 `-w`。

- **ModSecurity audit 預設 `SecAuditLogType Serial`，只寫 stdout。**
  `MODSEC_AUDIT_STORAGE_DIR` 那顆 volume 是空的。要從
  `compose logs --no-log-prefix --no-color waf | grep '^{'` 取，
  否則 WAF ↔ ZAP 對照完全沒有資料。

- **CRS 排除規則必須載入在 CRS 之前。** `ctl:ruleRemoveById` 只能影響同 phase 尚未執行的規則，
  載在 CRS 之後等於沒寫。拆成 `exclusions-before/`（放 `ruleRemoveById`）與
  `exclusions-after/`（放 `SecRuleUpdateTargetById`）。
  兩個 `ctl:` 之間是**逗號**不是分號 —— 分號會讓 ModSecurity 拒絕載入、nginx 起不來。

---

## 6. Ansible 原生部署

完整步驟、原理與變數表見 `ansible/README.md`。此處只列與 Docker 的對應關係：

| Docker | 原生 |
|---|---|
| `app` 容器（php-fpm + nginx + supervisord） | `php8.5-fpm` + `nginx` + systemd unit（queue / schedule） |
| `edge` nginx | MyGuard 版 nginx + ModSecurity + CRS |
| `nuxt` 容器 | PM2（fork mode）或 Nginx 直送靜態檔 |
| `mysql` 容器 | 系統 MySQL |
| compose `-p` 隔離 | `releases/` + `shared/` + `current` symlink |

刻意保持一致的地方：兩邊都是「一個反向代理在前，`/` 給前端、
`/api|/admin|/up|/storage` 給 PHP」，所以 `NUXT_PUBLIC_API_BASE_URL`
在兩邊都可以是空字串（同源）。

### 原生部署的高風險點

- **release prune 必須 current-aware 且永遠有上界。**
  `ls -1dt | tail -n +N | xargs rm -rf` 按 mtime 排序且不排除 `current` 指向的目標 →
  rollback 之後下一次部署就會刪掉正在服務的版本。
  且若變數渲染成空字串會變成 `rm -rf /*/`。用 `find` + `stat` 解析 `current` 實體路徑再 `reject`。
- **`disable_functions` 不可含 `proc_open`，且只放 FPM 不放 CLI。**
  Composer 的 `post-autoload-dump`（本專案有 `package:discover` + `filament:upgrade`）
  走 Symfony Process，需要 `proc_open`。
- **`skip-name-resolve` 下，grant 要同時建 `'user'@'127.0.0.1'` 與 `'user'@'localhost'`。**
  MySQL 不做反解，比對的是字面 `127.0.0.1`。
- **Debian 沒有 `mysql-server`**（`default-mysql-server` 是 MariaDB）。
  要嘛限制成 Ubuntu，要嘛加 `repo.mysql.com` 並鎖系列。
- **TLS 有先後順序問題**：nginx 在 certbot 之前，vhost 卻已引用尚不存在的憑證 → `nginx -t` emerg。
  用 `ssl-cert` 的 snakeoil 開機，憑證出現後再切換。
- **`deb822_repository` 需要 target 上有 `python3-debian`**，要放進 base packages。
- **`validate: nginx -t -c %s` 無法驗證 vhost 片段**（`-c` 視之為完整主設定，沒有 `events{}`）。
  片段不驗證，最後跑一次 `nginx -t`。
- **location 內的 `add_header` 會讓 server 層的安全標頭全部失效**（nginx 繼承規則：
  當前層有 `add_header` 就不繼承）。`/storage/*` 與 `/_nuxt/*` 要重新 `include` 標頭 snippet。
- **`serial: 1` 讓 `run_once` 變成 no-op**（它的作用域是當前 serial batch）。
  migration 要用 `db_primary` group 明確 gate。
- **`frontend_mode` 預設 `spa`**，直到 `nuxt.config.ts` 改成讀 `process.env.NUXT_SSR` 為止。
- **MyGuard 套件名有歧異**（`libnginx-mod-http-modsecurity` + `libmodsecurity3` + `modsecurity-crs`
  vs 較新的 `libnginx-mod-http-coraza`）。要變數化 + 前置 `apt-cache policy` 探測，
  找不到就以可行動訊息 fail fast，**絕不默默裝錯東西**。

---

## 7. 常用指令對照

> 完整清單以 `cx help` 為準（那份輸出是唯一的權威來源）。
> 使用者導向的說明在 [`README.md`](README.md)。

| 目的 | `cx` | 原生等價 |
|---|---|---|
| 初始化工作區 | `cx setup` | — |
| 裝原生工具鏈 | `cx setup tools [名稱...]` | 免 root 裝到 `~/.local` |
| 裝專案相依 | `cx setup deps` | `composer install` + 兩邊的 npm |
| 起開發環境 | `cx dev up -d` | `docker compose --project-directory . -p pm_dev -f docker-compose.yml -f docker/compose/dev.yml --env-file .env --env-file docker/env/dev.env up -d` |
| artisan | `cx art migrate` | `… run --rm --entrypoint php app artisan migrate` |
| composer | `cx composer install` | `… run --rm --no-deps --entrypoint composer app install` |
| npm（前端） | `cx npm ci` | `… run --rm --no-deps --entrypoint npm nuxt ci` |
| npm（後端的 Vite 資產） | `cx npm --backend ci` | `… run --rm --no-deps --entrypoint npm app ci` |
| 後端測試 | `cx test back` | `… exec -T -e DB_CONNECTION=sqlite app php artisan test` |
| 前端型別檢查 | `cx test front` | `… run --rm --no-deps --entrypoint npm nuxt run typecheck` |
| 覆蓋率 | `cx test coverage` | 同上，另外臨時打開 `XDEBUG_MODE=coverage` |
| 進 shell | `cx dev sh app` | `… exec app sh`（容器內有 `art` / `t` 捷徑） |
| 資料庫 | `cx db status\|shell\|dump\|restore\|fresh\|admin` | — |
| 掃描 | `cx scan all` | 見 §5 |
| SonarQube | `cx sonar up\|token\|status` | 獨立 project `pm_devsecops` |
| 驗收 | `cx verify [static\|runtime\|app\|ansible\|all]` | 產出 `reports/verify/<時間戳>.md` |
| Git 同步 | `cx git sync\|save\|status` | |
| 建立遠端 | `cx git remote-init`（gh 建 3 個 public repo） | |
| 推送 | `cx git push`（白名單 + 祕密掃描 + 子模組順序） | |
| Ansible 靜態檢查 | `cx deploy syntax` / `cx deploy lint` | `ansible-playbook --syntax-check` / `ansible-lint` |
| 部署 | `cx deploy check\|apply\|app\|rollback [限制]` | `ansible-playbook -i inventory/hosts.yml site.yml` |
| 診斷 | `cx doctor` | — |

**尚未實作**（打了會得到 exit 2 並指向 §12）：
`cx fresh --rollback`、`cx fresh --mode carryover|scaffold` 的重建階段。

`cx` 可從專案任何子目錄執行（向上找 `.cxroot` 標記 —— **不用 `git rev-parse`**，
因為 `cx fresh` 會刪掉 `.git`，用 git 當解析器會在流程中途壞掉）。
`cx install` 之後可在任何地方直接打 `cx`。

### 新增一個動詞時，四個地方要一起改

1. `bin/cmd/<verb>.sh`，定義 `cmd_<verb>_main()`
2. `cx` 的 `CX_CMD_FILE_OF`（只有「動詞名 ≠ 檔名」時才需要，例如 `up` → `compose.sh`）
3. `bin/completion/cx.bash` 的 `verbs=`
4. `bin/cmd/help.sh`

漏掉第 1 項的後果實際發生過：dispatcher 把 8 個動詞指到一個從未被寫出來的
`bin/cmd/compose.sh`，於是 `cx up` 回「未知的指令」。
`cx doctor` 現在會檢查每個對外動詞都找得到實作檔。

---

## 8. 給 AI 助理的具體提醒

**改 compose 檔之前**
- 先確認你知道**這個檔在合併鏈的哪一層**。base 不能有 `ports:`、`container_name:`、原始碼 bind mount。
- 新增 service 時記得補 `networks:`，否則會落到自動建立的 `default` 網路上，用服務名解析不到別人。

**改 Dockerfile 之前**
- 先確認你在改**哪個 stage**。`dev` 不 COPY 原始碼（bind mount 會蓋掉）。
- `prod` 有 `! php -m | grep -qi xdebug` 的 build 斷言 —— 加了 xdebug 會 build 失敗，**這是刻意的**。

**改 Ansible 之前**
- 先跑 `ansible-playbook site.yml --syntax-check` 與 `ansible-lint`，
  再用 `--check --diff` 對 staging 跑一次。
- 任何 `command:`/`shell:` 都要有 `changed_when`，任何刪除都要有 gate。

**寫 shell 時**
- `set -Eeuo pipefail` + ERR trap。
- 不要用 `sed` 套用可能含元字元的值 —— 用 bash `${v//a/b}`（字面替換、無元字元）。
- whiptail 的 UI 走 stdout，重導 stdout 之前要先把真 tty 存到別的 fd。
- `f() { …; } || true` 會讓**整個函式本體**的 errexit 失效（實測 bash 5.3.9，包 subshell 也救不回來）。
  要隔離失敗就開真正的子行程。
- `flock` 是 per open-file-description：同一行程對同一路徑第二次 `exec {fd}>` 會**自己鎖死自己**。

**新增相依套件時**
- 先確認 peer 版本並在 `package.json` 明寫，不要靠 npm 自動裝 peer。
  例：`@pinia/nuxt` 要 `pinia ^3`，但 `pinia` 的 latest 已是 4.x。
- 不要手寫 `vue` / `vue-router` 到 `dependencies` —— Nuxt 自己會鎖，手寫會被 Vite dedupe 到錯的版本。

**動到 `frontend/nuxt.config.ts` 的 `ssr` 時**
- 它是三模式的開關，要寫成 `ssr: process.env.NUXT_SSR !== 'false'`，不要寫死。

**被要求「升級到某版本」或「改用 LTS」時**
- 先讀 §1 的 LTS 政策表。PHP / Laravel / Nuxt / Filament **沒有 LTS 制度**，
  不要為了找 LTS 而降版 —— PHP 降到 8.4 反而會縮短支援期。
- MySQL 千萬不要跳到 9.x：那是 Innovation track，每版只有 8 個月支援。
- Node 不要跳到 26：2026-10 之前它還是 Current，不是 LTS。

**被要求推送時**
- 確認目標是 `Information-Study`，且使用者在**當次對話**明確指示。
- 三個 repo 都是 public —— 推之前一定要跑祕密掃描。
- 子模組先推，大庫最後推。
- 對 `team-of-P/*` 的推送請求一律拒絕，不要問、不要繞道。

---

## 9. docs/

索引在 [`docs/README.md`](docs/README.md)。這裡是完整清單：

| 文件 | 內容 |
|---|---|
| [`docs/README.md`](docs/README.md) | 索引與閱讀順序 |
| [`docs/manual.md`](docs/manual.md) | 完整操作說明書，從零到三個階段 |
| [`docs/cx-reference.md`](docs/cx-reference.md) | `cx` 每個動詞的語法、參數、行為、退出碼、陷阱 |
| [`docs/docker-reference.md`](docs/docker-reference.md) | 合併鏈、三模式差異、多階段映像、edge / WAF |
| [`docs/ansible-reference.md`](docs/ansible-reference.md) | play 結構、12 個 role、vault、MySQL 五個坑 |
| [`docs/runners.md`](docs/runners.md) | 兩條 runner：容器與原生各自獨立、產出為何不可互換 |
| [`docs/devsecops.md`](docs/devsecops.md) | 四道防線的原理、閘門定義、退出碼、報告格式 |
| [`docs/reports.md`](docs/reports.md) | 測試與掃描的報告怎麼看（含逐檔案的讀法） |
| [`docs/template.md`](docs/template.md) | 拿這個 repo 當新專案範本：哪些能刪、換名字要改哪裡 |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | 症狀 → 原因 → 解法，全部是實際踩過的坑 |
| [`docs/progress.md`](docs/progress.md) | 逐項進度追蹤與「仍未驗證什麼」 |
| [`docs/docker-verification.md`](docs/docker-verification.md) | Phase 2 的驗收需求 **與實測結果**（2026-09-04 已回填） |

`docs/docker-verification.md` 現在包含：15 項舊缺陷的驗收條件與結果、
5 項阻斷級與 12 項重大項目的逐項結論、WAF 攔截率實測、
以及 **20 條驗證過程才發現的新缺陷**（§7 追加發現）。

`docs/` 是「怎麼用」，本文件是「為什麼這樣設計」。
兩邊衝突時的權威順序見 `docs/README.md` 的「三份權威來源」。

---

## 10. 檔案地圖

```
~/pm/
├── cx                       統一入口 dispatcher
├── .cxroot                  根目錄標記（專案名、GitHub 組織、repo 名）
├── .env                     ⚠ 不進版控。由 cx setup env 產生（隨機密碼 + 你的 UID/GID）
├── .env.example             三模式共用的值
├── .dockerignore            build context 排除清單（含祕密）
├── .semgrepignore           ⚠ 必須放在專案根目錄，Semgrep 只在掃描目標的根目錄找它
├── .gitignore               主庫（PUBLIC repo）；另有 /example/ 的排除
├── docker-compose.yml       base：無 ports、無 container_name、無原始碼 mount
├── README.md                使用者導向的入口
├── claude.md                本文件（原理與坑）
├── bin/
│   ├── lib/{common,ui,archive,guard}.sh
│   ├── lib/{ansible_lint,compose_mounts,verify_checks,sarif_gate}.py
│   ├── cmd/{setup,doctor,compose,test,db,sonar,scan,verify,deploy,git,
│   │        fresh,install,lint,tui,art,composer,npm,help}.sh
│   └── completion/cx.bash
├── templates/gitignore/{main,backend,frontend}
├── docker/
│   ├── compose/{dev,test,prod,sonar}.yml   模式 overlay
│   ├── env/{dev,test,prod}.env             埠段與 build target
│   ├── php/     多階段 Dockerfile + nginx / php-fpm / supervisord / php.ini
│   ├── nuxt/    多階段 Dockerfile（deps/dev/build/prod/static）+ static.conf
│   ├── edge/    反向代理（nginx.conf + conf.d/）
│   ├── entrypoint/{app,nuxt}.sh
│   ├── waf/     ModSecurity CRS 排除規則（before / after）
│   ├── security/{trivy,semgrep,zap}/
│   └── legacy/  舊設定的 .orig 副本（只供對照，不參與建置）
├── ansible/     12 role + site.yml + playbooks + .ansible-lint + .yamllint
├── docs/        progress.md、docker-verification.md
├── reports/     掃描與驗收輸出（目錄進版控，內容不進）
│   ├── quality/ sast/ sca/ dast/ waf/ db/ verify/
├── example/     ⚠ **不進版控**。舊專案的參考副本，其 .git 指向黑名單遠端
├── backend/     submodule → Information-Study/pm-backend
└── frontend/    submodule → Information-Study/pm-frontend
```

---

## 11. 原生開發環境（無 Docker 時）

Docker daemon 不可用時，用下列原生工具鏈。**全部免 root**（除了 PHP 擴充）。

```bash
# Composer（getcomposer.org 在本機被沙箱擋住，改從 GitHub release 取）
VER=$(curl -4 -fsSL https://api.github.com/repos/composer/composer/releases/latest \
      | grep -m1 '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
curl -4 -fsSL -o /tmp/composer.phar \
     "https://github.com/composer/composer/releases/download/${VER}/composer.phar"
install -m 0755 /tmp/composer.phar ~/.local/bin/composer

# Node（務必核對 SHASUMS256.txt）
NODE=v24.20.0
curl -4 -fsSL -O "https://nodejs.org/dist/$NODE/node-$NODE-linux-x64.tar.xz"
curl -4 -fsSL -O "https://nodejs.org/dist/$NODE/SHASUMS256.txt"
sha256sum -c --ignore-missing SHASUMS256.txt
mkdir -p ~/.local/node && tar -xJf node-$NODE-linux-x64.tar.xz -C ~/.local/node --strip-components=1
ln -sf ~/.local/node/bin/{node,npm,npx} ~/.local/bin/
```

### 本機環境的三個坑

1. **IPv6 壞掉。** `getcomposer.org` 解析到 IPv6 就卡死。所有 curl 都要加 `-4`。
2. **沙箱允許清單。** `registry.npmjs.org`、`nodejs.org`、`github.com`、`repo.packagist.org` 可通；
   `getcomposer.org`、`deb.debian.org` 不通。
3. **npm 11 的 install-scripts 閘門。** esbuild / vue-demi 的 postinstall 預設被擋。
   實測 esbuild 仍可用（平台套件 `@esbuild/linux-x64` 有被下載），
   但若遇到建置怪錯，用 `npm install-scripts ls` 檢查。

### 沒有資料庫時

`php artisan install:api` 有 `--without-migration-prompt`，可跳過「要不要跑 migration」的詢問
（該提示的預設值是 **true**，`--no-interaction` 下會直接對著不存在的 DB 跑）。

---

## 12. 驗證狀態

> **原則：沒跑過的就寫沒跑過。** 不要因為程式碼看起來對就標成已驗證。
> 機器可驗的部分不要手抄 —— 跑 `cx verify` 並看 `reports/verify/<時間戳>.md`。
> 逐項的進度追蹤在 [`docs/progress.md`](docs/progress.md)。

### 12.1 環境（2026-09-04 更新）

寫這份文件的最初版本時，本機**沒有 Docker、沒有資料庫、沒有 pip**，
所以底下曾經有一份很長的「從未執行」清單。目前狀態：

| 限制 | 原本的影響 | 現況 |
|---|---|---|
| Docker daemon 不可用 | 整個 Phase 2、Semgrep、ZAP、SonarQube、WAF | ✅ **已解除**。Engine 29.7.2 + Compose v5.5.0 |
| 無 `pip` / `venv` | ansible、ansible-lint、yamllint、semgrep 都裝不了 | ✅ **已解除**。`venv --without-pip` + `get-pip.py`，免 root |
| 無 composer / node | 後端與前端的相依 | ✅ **已解除**。`cx setup tools`，核對 SHA256 |
| `pdo_sqlite` 未安裝 | `php artisan test` | ✅ 容器內已有。host 端仍缺，但 `cx test back` 走容器 |
| 無 Java runtime | OWASP ZAP 原生模式 | 仍無 —— ZAP 走 docker runner，不需要 host 的 Java |
| `sudo` 需互動密碼 | `apt install` | 仍是。所有工具改成免 root 安裝到 `~/.local` |
| 沙箱網域限制 | `getcomposer.org`、`deb.debian.org` 不通 | ✅ 目前全通（`cx setup` 仍保留 `-4`，因為 IPv6 曾經是壞的） |
| **無目標主機** | Phase 5 的執行期驗證 | **仍無**。這是目前唯一還在的根本限制 |

> ⚠ 加入 docker 群組之後**必須** `wsl --shutdown`（Windows 端）再重開。
> `usermod -aG` 只影響之後才建立的登入 session；不重開的話 `docker ps` 仍是
> `permission denied while trying to connect to the docker API`，
> 而那個訊息完全不會提示你「群組已經加好了，只是還沒生效」。

### 12.2 Phase 2 — Docker（✅ 已驗證）

`cx verify all` 共 52 項，**0 失敗、0 未驗**。
逐項結果與 20 條「原始清單裡沒有、驗證過程才發現」的缺陷，
全部回填在 [`docs/docker-verification.md`](docs/docker-verification.md) §6–§7。

重點結論：

* 三個模式**同時運行** 14 個容器，零埠衝突
* D5 修正確認：`supervisorctl status` 看得到 5 個 RUNNING —— 舊版的 `CMD` 陣列缺陷
  讓 supervisord 從未啟動，**queue worker 從來沒跑過**
* WAF 在 blocking 模式擋下 SQLi / XSS / 路徑穿越（403），而 `/admin/login` 不誤擋
  —— 排除規則 10012/10013 有效
* ModSecurity audit log 確實從 stdout 取得到（`cx --mode test logs waf | grep '^{'`）

### 12.3 Phase 3 — 前後端

| 項目 | 狀態 |
|---|---|
| Laravel 骨架、Larastan level 5、Filament 安裝、Nuxt 三模式建置 | ✅ 已驗證 |
| **`php artisan migrate`** | ✅ **已執行**（三個模式各自的資料庫都跑過，10 張表） |
| **資料庫 schema** | ✅ 已驗證 |
| **`php artisan test`** | ✅ **已執行**（`cx test back`，2 passed）—— 補上 `pdo_sqlite` 後解除 |
| **Filament `/admin`** | ⚠ 登入頁回 200，但**沒有建立過管理員也沒有登入過**（`cx db admin` 可建） |
| **Sanctum SPA 認證流程** | ⚠ `/sanctum/csrf-cookie` 回 204、`/api/user` 未認證回 401，但**沒有真的走完一次登入**（前端還沒有登入頁） |
| **CORS 實際行為** | ⚠ 只驗證了設定值。三個模式都是同源，沒有做過真的跨源請求 |
| **前端 dev server** | ✅ 已啟動（HMR 容器 healthy，`/` 回 200） |
| **前端型別檢查** | ✅ **已補齊並通過**。原本缺 `tsconfig.json`（`npm create nuxt` 會產生，手工建立的骨架漏了）與 vue-tsc / typescript / @types/node |
| **前後端串接** | ✅ 經 edge 同源串接已驗（`/` → Nuxt、`/api` → Laravel） |
| **後端 Vite 資產** | ✅ **新增**。舊專案呼叫一個從來不存在的 `npm-php` service（缺陷 D3），所以 `public/build` 從來沒被建置過 |

### 12.4 Phase 4 — DevSecOps（四道全部跑得動）

| 防線 | 狀態 | 最後結果 |
|---|---|---|
| ① Larastan | ✅ | 0 errors |
| ① SonarQube scanner | ⚠ 可執行但未跑 | 需 `cx sonar up` |
| ② Semgrep | ✅ **已執行** | 298 規則 / 267 檔；0 ERROR、9 warning、5 筆有理由的抑制 |
| ③ Trivy fs（vuln + secret + misconfig） | ✅ | 乾淨 |
| ③ composer / npm audit | ✅ | 乾淨 |
| ④ ZAP | ✅ 可執行 | 見 `reports/dast/` |
| ④ WAF 攔截率對照 | ✅ **已實測** | blocking 模式擋下三類攻擊，正常流量不受影響 |
| gitleaks | ✅ | 三個 repo 全歷史皆乾淨 |

### 12.5 Phase 5 — Ansible（靜態全綠，尚未上真機）

`cx setup tools ansible` 解除了「連 `--syntax-check` 都跑不了」這個阻擋之後：

| 項目 | 結果 |
|---|---|
| 三個 playbook 的 `--syntax-check` | ✅ 全過 |
| `ansible-lint`（**production profile**） | ✅ 0 failures / 0 warnings（181 檔） |
| `yamllint` | ✅ 0 |

起點是 **739 個 finding**。修正過程找到兩類真問題：

* **`include_role` 不能當 handler**（ansible-core 2.21 直接拒絕載入）。
  這是實跑 `--syntax-check` 才發現的 —— 靜態 YAML 檢查看不出來，語法本身完全合法。
* **37 個 inventory 變數不被任何 role 讀取**。值剛好都與真正的變數相同，
  所以第一次部署會「看起來正常」。危險的是第二次：改了文件上的旋鈕卻沒有任何反應。
  其中三個載重最重的：`production.yml.example` 的 `waf_exclusions_before: []`
  會在切成 blocking 的同一刻抹掉 5 條 Livewire/Filament 排除規則；
  `releases_prune: false` 印出 `prune=False` 然後照樣 prune；
  `backend_branch` 印出你要的分支然後 clone `main`。全部已接上。

**仍未驗證**：任何需要真實目標主機的東西。清單見 [`docs/progress.md`](docs/progress.md)。
`--check` 不是萬能 —— `command` / `shell` 在 check 模式會被 skip，
所以「乾跑通過」不等於「實際跑一定會過」。

### 12.6 `cx fresh` 的重建階段

備份、驗證封存、確認閘門、刪除都可用且測過。
**重建階段與 `--rollback` 仍未實作**，打了會得到 `EX_USAGE`。

### 12.7 補正流程

```bash
cx doctor              # 先確認哪些阻擋已解除
cx verify all          # 52 項驗收，產出帶時間戳的報告
cx scan all            # 四道防線
cx deploy syntax       # Ansible 語法
cx deploy lint         # ansible-lint + yamllint
```

補正完成的項目，請把本節對應列改為 ✅ 並註明驗證日期與方式。
**不要只因為改了程式碼就標成已驗證。**
