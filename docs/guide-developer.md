# 開發者指南

## 這份文件給誰看

你剛把這個 repo clone 下來，接下來要寫功能 —— 加一個 API、改一個 Filament 資源、
調一個 Nuxt 頁面。這份文件從 `git clone` 一路帶到「有一條乾淨的 feature 分支、
測試綠燈、可以交出去」，中途不需要離開這份文件去找別的地方。

它**不**教你四道防線怎麼調閘門（見 [devsecops.md](devsecops.md) 與
[guide-tester.md](guide-tester.md)）、也不教你部署（見
[guide-deployer.md](guide-deployer.md) 與 [ansible-reference.md](ansible-reference.md)）。
每一個動詞的完整參數表在 [cx-reference.md](cx-reference.md)，這裡只寫「你每天真的會打的那些」。

**這個專案只有一個入口：`cx`。** 專案根目錄的 `./cx`，或 `cx install` 之後全域的 `cx`。
繞過它直接打 `docker compose` / `git push` / `php artisan` 不是不行，但你會踩到 `cx`
已經替你處理掉的那些坑（compose 的四個合併陷阱、子模組的提交順序、測試打到真資料庫）。

> **文件紀律**：本文件只寫在原始碼裡查證過的動詞與旗標。有實測紀錄的地方會指出紀錄在哪、
> 日期是多少；**沒跑過的一律標明沒跑過**，不用「應該」帶過。

---

## 0. 從這個範本開一個新專案

> 這一節只有**開新專案**的人需要。已經在既有專案裡寫功能的人，直接跳到 §1。

`pm` 是一個範本。要把它變成你自己的專案（換名字、抹掉範本的 git 歷史、接上你自己的
遠端），用 `cx init`：

```bash
cx init shop                              # 改名成 shop，重建，之後自己接遠端
cx init shop --gh                         # 順便用 gh 建三個 GitHub public repo
cx init shop --org my-org --gh            # 指定 GitHub 組織
cx init shop --remote git@github.com:me/shop.git    # 接到現成的遠端
```

`cx re-init` 是同一支程式，差別只在**不改名**（原地重建）。

### 0.1 它做了什麼，順序為什麼不能換

```
改名（cx rename）→ 重建（cx fresh）→ 接遠端（cx git remote-init / remote-set）
```

`cx init` 自己幾乎沒有邏輯 —— 破壞性流程、封存與 rollback 全都在 `cx fresh` 裡
（那是本專案唯一經過對抗式稽核與實跑驗證的一份），身分改寫在 `cx rename`。

**rename 必須在 fresh 之前。** `_fresh_git_init` 會用 `.cxroot` 的 `CX_REPO_*`
重新產生 `.gitmodules`；反過來做的話，`.gitmodules` 會帶著**範本的舊名字**被寫進新專案
的第一個 commit。

### 0.2 什麼會被抹掉、什麼會留下

抹掉（不可逆）：

| 項目 | 說明 |
|---|---|
| `.git`、`.gitmodules` | 主庫的整個提交歷史 |
| `.git/modules/{backend,frontend}` | **兩個子模組的物件庫就在這裡面** —— 刪掉主庫的 `.git` 會一起帶走 |
| `backend/`、`frontend/` 的內容 | 依 `--mode` 決定會不會疊回來（見 §0.3） |

留下不動：`bin/` `cx` `.cxroot` `templates/` `docs/` `claude.md` `docker/`
`ansible/` `.env` `docker-compose.yml` `.dockerignore` `.vscode/` `reports/`。

> **`.env` 會被保留，但它裡面是範本的密碼與 APP_KEY。** 新專案應該重新產生：
> `cx setup env`。閘門的文字會提醒你這件事。

### 0.3 `carryover` 與 `scaffold` 的差別

```bash
cx init shop                      # --mode carryover（預設）
cx init shop --mode scaffold      # 只要全新骨架
```

| | carryover（預設） | scaffold |
|---|---|---|
| 框架骨架 | 全新產生（`composer create-project` / `nuxi init`） | 同左 |
| 你寫的 `app/` `routes/` `tests/` `pages/` `components/` … | **從封存疊回來** | **不疊回來**，只留在封存裡 |
| 範本自己的接線（Filament 面板、`routes/api.php`、Sanctum migration、測試防護、ESLint） | 由 `templates/` 裝回 | 同左 |

兩個模式都會產出**完整可用**的系統。差別只有「你自己寫的程式碼會不會回來」。

> ⚠ 這個預設在 2026-09-05 從 `scaffold` 改成 `carryover`。理由：`cx fresh` 的預設
> 一直是 `carryover`，兩個動詞預設相反本身就是缺陷；而且預設不該是「最危險的那一個」。
>
> 同一天還修掉一個更嚴重的問題：`scaffold` 產出的專案**沒有 Filament 後台、
> 沒有 `routes/api.php`、沒有 Sanctum 的資料表** —— 因為 `_fresh_rebuild_backend`
> 只跑 `create-project` + `require filament` + `require larastan`，**從不跑
> `filament:install --panels`**；而 `carryover` 疊回來的清單裡沒有 `bootstrap/`，
> 所以連 `bootstrap/providers.php`（註冊面板的那一行）也會掉。
> 現在那五樣收在 `templates/backend/`，由 `bin/lib/scaffold_patch.py` 冪等地裝回去。

### 0.4 閘門：你會被問什麼

`cx init` **只問一次**（它在內部對 `cx fresh` 設了 `--yes`，所以 `DESTROY <名字>` 與
`NO CARRYOVER` 這兩個 token 是自動回答的）。也就是說 `INIT <新名字>` 那一段文字
是你唯一會看到的警告 —— 它會列出上面 §0.2 的清單、封存路徑、以及目前的 `--mode`。

```
確認：INIT shop
… 會發生的事、保留不動的東西、封存位置 …
要繼續請輸入： INIT shop
```

非互動環境（沒有 tty）會直接 `EX_ABORT`(4)，什麼都不動。要在腳本裡跑得加 `--yes`。

### 0.5 先看一遍再動手

```bash
cx --dry-run init shop            # 列出會依序執行什麼，以及 rename 的每一個變更點
cx --dry-run fresh --mode carryover   # fresh 的乾跑要單獨看（init 的乾跑不會進到 fresh）
```

### 0.6 出事了怎麼辦

破壞性動作之前一定會先做完整封存（原始碼 tar、三個 git bundle、真實 gitdir、
mysqldump、SHA256SUMS），而且**先驗證封存可用**才進閘門。

```bash
cx fresh --rollback                        # 回到動手之前（用最新那份封存）
cx fresh --rollback --from <封存目錄>       # 指定某一份
```

中途失敗時，專案根目錄會留下 `CX-RECOVERY.md`，裡面就是當下該打的指令。

> ⚠ **`cx fresh` 不支援 git worktree，會直接拒絕（`EX_PRECOND`）。**
> worktree 的 `.git` 是指標檔，真正的物件庫在 `CX_ROOT` 之外 —— 封存抓不到它、
> 刪除也刪不掉它。2026-09-05 之前這個情況會產出一份**通過驗證但不含主庫歷史**的封存，
> 而流程會「成功」。請在主 checkout 上執行（`git worktree list` 看得到是哪一個）。

### 0.7 做完之後

`cx init` 最後會印出接下來的步驟。照著跑：

```bash
cx setup env             # 重新產生 .env（新的密碼與 APP_KEY）—— 一定要做
cx setup deps            # 安裝前後端相依
cx dev up -d --build     # 起開發環境
cx git flow-init         # 建立 gitflow 的分支拓撲（見 §6.2）
cx git config identity --name "你的名字" --email "你的信箱"   # 新 repo 沒有身分
cx verify cli docs tui   # 應該全綠
```

產出的分支拓撲：三個 repo 都在 `main`，各自有 `dev`；`.gitmodules` 追蹤子模組的
分支。`cx git flow-init` 會把缺的補齊。

### 0.8 這一段實際跑過嗎

跑過。2026-09-05 在拋棄式 clone（真 submodule、本地 bare remote）上，
`carryover` 與 `scaffold` 各完整跑過一次 `cx init shop`，並逐項斷言：

* `.git/modules` 消失，三個 repo 的舊 commit `git cat-file -e` **全部失敗**
* 三個 repo 各只剩 1 個 commit
* `.cxroot` / `.env` 的 `PROJECT_SLUG` / `IMAGE_PREFIX` / compose 專案名 / 映像名
  全部變成新名字；`.gitmodules` → `../shop-backend.git`
* Filament 面板與其註冊、`routes/api.php`、Sanctum migration、測試防護、ESLint 都在
* `cx setup env` 之後 `cx dev config` rc=0

自動化的版本在 `bin/test/80_init.bats`（12 個案例；完整破壞性那一個需要網路，
預設 skip，用 `CX_TEST_NETWORK=1` 開）。

---

## 1. 第一次設定

### 1.1 前置需求

| 一定要先有 | 為什麼 |
|---|---|
| `bash` 5.x | `cx` 本身就是 bash |
| `git` | 三個 repo（主庫 + 兩個子模組） |
| `python3` | `cx` 有幾支輔助程式（`bin/lib/*.py`）：compose 掛載檢查、verify、ansible lint |
| Docker Engine + Compose v2 **或** 一整套原生工具鏈 | 兩條路擇一即可，見 [§3](#3-兩條-runnerdocker--native) |

其餘（composer、node、ansible、trivy、gitleaks、semgrep、shellcheck、bats）都由
`cx setup tools` 免 root 裝到 `~/.local`，不必事先準備。

> **WSL 的第一個卡點**：`sudo usermod -aG docker $USER` 之後**必須**在 Windows 端執行
> `wsl --shutdown` 再重開。`usermod` 只影響「之後才建立」的登入 session，
> 而 `docker ps` 只會說 `permission denied while trying to connect to the docker API` ——
> 完全不會提示你「群組加好了，只是還沒生效」。

### 1.2 clone：`--recurse-submodules` 不是可選的

```bash
git clone --recurse-submodules https://github.com/Information-Study/pm.git
cd pm
```

`backend/` 與 `frontend/` 是**兩個獨立的 git repo**（子模組）。忘記
`--recurse-submodules` 的話它們會是兩個空目錄，而後果不是一個清楚的錯誤，是**五個
互不相關的錯誤**：`cx composer` 說找不到 `composer.json`、`cx npm` 說找不到
`package.json`、`cx test` 說找不到 `artisan`、`cx acl apply` 說沒東西可設、
`cx git commit` 說 repo 不存在。每一個都指向不同的方向。

`cx doctor` 會把這件事單獨挑出來講（它以前不檢查，於是空 clone 上會**全綠**）。
已經 clone 錯了就補：

```bash
git submodule update --init --recursive
cx git sync          # 子模組從 detached HEAD 接回追蹤分支
```

`cx git sync` 值得單獨講：`clone --recurse-submodules` 之後子模組一定是 detached HEAD。
它用的是 `checkout -B <分支> <目前的 HEAD>` 而不是 `checkout <分支>` —— 因為當
detached HEAD **領先**追蹤分支時（你剛好在 detached 狀態下 commit 過），
單純的 checkout 會把 HEAD 移回舊的分支尖端，那些 commit 立刻變成孤兒，
而且 `git status` 之後看起來還很乾淨。

### 1.3 `cx setup` 的七個子指令各做什麼

```bash
./cx setup            # = setup all
```

| 子指令 | 做什麼 | 為什麼需要它 |
|---|---|---|
| `setup env` | 從 `.env.example` 產生 `.env`：隨機密碼、你的 UID/GID、專案名 | compose 的 `MYSQL_ROOT_PASSWORD` 是 `:?` 必填。沒有 `.env`，**每一個** docker 動詞都會在做任何事之前就死掉 |
| `setup dirs` | 建立 `reports/` 與 `.cx/` 的葉目錄 | 這些目錄**必須由你的身分建立**。讓 Docker 自動建會是 `root:root 0755`，之後以 uid 1000 執行的 Trivy / Semgrep / PHPStan / ZAP 全部 `EACCES` |
| `setup system [名稱...]` | 需要 root 的 apt 套件 | 見下表。sudo 不可用時**只印出指令**並回傳 `3`，不會替你輸入密碼 |
| `setup tools [名稱...]` | 免 root 的工具鏈到 `~/.local`，每個下載都核對 SHA256 | IDE 的自動完成需要 host 上有 `vendor/` 與 `node_modules/`；`cx deploy` 需要 host 上的 ansible；原生 `cx scan` 需要 trivy / gitleaks / semgrep |
| `setup deps` | backend 的 `composer install` + `npm ci` + `npm run build`；frontend 的 `npm ci` | backend 有自己的 `package.json`（Vite + Tailwind）。`welcome.blade.php` 用 `@vite(...)`，沒有 `public/build/manifest.json` 就丟 `ViteManifestNotFoundException` |
| `setup guard` | 安裝三個 repo 的 pre-push 白名單 hook | **選用**，2026-09-04 起預設不裝。它會攔截所有原生 `git push`，對想直接用 IDE 推送的人是持續的阻礙 |
| `setup native` | `system` → `tools` → `deps` 一次跑完 | 見 [§3.3](#33-一行把原生那條路準備好) |

裸的 `cx setup`（= `setup all`）做的是：`env` → `dirs` → 提示 push guard 是選用 →
安裝 Ansible collections（`ansible/collections/` 不進版控，缺了 `cx deploy syntax`
會失敗在 `couldn't resolve module/action 'community.general.timezone'`）→
盤點工具鏈並告訴你缺什麼。**它不會替你安裝工具**。

#### 哪個工具在哪一邊

| 清單 | 內容 |
|---|---|
| `setup system`（需要 root） | `php` `nginx` `git` `docker`（含 compose v2）`mysql-client` `php-sqlite` `acl` `jq` |
| `setup tools`（免 root，裝到 `~/.local`） | `composer` `node`（含 npm）`ansible`（含 ansible-lint / yamllint）`trivy` `gitleaks` `semgrep` `shellcheck` `bats` |
| 不必安裝 | `artisan` —— 它是 `src/backend/artisan`，隨 Laravel 一起來 |

> `shellcheck`、`bats`、`jq` 三個確實在實作的清單裡（`bin/cmd/setup.sh` 的
> `CX_SETUP_TOOLS` / `CX_SETUP_SYSTEM_TOOLS`），`cx lint sh` 會叫你去裝 shellcheck、
> `cx test cli` 會叫你去裝 bats。bash 補全**已經**補上這三個，而且
> `cx verify cli` 的 `CLI-setup-comp` 就是在盯補全清單與權威清單一致。
> 也就是說 `cx setup tools shellcheck` 會動，`<TAB>` 也補得出來。

#### `~/.local/bin` 必須在 PATH 上

這是這個流程裡最容易誤診的一件事：工具裝好了，但這個 shell 看不到它，於是你會照著建議
再裝一次、看到「安裝成功」、然後 `cx` 還是說缺。`cx setup` 與 `cx doctor` 都會分開講
「真的沒裝」與「裝了但 PATH 沒有」。

```bash
export PATH="$HOME/.local/bin:$PATH"       # 這次先生效
echo $PATH | tr : '\n' | grep '\.local/bin' # 確認
```

`~/.profile` 已經有這一段，但它**只在 login shell 生效**；非 login shell 請把同一行
加到 `~/.bashrc`。

> **WSL 專屬、而且會偽裝成前端壞掉**：PATH 上找得到的 `npm` 可能是 Windows 那支
> （`/mnt/c/Program Files/nodejs/npm`）。它在 WSL 的專案目錄裡跑會 CMD.EXE UNC 錯誤，
> 而且 `npm ci` 會「成功」地留下一棵殘缺的 `node_modules` —— 錯誤要到 `vite build`
> 才炸。**PATH 沒修好之前不要跑 `cx setup deps`。**
> `cx doctor` 有一項專門點名 PATH 上的 Windows 工具。

### 1.4 `cx doctor`：讀它的分區，不要只看顏色

```bash
./cx doctor
```

它分十一段報告，每一段的意義不同：

| 區段 | 它在回答什麼 |
|---|---|
| 專案 | `.cxroot` 在不在、**子模組初始化了沒** |
| 容器 | Docker daemon 通不通（`command -v docker` 會騙人：WSL 上 CLI 在 PATH 但 daemon 不通）、三模式的埠有沒有被**別人**佔走 |
| 後端 / 前端工具鏈 | php 與必要擴充、composer、node 版本、frontend 相依 |
| DevSecOps | trivy / gitleaks / semgrep / ZAP —— 缺了只影響 `cx scan`，不影響開發 |
| Ansible | 缺了只影響 `cx deploy` |
| 介面與 Git | whiptail / dialog（TUI）、`gh`、push guard、檔案 ACL |
| **兩條 runner 各自的完整性** | 分開報 docker 與 native —— 不分開的話「auto 之下看起來一切正常」會把原生路徑的缺口整個蓋掉 |
| 可執行位元 | `cx` 與 `bin/**` 在磁碟與 **git index** 上都是 755。index 記成 100644 而磁碟是 755 時內容零差異、`git diff` 看不出來，但別人 clone 下來打 `./cx` 就是 Permission denied |
| Phase 2 產出物 | compose / Dockerfile / edge / entrypoint 齊不齊、`.env` 有沒有殘留 `__CHANGE_ME__` |
| cx 動詞完整性 | 補全宣告的動詞都解析得到實作檔，且每個實作檔都有動詞叫得到 |

`✔` / `⚠` / `✘` 的分工是刻意的：**`⚠` 多半是「這條路你現在用不到」**（沒裝 ansible 只擋
`cx deploy`），`✘` 才是「現在就會壞」。push guard 與 ACL 是選用功能，「一個都沒裝」是
`✔`；push guard「只裝了一半」則是 `⚠` —— 那種狀態下三個 repo 的推送行為不一致，
你會以為有保護。（ACL 設了一半目前仍報 `✔ 未設定或不完整（選用）`，細節要自己跑
`cx acl check`。）

### 1.5 選用：把 `cx` 裝成全域指令

```bash
./cx install          # ~/.local/bin/cx symlink + 註冊 bash 補全
./cx install --rc     # 另外在 ~/.bashrc 加入補全載入（自動偵測失效時才需要）
```

`cx` 可以從專案的**任何子目錄**執行（它向上搜尋 `.cxroot`），相對路徑參數以你所在的
位置解析。`cx uninstall` 移除（需確認）。

### 1.6 第一次跑起來

```bash
./cx setup                 # .env、目錄、collections、盤點
./cx setup deps            # vendor 與 node_modules（PATH 修好之後才跑）
./cx doctor                # 確認還缺什麼
./cx dev up -d --build     # 起開發環境
./cx db admin              # 建立 Filament 管理員
```

| | 網址 |
|---|---|
| 前端（經 edge） | http://localhost:8080 |
| 後端 API | http://localhost:8080/api |
| Filament 後台 | http://localhost:8080/admin |
| Nuxt 直連（繞過 edge，debug HMR 用） | http://localhost:3000 |
| phpMyAdmin | http://127.0.0.1:8891 |

---

## 2. 三個模式：dev / test / prod

模式由全域旗標 `--mode` 決定（預設 `dev`），也可以用前綴動詞 `cx dev …` / `cx test …` /
`cx prod …`。`cx_compose_init`（`bin/lib/common.sh`）據此決定三件事：compose 的
`-p <專案>_<模式>`、疊在 `docker-compose.yml` 上的 `env/docker/compose/<模式>.yml`，
以及接在根 `.env` 之後的 `--env-file env/docker/compose/<模式>.env`（後面的優先，模式專屬的埠
才蓋得掉通用值）。

### 2.1 什麼時候用哪一個

| | dev | test | prod |
|---|---|---|---|
| **拿來做什麼** | 寫程式。改完存檔就生效 | **被掃描**。ZAP 打 WAF、WAF 轉給 edge | 驗證正式組態的容器版本 |
| 原始碼 | bind mount（`./src/backend` `./src/frontend` 掛進容器） | 烘進映像（不可變） | 烘進映像（不可變） |
| `APP_ENV` / `APP_DEBUG` | `local` / `true` | `testing` / `false` | `production` / `false` |
| `display_errors` | On | **Off** | **Off** |
| xdebug | 有（`XDEBUG_MODE=debug`，`start_with_request=trigger`） | 裝了但預設 `off`，只有收覆蓋率時才臨時打開 | **無**（build 時斷言） |
| phpMyAdmin | 有 | 有 | **刻意沒有** |
| ModSecurity WAF | — | **有** | — |
| MySQL 埠 | 發布到 127.0.0.1 | 發布到 127.0.0.1 | **完全不發布** |
| 資料庫 fresh | `DB_FRESH=false` | `DB_FRESH=true`（entrypoint 用哨兵檔一次性化） | `false` |

日常寫功能只會用 `dev`。`test` 是在你要跑 `cx scan dast` / `cx verify waf` 時才起 ——
它的存在意義就是「被掃」。`prod` 是在你改了 Dockerfile 或 nginx 設定、想確認正式組態
沒被改壞時才起（真正的正式環境走 Ansible 那條路，不是這個 compose 模式，見
[ansible-reference.md](ansible-reference.md)）。

`xdebug` 的 `start_with_request=trigger` 而不是 `yes` 是刻意的：`yes` 會讓每個請求都去連
IDE，沒開 IDE 時每次都要等 connect_timeout。改成 `trigger` 之後只有帶了觸發標記的請求才會連線。
IDE 端監聽 `XDEBUG_CLIENT_PORT`（預設 `9003`）。

### 2.2 埠段對照表

來源是 `env/docker/compose/<模式>.env`（可以改），實際的 `ports:` 在 `env/docker/compose/<模式>.yml`。

| 服務 | dev | test | prod | 變數 |
|---|---|---|---|---|
| edge（HTTP 入口） | **8080** | 18080 | **80** | `EDGE_HTTP_PORT` |
| ModSecurity WAF | — | **18081**（test 的對外入口） | — | `WAF_HTTP_PORT` |
| Nuxt 直連 | 3000 | 13000 | 不發布 | `NUXT_PORT` |
| MySQL | 127.0.0.1:**3306** | 127.0.0.1:**13306** | **不發布** | `MYSQL_PORT` / `MYSQL_BIND` |
| phpMyAdmin | 127.0.0.1:**8891** | 127.0.0.1:**18891** | **無** | `PHPMYADMIN_PORT` |

三個模式的埠段刻意不重疊，所以**三個可以同時 up**。理由要講清楚：`-p <專案>_<模式>` 只
隔離容器／網路／volume，**不隔離 host 埠**。只做前者不做後者的話，第二個模式會
`Bind for 0.0.0.0:8080 failed: port is already allocated`。

MySQL 與 phpMyAdmin 都綁 `127.0.0.1`（`MYSQL_BIND`），不是 `0.0.0.0` —— 後者會把資料庫
曝在區網上。

test 的對外入口是 **18081（WAF）不是 18080（edge）**：`APP_URL` 與
`SANCTUM_STATEFUL_DOMAINS` 都指向 18081。打 18080 等於繞過 WAF，掃描結果會失真。

prod 刻意**不發布 8443**：compose 裡的 edge 沒有 `listen ssl` 區塊，發布了卻沒有 TLS
會讓 `SESSION_SECURE_COOKIE=true` 的 Filament 登入陷入無限 419。正式環境的 TLS 由
Ansible 那條路的 certbot 處理。

> 合併鏈（base + overlay 怎麼疊、四個 compose 陷阱）見
> [docker-reference.md](docker-reference.md) §1–§2；nginx 路由見
> [nginx-reference.md](nginx-reference.md)。

---

## 3. 兩條 runner：docker / native

專案的每一個功能都要能**完全用 Docker** 跑完，或**完全用原生工具鏈**跑完，
兩條路各自獨立、互不依賴。用全域旗標 `--runner` 選（放在動詞**之前**）。

```bash
cx --runner docker composer install    # 一定用容器
cx --runner native composer install    # 一定用原生 composer
cx composer install                    # auto（預設）：有 Docker 就用 Docker
```

| 值 | 行為 |
|---|---|
| `auto`（預設） | Docker daemon 可用就走容器，否則走原生 |
| `docker` | **一定**走容器。daemon 不可用 → 硬失敗 `EX_PRECOND`(3) |
| `native` | **一定**走原生。缺工具 → 硬失敗 `EX_PRECOND`(3)，並逐一列出缺哪些、各自怎麼裝 |

**被指定的那一邊不可用時絕不偷偷換邊。** 這是整件事的重點：只要允許靜默 fallback，
「原生路徑可以獨立運作」就永遠無法被驗證 —— 你以為在測原生，實際上跑的是容器，
而且沒有任何訊息告訴你。

每個雙路徑動詞都會先印一行 banner，所以「這次到底跑在哪裡」永遠不必用猜的：

```
runner: docker（自動） — 容器內的 composer
runner: native（指定） — composer 2.10.3
```

### 3.1 什麼情況下必須用哪一條

| 情況 | 必須用 |
|---|---|
| 這台機器沒有 Docker | `native`（或讓 `auto` 自己降級） |
| 你要驗證「沒有 Docker 也跑得動」 | **明寫** `--runner native` —— `auto` 會降級，證明不了任何事 |
| `cx test coverage` | `docker`。覆蓋率需要 test 映像裡的 xdebug；原生 PHP 不一定有，而且 xdebug 版本會影響數字的可比性。原生路徑會直接 `EX_PRECOND` 擋下 |
| `cx db restore` | `docker`。原生路徑沒有實作，會回 `EX_USAGE` 並告訴你怎麼手動做 |
| `cx dev` / `cx test` / `cx prod` 的九個 compose 動作 | `docker`。這些動詞**只有**容器路徑 |
| `cx pma` | `docker` |
| IDE 要有自動完成 | 需要 host 上有 `vendor/` 與 `node_modules/` → `cx setup deps`（原生） |

### 3.2 兩條路的產出**不保證可以互換**

- `src/backend/vendor`：容器是 `php:8.5-fpm-alpine`（musl），host 是 Ubuntu（glibc），
  擴充清單也不同。composer 會照「當下這個 php」解相依。
- `src/frontend/node_modules`：同理。`cx npm --backend` 的 docker 路徑刻意用
  **glibc 的 node 映像**（bookworm-slim）而不是 Alpine —— 用 Alpine 會產生一份只有
  Alpine 能用的 `node_modules`，之後在 host 上 `npm run build` 會炸
  `Cannot find module '@rolldown/binding-linux-x64-musl'`，而那個訊息看起來像
  npm 的 optional dependencies bug，其實只是 libc 不匹配。

這是刻意的分工，不是缺陷。細節與實測見 [runners.md](runners.md) §3。

### 3.3 一行把原生那條路準備好

```bash
cx setup native        # = system → tools → deps，順序固定
```

順序不能反：composer 的安裝器需要 php，所以 `system` 必須先跑。
`system` 因為缺 sudo 而只印出指令時回傳 `3`，但**流程會繼續**跑 `tools` ——
免 root 的那一半仍然裝得起來。

`cx setup native` **不吃名稱參數**。要裝單一項目請用 `cx setup system <名稱>` 或
`cx setup tools <名稱>`（兩份清單互斥，`native` 分不出你指的是哪一邊）。

> 兩條 runner 的實測對照表（2026-09-04）在 [runners.md](runners.md) §5：
> `art` / `composer` / `npm` / `test front` / `db migrate` 兩條路都跑過；
> 原生的 `test back` 需要 `php8.5-sqlite3`，原生的 `db status` 需要 `mysql-client`。

---

## 4. 日常動詞

### 4.1 容器：`cx dev up/down/logs/sh/ps`

九個動作：`up` `down` `restart` `ps` `logs` `sh` `build` `config` `dc`。
它們可以加模式前綴（`cx dev up`）、也可以裸打（`cx up`，沿用 `--mode`，預設 dev）。

```bash
cx dev up -d --build          # 建立並啟動（-d 背景、--build 先建映像）
cx dev ps                     # 容器與埠
cx dev logs -f app            # 追 app 的 log（不給 --tail 時預設 --tail=200）
cx dev logs -f nuxt edge      # 可以同時追多個服務
cx dev sh                     # 進 app 的 shell（預設服務就是 app）
cx dev sh nuxt                # 進 nuxt
cx --mode test sh waf         # 進 WAF 容器
cx dev restart nuxt           # 只重啟一個服務
cx dev build --no-cache       # 只建映像不啟動
cx dev config                 # 印出合併後的 compose 設定（除錯合併鏈用）
cx dev dc up -d phpmyadmin    # 逃生門：參數原樣交給 docker compose
cx dev down                   # 停止並移除容器（保留資料）
cx dev down -v                # ⚠ 連 volume 一起刪 —— 資料庫會消失，會要求確認
```

幾個一定要知道的行為：

- **`sh` 開的是 `sh` 不是 `bash`。** app 映像是 Alpine，沒有 bash。
- **動作有白名單。** `cx dev upp -d` 會被 `cx` 這一層擋下並告訴你可用的動作；
  不擋的話錯字會被原封不動丟給 docker compose，而錯誤訊息是 compose 的，
  看不出是你打錯字。
- **`up` 之前 `cx` 會先做四件事**：確認 `.env` 存在（硬失敗）、以你的身分建好
  `reports/` 與快取目錄、檢查 bind mount 來源都存在、比對 `.env` 與 MySQL volume 的時間。
  最後兩項各自對應一個「訊息完全不指向原因」的坑：
  - bind mount 來源不存在時 Docker 會**靜默建立 root:root 空目錄**再掛上去，
    於是 CRS 排除規則從未載入、WAF 悄悄失效，沒有任何線索。
  - MySQL 官方映像**只在資料目錄是空的時候**建立帳號。volume 已經有內容之後，
    改 `.env` 的 `DB_PASSWORD` 完全不會生效 —— 容器照常起來、healthcheck 照常過，
    然後 app 的 entrypoint 在 migrate 那一步炸 `Access denied for user`。
    最常見的觸發是「同一台機器上換一個 checkout 跑 `cx setup env`」（新密碼、舊 volume）。

- **`down -v` 有紅線閘門。** 它會列出將被刪除的 volume 並要求確認。只想重建 schema
  的話用 `cx db fresh`，不要用 `down -v`。

### 4.2 `cx art` / `cx php`

```bash
cx art migrate:status
cx art make:model Post -mfs
cx art tinker
cx php -v
cx php -m                       # 看擴充
cx php -r 'echo PHP_VERSION;'
cx php scripts/oneoff.php
```

`cx art` 是 artisan，`cx php` 是 php 本身。兩者共用同一份 runner 判斷與前置檢查
（所以在同一個檔案裡）。原生路徑會先確認 `src/backend/vendor/autoload.php` 存在 ——
缺了它 artisan 的錯誤是 `Failed opening required`，而不是「請先安裝相依」。

不給參數會印用法並回 `EX_USAGE`(2)。

### 4.3 `cx composer`

```bash
cx composer install
cx composer require spatie/laravel-permission
cx composer why-not laravel/framework 13.0
```

永遠在 `backend/` 執行。**`--ignore-platform-req*` 被硬性拒絕**（兩條路都擋）：
它掩蓋的是真正的相依衝突，正確的診斷是 `composer why-not <套件> <版本>`。

### 4.4 `cx npm`

```bash
cx npm ci                     # frontend（預設）
cx npm run dev
cx npm run build
cx npm --backend ci           # backend 的 Vite 資產
cx npm --backend run build
cx npm --frontend run typecheck   # 明確指定
cx npm -- --help              # -- 之後原樣交給 npm
```

| 旗標 | 位置 |
|---|---|
| （預設） | `frontend/` |
| `--backend`（別名 `--php`） | `backend/` —— Laravel 端的 Vite + Tailwind 資產 |
| `--frontend` | 明確指定 `frontend/` |
| `--` | 之後的參數原樣交給 npm |

前端與後端走**不同的容器**，這不是可以合併的兩條路：frontend 用 compose 的 `nuxt`
service；backend **不能**用 `app`（那是 `php:8.5-fpm-alpine`，裡面根本沒有 node，
實測是 `exec: "npm": executable file not found in $PATH`），改用 glibc 的 node
一次性容器。

### 4.5 `cx db`

作用於目前 `--mode` 的 compose project。

```bash
cx db status                      # 連線資訊、資料表、migration 狀態
cx db shell                       # 進 mysql client
cx db shell "SELECT COUNT(*) FROM users"
cx db wait                        # 等 MySQL 就緒（CI 用）
cx db migrate                     # artisan migrate --force
cx db seed
cx db fresh                       # ⚠ migrate:fresh --seed，清空所有資料表
cx db dump                        # → reports/db/<mode>-<時間>.sql.gz
cx db dump backups/before.sql.gz
cx db restore reports/db/dev-20260904T010203Z.sql.gz    # ⚠ 要輸入確認字串
cx db admin                       # 建立 Filament 管理員
cx --mode test db fresh           # 對 test 模式操作
```

`fresh` / `restore` 都有紅線閘門（`restore` 還要求輸入 `RESTORE <模式>`）。
`dump` 產生後會 `gzip -t` 驗證封存 —— 壞掉的備份要現在就發現，不是還原的時候。

mysql client 是在 **mysql 容器裡**執行，不是 app 容器。app 是 Alpine，
`apk add mysql-client` 裝到的其實是 MariaDB client，它預設會驗證伺服器憑證，
而 MySQL 8.4 出廠是自簽憑證 —— 於是每一次連線都是
`ERROR 2026 (HY000): TLS/SSL error: self-signed certificate in certificate chain`，
看起來像 TLS 壞了，其實只是用錯 client。

**原生路徑打的是 `src/backend/.env` 指到的那台 MySQL**（Ansible 部署出來的就是這種），
完全不碰 compose。但 `src/backend/.env` 記的是「容器眼中的世界」，`DB_HOST=mysql` 在 host
上解析不到，所以要覆寫：

```bash
CX_DB_HOST=127.0.0.1 CX_DB_PORT=3306  cx --runner native db status   # 打 dev 容器發布的埠
CX_DB_HOST=127.0.0.1 CX_DB_PORT=13306 cx --runner native db status   # test
```

### 4.6 `cx code`

```bash
cx code                    # 開專案根（不是你目前的子目錄）
cx code backend            # 開 backend/
cx code docs/manual.md     # 開單一檔案
cx code -n                 # 開新視窗（-r 重用、-w 等關閉；都是傳給 VS Code）
```

為什麼需要一個動詞而不是 `code .`：從子目錄執行時 `code .` 開的是子目錄不是專案根；
WSL 裡的 `code` 是 Windows 那支透過 shim 注入的，不一定在 PATH 上 —— 找不到時
`cx code` 給的是可行動的訊息（去裝 WSL 擴充），不是 `command not found`。
執行檔依序試 `code` → `code-insiders` → `codium`，也可以用 `CX_CODE_BIN` 指定。

### 4.7 `cx pma`

```bash
cx pma                # 確認容器在跑，印出網址並開瀏覽器
cx pma --no-open      # 印出網址與狀態，不開瀏覽器
cx pma --url          # 只印網址（給腳本用）
```

dev 與 test 都有 phpMyAdmin；**prod 刻意沒有**（管理介面是額外的攻擊面，而且 prod 的
MySQL 根本不發布埠）。在 prod 模式下這個動詞會回 `EX_USAGE`(2) 並告訴你改用
`cx --mode prod db shell`。

埠是從**合併後的 compose 設定**讀出來的，不是寫死 8891 —— `env/docker/compose/dev.env`
可以覆寫，寫死就會給出錯的網址。密碼不會印出來（終端機 scrollback 與 tmux buffer 會留），
只告訴你長度與去哪裡看。

> `cx pma --help` 與實作一致：dev 與 test 兩個模式都提供 phpMyAdmin
>（test 的 service 是 2026-09-05 補上的），prod 刻意不放管理介面。

---

## 5. 寫程式的循環

```
改 code → cx lint / cx style → cx test → cx verify
```

### 5.1 `cx lint` 與 `cx style` 的硬分工

**這是這個專案裡最重要的一條界線：`lint` 絕不改檔案，`style` 會改檔案。**

把兩者混在一個動詞底下，遲早會有人在 CI 裡跑 lint 然後意外改了一整棵樹 ——
接著 CI 的工作區跟你本機的不一樣，而 diff 沒有任何人審過。

| | `cx lint` | `cx style` |
|---|---|---|
| 會不會改檔案 | **絕對不會** | 會（除非加 `--check`） |
| 用在哪 | CI、提交前 | 本機整理格式 |
| 範圍 | `ansible` `php` `js` `sh` `all`（預設 all） | `php` `js` `all`（預設 all） |

```bash
cx lint                       # 全部：ansible + pint --test + eslint + prettier --check + shellcheck
cx lint php                   # = cx style php --check
cx lint js                    # ESLint + Prettier --check
cx lint sh                    # shellcheck 掃 cx 與 bin/**.sh / *.bash
cx lint ansible ansible/roles # 指定目錄

cx style                      # 兩邊都格式化（**會改檔案**）
cx style php                  # 只格式化 backend（Laravel Pint）
cx style js                   # 只格式化 frontend（Prettier）
cx style --check              # 只檢查不改 —— CI 用這個
cx style php -- --dirty       # -- 之後的參數傳給 pint（只處理未提交的檔）
```

兩個工具都**已經隨既有相依裝好**，不需要另外安裝：`src/backend/vendor/bin/pint`
（composer 的 require-dev）與 `src/frontend/node_modules/.bin/prettier`（devDependencies）。

兩個動詞都是**全部跑完才回傳最嚴重的退出碼**，不是遇到第一個問題就停 ——
停在第一個的話，前端的格式問題永遠要等到後端乾淨的那一天才會被看見。

`cx lint sh` 的閘門以 shellcheck 的 **error** 為主，warning 仍然完整顯示但不擋。理由寫在
`bin/cmd/lint.sh` 裡：用「有任何 finding 就失敗」當閘門的結果是這條 lane 永遠紅燈，
於是沒有人會再看它。
例外是一份很短的清單（`SC2215 SC2216 SC2217 SC2218 SC2069 SC2064 SC2140 SC2145`）——
shellcheck 把它們歸類為 warning，但它們其實是**正確性缺陷**（例如 SC2215：註解夾在 `\`
續行中間，於是指令提早結束、後面變成另一支程式；`bash -n` 完全過得了），所以一律視同
error 擋下來。

`cx lint ansible` 是 `ansible-playbook --syntax-check` 的**替代品，不是等價物** ——
它只做 YAML 剖析、FQCN、紅線、變數引用、changed_when。ansible 裝好之後請改用
`cx deploy lint`。

### 5.2 `cx test`

```bash
cx test back                  # 後端 PHPUnit（php artisan test）
cx test back --filter=User    # 參數原樣傳給 artisan test
cx test front                 # 前端型別檢查（nuxt typecheck）
cx test all                   # back + front（預設）
cx test coverage              # 後端覆蓋率（只有容器路徑）
cx test larastan              # 靜態分析（等同 cx scan code 的第一段）
cx test cli                   # cx 自己的行為測試（bats）
cx test cli --strict          # 有任何 skip 就算失敗（CI 用）
```

`cx test` 同時是「test 模式的 compose」與「跑測試套件」兩件事。第一個參數落在
compose 動作白名單（`up down restart ps logs sh build config dc`）裡就走 compose，
否則走測試套件。兩組沒有交集，所以不會有歧義。

```bash
cx test up -d --build         # 起測試環境（含 ModSecurity WAF）
cx test logs -f waf
```

**後端測試走 sqlite `:memory:`，所以 `cx test back` 不需要 MySQL。**
但要注意這件事的原因 —— 這是本專案的紅線之一：

> 導向 sqlite 的是 `cx`，**不是 `phpunit.xml`**。那個檔的 `<env force="true">`
> 在容器裡**沒有作用**：PHPUnit 的 force 只寫 `putenv()` 與 `$_ENV`，不寫 `$_SERVER`，
> 而 Laravel 的 `Env` 讀 `$_SERVER` 優先，compose 的 `environment:` 讓 `$_SERVER`
> 一定有值。**實測：容器裡裸跑 `php artisan test` 打的是真的 dev MySQL。**
> 所以請一律用 `cx test`（它用 `-e` 蓋掉 `$_SERVER`）。
> 目前沒有測試用 `RefreshDatabase`，所以還沒造成損失 —— 但只要有人加一個，
> 裸跑就會清空你的開發資料庫。

`cx test front` 目前是 `nuxt typecheck`：frontend 沒有測試框架，型別檢查是唯一有意義的
自動檢查（它同時會驗 `nuxt.config.ts`、元件與 store 的型別）。原生路徑缺
`node_modules` 時是**硬失敗**而不是跳過 —— 以前是 warn + return 0，那在 CI 上會變成
一個永遠綠但什麼都沒做的步驟。

`cx test cli` 跑的是 `bin/test/*.bats`。bats 把 skip 算成成功，那與本專案
「SKIP ≠ PASS」的教條直接衝突，所以 `cx` 會把跳過的數量與內容單獨印出來，
並提供 `--strict`（或 `CX_TEST_STRICT=1`）讓 CI 把任何 skip 當成失敗。

### 5.3 `cx verify`

把驗收清單變成可執行的檢查，並產出帶時間戳的 Markdown 報告。

```bash
cx verify                     # 預設：cli docs tui static app ansible
cx verify cli docs tui        # 全新 clone 上就能跑，秒級，不需要 Docker 也不需要 .env
cx verify runtime             # 需要先 cx dev up -d
cx verify waf                 # 需要先 cx test up -d
cx verify acl
cx verify all                 # 全部（會依序把三個模式都起起來，很慢）
cx verify --report /tmp/r.md  # 指定報告路徑（預設 reports/verify/<時間戳>.md）
cx verify --quiet             # 只印總結
```

| 範圍 | 需要什麼 | 檢查什麼 |
|---|---|---|
| `cli` | 無 | `cx` 自己：動詞／旗標／補全／help 四方同步 |
| `docs` | 無 | 文件與實作是否一致（教的變數真的被讀嗎、路徑對嗎） |
| `tui` | 無 | 選單每一項都指得到真的存在的指令，且每個動詞都到得了 |
| `static` | `.env` | compose 合併結果、Dockerfile、版本鎖定 |
| `runtime` | 容器在跑 | supervisord、vendor、APP_KEY、xdebug |
| `app` | 容器在跑 | 應用層端點（`/up`、`/admin`、`/sanctum`、前端） |
| `waf` | test 在跑 | ModSecurity：攻擊被擋、正常請求不被擋、引擎狀態與宣告一致 |
| `acl` | `setfacl` / `getfacl`（缺了整段 SKIP，不需要容器） | 檔案權限（POSIX ACL） |
| `ansible` | ansible | `--syntax-check` + ansible-lint + yamllint |

每個檢查回報三種結果，而且 **SKIP 不算通過**：`PASS`（真的驗過了）、`FAIL`（真的壞了）、
`SKIP`（這次沒辦法驗，例如容器沒起來）。這個分野是刻意的 —— 不要因為程式碼看起來對
就標成已驗證。

寫功能的日常循環裡，`cx verify cli docs tui` 是最值得跑的三個（秒級、不需要任何環境）。
改過 compose / Dockerfile 之後補一個 `cx verify static`。

> 掃描（`cx scan code|sast|sca|dast|secrets`）與報告怎麼讀不在這份文件的範圍：
> 見 [devsecops.md](devsecops.md)、[reports.md](reports.md) 與
> [guide-tester.md](guide-tester.md)。

---

## 6. Git 工作流

### 6.1 三個 repo 與那條順序規則

這個專案是**三個 git repo**：主庫 `pm`，加上兩個子模組 `pm-backend`（`backend/`）與
`pm-frontend`（`frontend/`）。主庫記的是兩個子模組的 **gitlink**（一個 commit SHA）。

由此得出兩條**方向相反**的順序規則，混用會壞：

| 操作 | 順序 | 為什麼 |
|---|---|---|
| `commit` / `push` | **子模組先、主庫後** | 主庫的 gitlink 指向子模組的 commit。反過來會讓 gitlink 指向一個尚不存在的 commit —— push 時遠端會回 `upload-pack: not our ref`，而且看不出是誰造成的 |
| `pull` / `branch switch` / `branch new` | **主庫先、子模組後** | `cx` 在主庫切分支時明確帶 `--recurse-submodules`，git 會「順便」把子模組拉到 gitlink 所指的 commit，讓子模組進入 detached HEAD。實測：子模組先切、主庫再切 → 子模組變成 DETACHED、分支丟失。所以子模組的 checkout 必須是最後一步才會生效 |

`cx git` 的每一個動詞都已經照這兩條規則排好，而且切換之後會**驗證沒有任何 repo 是
detached HEAD**（`--recurse-submodules` 的副作用是靜默的，只看 `switch` 的 exit code 看不出來）。
實測補充：它**只** detach gitlink 真的有變的那個子模組，另一個仍然留在自己的分支上。

### 6.2 分支模型：gitflow，`dev` 是開發主線

分支模型只有一個來源 —— `.cxroot` 的兩行：

```
CX_GIT_MAIN_BRANCH=main      # 發布線
CX_GIT_DEV_BRANCH=dev        # 開發主線
```

拓撲是**不對稱**的 —— 主庫與子模組扮演的角色不一樣：

```
主庫 pm        main ← dev                （**沒有 feature/***）
backend        main ← dev ← feature/*
frontend       main ← dev ← feature/*
```

`feature/*` **只開在子模組裡**，從該子模組的 `dev` 開、合回該子模組的 `dev`。
主庫是基礎設施倉庫（`bin/` `docker/` `ansible/` `docs/`），它的 `dev` 只負責
把子模組的 gitlink 往前推 —— 那件事發生在 `cx git feature finish` 裡。
`cx git branch new` 會**拒絕**在主庫開 `feature/*`，`branch delete` 會拒絕刪
`main` 與 `dev`。

> **為什麼主庫不開 feature，也不拆成 `dev-frontend` / `dev-backend`？**
> 2026-09-05 在拋棄式 repo 上實測過：前端與後端各自從同一條 `dev` 開分支、
> 各自只推進自己那一顆 gitlink、再先後合回 `dev` —— **兩次合併都 rc=0，零衝突**，
> 因為 `backend` 與 `frontend` 是不同路徑，git 自己就合得起來。
> 對照組：兩邊同時改共用基礎設施才是真的 `CONFLICT (content)`。
> 也就是說，把主庫拆成兩條長期線會為了一個**不存在**的衝突，
> 讓真正存在的那個（基礎設施要合兩次、而且會漂移）變嚴重。

**兩條工作分支線：`feature/*` 與 `hotfix/*`，拓撲完全相同。**
兩者都從 `dev` 開、合回 `dev`、只開在子模組，共用同一支實作 ——
差別只有前綴，用途是把「還在做的功能」與「在救火的缺陷」分開追蹤。

```bash
cx git feature start login --repo backend
cx git hotfix  start auth-bypass --repo backend
```

> ⚠ 本專案的 `hotfix` **不是 gitflow 的 hotfix**（那個從 `main` 開、
> 合回 `main` + `dev`、配 tag）。這裡的 `hotfix` **不碰 `main`**。
> `dev → main` 是 `cx git release` 的工作，而且它也不打 tag ——
> 本專案沒有版本號策略，做一半的 release 流程比沒有更糟。

### 6.3 第一次：設定身分

```bash
cx git config show                                        # 三個 repo 目前的設定
cx git config identity --name "你的名字" --email you@example.com
cx git config identity --name … --email … --global        # 改寫 ~/.gitconfig
cx git config editor "code --wait"
cx git config editor --global "vim"
```

不加 `--global` 就是**三個 repo 一起設**（逐個 `git -C … config` 是很容易漏掉一個的那種事）。
沒給 `--name` / `--email` 時會互動詢問；非互動環境會回 `EX_USAGE`(2) 而不是亂猜。

`cx git commit` 會先檢查身分 —— 沒有身分時 `git commit` 會失敗，而那個失敗以前是被吞掉的。

`config editor` 會**拒絕** `true` / `false` / `:` / `cat` 這類 no-op。CI 與容器映像常把
`EDITOR` 設成這種值讓程式不要卡住，但寫進 `core.editor` 的後果是**commit 訊息永遠是空的**，
而 git 只會說 `Aborting commit due to empty commit message`，完全指不到原因。
（2026-09-05 在本機實測到 `EDITOR=true`。）

### 6.4 一條 feature 的完整生命週期

```bash
cx git status                          # 先看三個 repo 各在哪、髒不髒、領先落後
cx git pull                            # 更新（主庫先、子模組後；預設只允許快轉）

cx git flow-init                       # 只有第一次：補齊三個 repo 的 dev（冪等）

cx git feature start login --repo backend   # → backend 的 feature/login（從它的 dev）
# ... 寫程式 ...
cx lint && cx test all                 # 提交前
cx git commit --repo backend -m "feat(auth): 加入登入流程"
cx git feature finish --repo backend   # 合回 backend 的 dev（--no-ff），
                                       # 再讓主庫的 dev 提交那一顆 gitlink
cx git push                            # 推送（白名單 + 祕密掃描 + 子模組先）
cx git branch delete feature/login --repo backend    # 刪分支（需確認）
```

`feature start` 會自動補 `feature/` 前綴（`cx git feature start login` 與
`cx git feature start feature/login` 等價）。

`--repo` 是**必要的**（或者 `cd` 進 `backend/` / `frontend/` 再下指令，它會自己推導）。
`--repo main` 與 `--repo all` 會被 `EX_USAGE` 拒絕 —— 主庫沒有 feature 分支這回事。

`feature finish` 不給名稱時用**該子模組**目前所在的分支（不是主庫的 —— 主庫根本沒有
feature 分支可以猜）。它檢查：該子模組有這條分支、有 `dev`、工作區乾淨；主庫有 `dev`，
且**除了兩顆 gitlink 以外**沒有未提交變更。

> 主庫的 gitlink 本來就會是髒的 —— 子模組剛提交了 feature 的工作，那正是這個動詞
> 要記錄的東西。第一版把前置條件寫成「主庫整個乾淨」，於是 `finish` 永遠過不了
> 自己的檢查。

順序也是刻意的：主庫**先**切到 `dev`，而且那一次切換**不帶** `--recurse-submodules`
—— 帶了的話會把剛合併好的子模組重設回 `dev` 記錄的舊 gitlink，後面 `git add` 記進去的
就是舊的 sha。然後子模組 `merge --no-ff`，最後主庫用明確的 pathspec **只** `add` 那一顆
gitlink（不是 `add -A`：另一邊的 gitlink 可能正髒著，不該被順手掃進這個 commit）。

**`finish` 刻意不推送、也不刪分支。** 那兩件事各自有自己的閘門，混進來會讓 `finish`
變成一個「一次做了三件不可逆的事」的動詞。合併衝突時它會叫你解完自己 `git commit`，
**不要再跑一次 `finish`**。

```bash
cx git feature list                    # 列出兩個子模組的 feature/*
```

> **前置條件：`--repo` 指到的那個子模組要有 `dev`。** 缺了的話 `feature start`
> 只會警告「從目前的 HEAD 開」並提示 `cx git flow-init`；真正硬失敗的是 `finish`
>（該子模組或主庫沒有 `dev` → `EX_PRECOND`(3)，訊息直接叫你去跑 `flow-init`）。
>
> **本工作區實測（2026-09-05）：`backend` 與 `frontend` 目前只有 `main`，沒有 `dev`。**
> 補法是 `cx git flow-init` —— 冪等，只補缺的，先乾跑列出要做什麼再要求確認。
> 它用 `git branch` 而不是 `switch -c`（只寫 ref、不動工作區，所以不會觸發子模組
> detach），而且會避開**落後的 `main`**：這兩個子模組的本地 `main` 都比 gitlink 舊
>（backend 少 2 個 commit），從那裡開 `dev` 等於一出生就落後。
>
> **驗證狀態**：`flow-init` / `feature start` / `feature finish` / `feature list`
> 由 `bin/test/72_gitflow.bats` 的 17 個 `@test` 涵蓋，含三個負向案例：
> 主庫不可以用 `branch new` 繞過去開 `feature/*`、`finish` 不會把另一側的髒 gitlink
> 掃進同一個 commit、`sync` 不會倒退子模組的分支。

### 6.5 `cx git commit`

```bash
cx git commit                                  # 不給 -m 會引導產生 Conventional Commits 訊息
cx git commit -m "fix(ui): 修正表單驗證"
cx git commit --repo frontend -m "fix(ui): …"  # 只提交一個 repo
cx git commit --amend                          # 修改上一個 commit（沿用原訊息）
cx git commit --skip-scan -m "…"               # 略過提交前的祕密掃描（push 仍會擋）
cx git save -m "…"                             # commit 的別名
```

| 旗標 | 值 | 說明 |
|---|---|---|
| `-m` / `--message` | 訊息 | 不給就引導產生（類型選單 + scope + 摘要） |
| `--repo` | `main` \| `backend` \| `frontend` \| `all` | 預設 `all`。值會**提早驗證**，不會做到一半才發現打錯 |
| `--amend` | — | `commit --amend --no-edit` |
| `--skip-scan` | — | 略過提交前的 gitleaks；`cx git push` 仍會擋 |

`--repo` 存在的理由：沒有它的話「只提交前端」這種再普通不過的需求就得離開 `cx` 用裸 git，
而裸 git 會繞過祕密掃描與子模組順序。只提交子模組時 `cx` 會提醒你**主庫的 gitlink 還指向
舊的 commit**，並給出補上的指令：

```bash
cx git commit --repo main -m "chore: 更新 frontend 指標"
```

> 2026-09-05 之前，`cx git commit` 的每一步都**沒有接退出碼**然後無條件印 `✔ 已提交`。
> 實測：pre-commit hook 失敗時它印「✔ 主庫已提交（4 項，含 gitlink）」並回傳 0，
> 而 repo 裡一個 commit 都沒有。現在每一步都會接，失敗時回 `EX_FAIL`(1)。

### 6.6 `cx git branch`

```bash
cx git branch list                          # 三個 repo 的分支、相對時間、上游、同步狀態
cx git branch new fix/x                     # 預設從**各 repo 自己的 `dev`** 開
cx git branch new fix/x --from dev          # 指定起點
cx git branch new fix/x --repo backend      # 只在某一個 repo
cx git branch switch main                   # 預設三個 repo 一起切
cx git branch switch tmp/x --repo backend   # 只切某一個 repo
cx git branch delete fix/x                  # 需確認；拒絕刪當前分支、main 與 dev
```

> **`branch new` 的起點：`--from` > 該 repo 自己的 `dev` > 該 repo 目前的 HEAD。**
> 起點是**逐個 repo** 解析的，不是拿主庫的答案代表三個 repo —— 主庫有 `dev`、
> 兩個子模組只有 `main`（clone 之後的常態）是很普通的狀態。有 repo 缺 `dev` 時
> 它會點名那幾個、從各自的 HEAD 開，並提示 `cx git flow-init`。
>
> `switch` 與 `delete` 也吃 `--repo`，但**不吃** `--from` —— 給了會 `EX_USAGE`，
> 不會被安靜忽略（被接受卻毫無作用的旗標比報錯更糟）。
> `cx git --help` 的說明文字與 [cx-reference.md](cx-reference.md) 都寫「預設從 dev 開」，
> 但 `bin/cmd/git.sh` 的 `_git_branch_new` 是 `local base=${_GIT_BRANCH_FROM:-}`，
> 空的時候走的是裸 `switch -c <名稱>`。只有 `cx git feature start` 會明確把起點設成 `dev`。
> 要從 dev 開就**明寫** `--from dev`，或直接用 `feature start`。

`branch switch` 在任何一個 repo 有未提交變更時會**拒絕切換**（避免變更被帶走或衝突），
並印出是哪些檔案。`branch new` 遇到髒工作區則是警告 + 確認 —— git 會把它們一起帶到新分支，
那通常正是你要的。

`branch delete` 對「未合併的分支」不會強刪：git 擋下時它印警告並保留，要丟棄請自己
`git -C <repo> branch -D`。

### 6.7 `status` / `fetch` / `pull` / `push`

```bash
cx git status        # 不連線 —— 領先落後的數字取決於上一次 fetch，它會把時間印出來
cx git fetch         # 三個 repo 一起 fetch --prune（唯讀，不動工作區）
cx git pull          # 主庫先、子模組後；預設只允許快轉
cx git pull --allow-merge
cx git push          # 子模組先、主庫後
cx git push --force  # ⚠ 要輸入 REWRITE HISTORY
```

- `status` **不連線**。沒有 remote-tracking ref 時它會明說「先跑 `cx git fetch`」，
  而不是印 0/0 讓你以為已經同步。
- `pull` 在任何一個 repo 髒的時候一律先擋（`EX_PRECOND`）。理由是失敗會發生在
  「一半」的位置：主庫已經快轉、子模組還沒動，而 merge 又因為 local changes 被拒絕 ——
  那個狀態很難描述、更難復原。
- `pull` 分岔時**不自動合併**，回 `EX_PRECOND`(3) 並列出三條路。
- `push` 的閘門順序是：祕密掃描 → 每個 repo 的 origin 檢查（永久黑名單 → 白名單）→
  確認閘門 → 子模組先推、主庫最後推。三個 repo 都是 **PUBLIC**，所以祕密掃描不是形式。
  推到白名單以外的遠端請用原生 git（pre-push hook 已於 2026-09-04 移除，不會被攔），
  但請自己先 `cx git scan-secrets`。

> `cx git` 的退出碼、`pull` 的四條路徑、黑名單紅線、從子目錄執行 —— 這些都有
> 2026-09-04 對**真實遠端**的實測紀錄，見 [cx-reference.md](cx-reference.md)
> 「`cx git` 的驗證紀錄」。

---

## 7. 檔案權限：`cx acl`

### 7.1 為什麼需要 ACL 而不是 chmod

權限模型是 setgid + 群組（`deploy:www-data`，目錄 `02750`／`02770`）。
**setgid 只讓新建的「目錄」繼承群組，不繼承權限位元** —— 位元仍然由建立者的 umask 決定。
於是兩邊互相踩：

```
php-fpm（www-data，umask 022）建出 storage/logs/laravel.log
    → rw-r--r-- www-data:www-data
    → deploy 雖然在 www-data 群組裡，卻不能寫這個檔

deploy（umask 022）建出 storage/framework/views/xxx.php
    → rw-r--r-- deploy:www-data
    → www-data 不能寫，Laravel 清快取時 Permission denied
```

這就是 Laravel「明明 chown 過了還是 permission denied」的典型成因。
`chmod -R 777` 能繞過，但那等於把 `storage` 對同機所有帳號開放 —— 而 `storage` 裡有
session、快取與上傳檔。

**default ACL（`setfacl -d`）是唯一乾淨的解法**：它讓每一個新建的檔案與目錄都自動帶上
指定的權限，完全不受 umask 影響，而且 `others` 仍然是 `0`。

### 7.2 怎麼用

```bash
cx acl check                      # 唯讀驗證（cx doctor 也會叫它）
cx acl status                     # 看目前的 ACL
cx acl status src/backend/storage     # 看單一路徑
cx acl apply                      # 套用前後端的權限模型
cx acl apply backend              # 只處理 Laravel
cx acl user add alice             # 讓 alice 可以改原始碼
cx acl user add bob --ro          # 只讀
cx acl user rm alice
cx acl fix-owner                  # 把不屬於你的檔案要回來（會列出並確認；需要 sudo）
cx acl drop                       # 移除 ACL，回到純 chmod
```

| 旗標 | 說明 |
|---|---|
| `--web-user <名稱\|uid>` | 網頁伺服器的執行身分（預設讀 `.env` 的 `APP_UID`） |
| `--dev-user <名稱\|uid>` | 開發者身分（預設：你自己） |

乾跑用**全域**旗標，放在動詞前面：`cx --dry-run acl apply`。
**沒有 `-n` 這個短旗標** —— `cx acl -n` 會被當成子指令。

套用的模型：

| 路徑 | ACL | 對應部署模型 |
|---|---|---|
| `backend/`、`frontend/` 整棵樹 | `u:web:rX, u:dev:rwX, o::---` | `02750` |
| `src/backend/storage`、`src/backend/bootstrap/cache` | `u:web:rwX, u:dev:rwX, o::---` | `02770` |

`o::---` 不是可有可無：web 與 dev 都已經有明確的 ACL 條目，others 不需要任何權限。
實測沒帶它的後果是 web 身分以 umask 022 建出的 `laravel.log` 會是 `other::r--`，
**同機任何帳號都讀得到日誌內容**。

### 7.3 `Operation not permitted` 的意思

`setfacl` 需要「檔案的擁有者」或 root —— 同群組、甚至有寫入權都不夠。樹裡只要有一個別人
的檔案，`setfacl -R` 就會在那裡停下，前面設好的留著、後面的沒設到 ——**半套狀態最難查**。
所以 `cx acl apply` 會先掃一遍，把「哪些檔案、屬於誰、怎麼修」一次講完。

最常見的來源是容器的 entrypoint 以 root 執行，`artisan package:discover` 與
`storage:link` 在 bind mount 裡留下 `root:root` 的檔案。修法就是 `cx acl fix-owner`。

`cx acl` 是**選用**功能：沒設不算故障，`cx doctor` 會把它報成 `✔ 未設定或不完整（選用）`。
部署主機的權限由 Ansible 的 `common` role 處理（同一套模型），不需要在目標機上跑 `cx`。

---

## 8. 除錯

### 8.1 log 在哪

| 想看什麼 | 怎麼看 |
|---|---|
| 容器的 stdout/stderr | `cx dev logs -f app`（預設 `--tail=200`），`cx dev logs -f nuxt edge` |
| Laravel 的 `laravel.log`（dev） | `src/backend/storage/logs/laravel.log` —— dev 是 bind mount，檔案直接在 host 上 |
| Laravel 的 log（test / prod） | 原始碼烘進映像，host 上沒有。`cx --mode test sh app` 進去看 `storage/logs/` |
| 容器裡的任何東西 | `cx dev sh [服務]`（開的是 `sh`，Alpine 沒有 bash） |
| 合併後的 compose 設定 | `cx dev config` —— 查「我改的那個值到底有沒有生效」 |
| 測試與掃描報告 | `reports/`，逐檔案讀法見 [reports.md](reports.md) |
| WAF 的 audit log | `reports/waf`，見 [reports.md](reports.md) §8 |
| 驗收報告 | `reports/verify/<時間戳>.md` |

xdebug：dev 模式已經開（`XDEBUG_MODE=debug`、`start_with_request=trigger`），
IDE 端監聽 `9003`，容器連回 host 用 `host.docker.internal`（compose 的 `extra_hosts`
已經處理）。連不上時把 `env/docker/compose/dev.env` 的 `XDEBUG_LOG_LEVEL` 調高（1~7）才有線索，
**查完記得調回 0**。

### 8.2 最常見的幾個症狀

| 症狀 | 真正的原因 | 處置 |
|---|---|---|
| `./cx: Permission denied` | 執行位元掉了（通常是 git index 記成 100644） | `cx doctor` 的「可執行位元」區段會指出來 |
| `cx: 找不到 .cxroot` | 不在專案內，或 `.cxroot` 被刪 | `cx --root <路徑> …` |
| `Bind for 0.0.0.0:8080 failed: port is already allocated` | 別的東西先佔了埠（主機的 nginx、另一個專案、Windows 那邊的服務） | `ss -ltnp "sport = :8080"`；或改 `env/docker/compose/<模式>.env` 的埠 |
| `env file ... not found` | 缺 `.env` | `cx setup env` |
| entrypoint 在 migrate 炸 `Access denied for user` | `.env` 比 MySQL volume 新 —— MySQL 只在資料目錄是空的時候建帳號 | 保留資料就把密碼改回舊值；丟掉資料就 `cx <模式> down -v` |
| `EACCES` / `permission denied`，訊息指向 nuxt 或 composer | 具名 volume 的內容被種成 `root:root` | `cx <模式> down && docker volume rm <專案>_<volume>`；`cx up` 會偵測並指路 |
| Trivy / Semgrep / PHPStan / ZAP 全部 EACCES | `reports/` 是 Docker 以 root 建的 | `cx setup dirs` |
| `ViteManifestNotFoundException` | backend 的 Vite 資產沒建 | `cx npm --backend ci && cx npm --backend run build`（或 `cx setup deps`） |
| `Cannot find module '@rolldown/binding-linux-x64-musl'` | `node_modules` 是 Alpine 建的、卻在 glibc 上跑（或反過來） | 刪掉重裝，見 [§3.2](#32-兩條路的產出不保證可以互換) |
| `npm ci` 成功但 `vite build` 說 CMD.EXE 不支援 UNC 路徑 | PATH 上的 npm 是 Windows 那支 | `export PATH="$HOME/.local/bin:$PATH"` |
| 測試打到了真的資料庫 | 裸跑 `php artisan test`（`phpunit.xml` 的 `force` 在容器裡無效） | 一律用 `cx test back` |
| `cx doctor` 在子目錄回報 28 個「未設執行位元」 | 已修（曾經是相對路徑 bug） | 更新到最新的 `cx` |
| `✘ cx 的選單需要終端機（TTY）` | 非互動環境跑 `cx tui`（`--ui plain` 也算，`cx_interactive` 把它排除在互動之外） | 直接給明確的動詞，例如 `cx doctor` |
| 子模組變成 detached HEAD | gitlink 把子模組釘在某個 commit（`clone --recurse-submodules` 之後的常態），或主庫帶 `--recurse-submodules` 切分支 | `cx git sync` |

**每一個症狀的完整說明（原因、實際的失敗訊息、解法）都在
[troubleshooting.md](troubleshooting.md)。** 那份文件的每一條都是實際踩過的坑，
按「環境 / Docker / 應用 / Ansible / 測試」分區。出事的時候先搜那裡的錯誤訊息原文。

### 8.3 兩個省時的習慣

```bash
cx --dry-run <任何動詞>      # 只印出要執行的指令，不改變任何狀態
cx dev config                # 合併後的 compose 設定 —— 不要用猜的
```

`--dry-run` 對破壞性動詞特別值得（`cx --dry-run rename …`、`cx --dry-run acl apply`）。

---

## 9. 退出碼

`cx` 的退出碼是穩定介面，CI 可以直接判斷。

| 碼 | 常數 | 意義 | 你通常要做什麼 |
|---|---|---|---|
| 0 | `EX_OK` | 成功 | — |
| 1 | `EX_FAIL` | 一般失敗（指令真的失敗了） | 看上面 git / docker / 工具自己的訊息 |
| 2 | `EX_USAGE` | 用法錯誤：未知動詞、未知參數、參數形狀不對 | 打錯字。`cx <動詞> --help` |
| 3 | `EX_PRECOND` | **前置條件不足**：沒有 Docker、缺檔、工具沒裝、工作區髒、沒有 TTY 卻執行 `cx tui` | 這不是 bug，是環境還沒準備好。訊息會告訴你缺什麼 |
| 4 | `EX_ABORT` | 你在確認閘門按了取消 | — |
| 20 | `EX_SCAN_QUALITY` | ① Quality 有 finding | 見 [reports.md](reports.md) |
| 21 | `EX_SCAN_SAST` | ② SAST 有 ERROR 等級 finding | 同上 |
| 22 | `EX_SCAN_SCA` | ③ SCA 有 finding | 同上 |
| 23 | `EX_SCAN_DAST` | ④ DAST 有 High risk alert | 同上 |

兩個設計決定值得知道：

1. **`EX_PRECOND`(3) 與 `EX_FAIL`(1) 嚴格分開。** 「沒裝 trivy」與「trivy 掃到漏洞」
   是完全不同的事，混在一起的話 CI 分不出「掃不成」與「掃出問題」。
2. **`EX_SCAN_*` 各自獨立。** `cx scan all` 會**全部跑完**再回傳最嚴重的那一個，
   不是遇到第一個 finding 就停。

`cx lint` / `cx style` 也是同樣的原則：跑完全部再回傳最嚴重的碼。
`cx test all` 一樣會把 back 與 front 兩邊都跑完，但它回傳的是**最後一個非零的碼**
（`bin/cmd/test.sh` 的 `_test_back || rc=$?; _test_front || rc=$?`），不是最嚴重的那一個 ——
只判斷「是不是 0」的 CI 不受影響，要靠碼分辨原因的話請分開跑。
在 `cx scan` 這一側，`EX_PRECOND`（工具沒裝）不會蓋掉「真的有 finding」：
`_scan_max` 取數值最大，而 `EX_SCAN_*`（20~23）本來就大於 3。

---

## 10. 一頁速查

```bash
# 第一次
git clone --recurse-submodules <url> && cd pm
./cx setup && ./cx setup deps && ./cx doctor
./cx dev up -d --build && ./cx db admin

# 每天
cx dev up -d                 cx dev logs -f app        cx dev sh
cx art migrate               cx composer require …     cx npm run dev
cx db status                 cx pma                    cx code

# 提交前
cx style                     # 會改檔案
cx lint                      # 不改檔案
cx test all
cx verify cli docs tui

# 一條 feature
cx git pull
cx git flow-init                       # 只有第一次
cx git feature start <名稱> --repo backend|frontend
cx git commit --repo backend|frontend -m "feat(scope): …"
cx git feature finish --repo backend|frontend
cx git push
cx git branch delete feature/<名稱>

# 出事
cx doctor                    cx dev config             cx --dry-run <動詞>
```

| 想知道 | 讀 |
|---|---|
| 某個動詞的完整參數 | `cx <動詞> --help`，然後 [cx-reference.md](cx-reference.md) |
| 為什麼這樣設計 | 專案根的 `claude.md` |
| 三模式與合併鏈的細節 | [docker-reference.md](docker-reference.md) |
| nginx 路由 / 「Docker 好好的上線就壞」 | [nginx-reference.md](nginx-reference.md) |
| 完全不用 Docker | [runners.md](runners.md) |
| 掃描與報告 | [devsecops.md](devsecops.md)、[reports.md](reports.md)、[guide-tester.md](guide-tester.md) |
| 上真機 | [guide-deployer.md](guide-deployer.md)、[ansible-reference.md](ansible-reference.md) |
| 東西壞了 | [troubleshooting.md](troubleshooting.md) |
| 還有什麼沒驗證 | [progress.md](progress.md)、[acceptance.md](acceptance.md) |
| 拿這個 repo 開新專案 | 見本文件 **§0**；完整參數表在 [cx-reference.md](cx-reference.md) |
