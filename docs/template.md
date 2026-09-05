# 拿這個專案當範本

> 這個 repo 的設計目標之一是**當成後續新專案的起點**：
> `cx` 工具鏈、Docker 三模式、Ansible 12 role、DevSecOps 四道防線
> 都與「pm」這個名字解耦，換名字之後可以直接用。

---

## 1. 哪些東西是可以刪掉重建的

先分清楚三類，才知道複製過去之後要處理什麼。

### A. 產出物 —— 刪掉之後用 `cx` 一行重建

| 目錄 | 大小（本專案實測） | 重建指令 |
|---|---|---|
| `src/backend/vendor/` | 204 MB | `cx setup deps` |
| `src/frontend/node_modules/` | 278 MB | `cx setup deps` |
| `src/backend/node_modules/` | 89 MB | `cx setup deps` |
| `ansible/collections/` | 39 MB | `cx setup`（或 `cx deploy galaxy`） |
| `reports/`（內容） | 依掃描次數 | `cx setup dirs`（連 `.gitignore` 一起補回）+ 重跑掃描 |
| `.cx/`（快取與鎖） | 空的時候 52 KB，Trivy + Semgrep 規則抓滿之後 1.3 GB | `cx setup dirs` |

一次全部刪掉再重建：

```bash
rm -rf src/backend/vendor src/backend/node_modules src/frontend/node_modules \
       ansible/collections reports .cx
cx setup                 # 目錄骨架、collections（不覆蓋 .env）
cx setup deps            # 三棵相依樹
cx dev restart nuxt      # 容器當時在跑的話一定要做，見下面的警告
cx doctor && cx verify
```

**2026-09-04 實測**（六個目錄一起 `rm -rf`，實際刪掉 1.9 GB）：

```
cx help / cx git status / cx code / cx pma --url   仍然 rc=0
                                      cx 本身不依賴任何產出物
cx doctor                             rc=3（正確：它就是該報缺東西）
cx setup                              重建 reports/ 與 .cx/，且不覆蓋 .env
cx setup deps                         重建 src/backend/vendor（204 MB）、
                                      src/backend/node_modules（89 MB）、
                                      src/frontend/node_modules（278 MB）
cx deploy galaxy                      重建 ansible/collections（38 MB）
cx dev restart nuxt                   容器當時在跑，一定要重啟
之後 cx doctor 32/0/0、cx verify 39 通過 0 失敗、容器仍在、端點全 200
```

> ### ⚠ 這次實測第一輪是**失敗**的，原因值得單獨記一筆
>
> 第一輪 `cx setup deps` 回 rc=1、`cx verify` 3 秒就掛。**不是重建邏輯壞掉** ——
> 是執行的那個 shell 沒有把 `~/.local/bin` 放進 PATH（`~/.profile` 只在
> login shell 生效）。於是：
>
> 1. `composer` / `node` / `ansible-galaxy` 全部「不存在」→ `vendor` 沒建、
>    collections 沒裝
> 2. 但 `npm` **存在** —— 因為 WSL 把 Windows 的 PATH 併了進來，
>    抓到的是 `/mnt/c/Program Files/nodejs/npm`
> 3. 那支 npm 在 WSL 的專案目錄裡跑會 `CMD.EXE 不支援 UNC 路徑`，
>    而且 `npm ci` 會「成功」地留下一棵 **24 KB 的殘缺 node_modules**，
>    錯誤要到 `vite build` 才炸
>
> 也就是說：真正的原因（PATH）跟看到的症狀（前端建置失敗）隔了三層。
>
> 這一輪暴露出三個 cx 的缺陷，都已修掉：
> `cx_have_native` 不再把 `/mnt/*` 與 `.exe` 當成原生工具鏈、
> `cx setup deps` 會擋下 Windows 的 npm、
> `cx doctor` 會分辨「沒裝」與「裝了但 PATH 看不到」，
> 並且不再把 24 KB 的殘骸當成裝好的 `node_modules`。
> 細節見 [`troubleshooting.md`](troubleshooting.md) 的兩則 WSL / PATH 條目。
>
> **所以刪除重建之前先確認**：
>
> ```bash
> echo $PATH | tr : '\n' | grep '\.local/bin'   # 沒輸出就先修 PATH
> cx doctor                                       # 應該 0 失敗
> ```

> **⚠ 容器正在跑的時候刪，要記得重啟。**
> dev 的 nuxt 是「bind mount 原始碼 + 具名 volume 蓋住 node_modules」，
> 照理說刪 host 的 `src/frontend/node_modules` 不該影響容器 ——
> 但實測會讓正在跑的 dev server 壞掉：
>
> ```
> [nitro] ERROR RollupError: Could not resolve entry module
>         "node_modules/nitropack/dist/presets/_nitro/runtime/nitro-dev"
> ```
>
> `/` 變成 500，而 `/admin`（走 PHP）還是好的 —— 所以很容易誤判成前端壞了。
> 解法很單純：`cx setup deps` 之後 `cx dev restart nuxt`。
> 實測重啟後 `/`、`/admin/login`、Nuxt 直連 3000 全部回 200。

> `reports/` 底下有兩個**進版控的檔案**（`.gitignore` 與 `README.md`），
> `rm -rf reports` 會一起帶走。少了 `.gitignore`，之後每一次掃描的產出
> 都會變成待提交的檔案。
>
> `cx setup dirs` 兩個都會補回來（實測過，之後 `git status reports/` 是空的）：
> `.gitignore` 用 heredoc 重寫，`README.md` 從版控 `git checkout` 取回。
> README 不用 heredoc 是因為它是純文件 —— 內容複製一份到腳本裡，兩份一定會漂移。
>
> 沒有 git 的情況（例如 `cx fresh` 已經刪掉 `.git`）它會講清楚取不回來，
> 但不當成錯誤：那只是文件，不影響任何功能。
>
> ⚠ **還沒 commit 的改動不在這個保護範圍內。** `git checkout` 取回的是
> **版控裡**的版本，所以刪除之前請先把 `reports/README.md` 的修改提交掉。

`.cx/` 裡佔空間的是 Trivy 與 Semgrep 的規則快取（跑過掃描之後會膨脹到 GB 級）——
複製專案當範本時**一定要排除**，否則會帶著一整包沒用的快取。
`.cx/verify-config-*.json` 也在裡面，那是 `cx verify` 自己產生又自己刪的暫存檔。

### B. 不可重建 —— 複製之前要決定怎麼處理

| 檔案 | 說明 |
|---|---|
| `.env` | `cx setup env` 會產生**新的隨機密碼**。新專案應該讓它重新產生，不要複製 |
| `env/ansible/inventory/hosts.yml` | 真實主機清單，不進版控 |
| `env/ansible/inventory/group_vars/all/vault.yml` | 加密的祕密 |
| `env/ansible/inventory/group_vars/<env>.yml` | 環境別設定 |
| `.cx/sonar-token` | SonarQube token |
| `reports/db/` | 資料庫備份（是資料，不是產出物） |

`cx setup env` **不會覆蓋既有的 `.env`** —— 要重新產生必須自己先備份並刪除。
這是刻意的：覆蓋掉一個正在用的密碼是不可逆的。

### C. 專案識別 —— 換名字時要改的地方

改 `.cxroot` 一個檔就會連帶生效的東西（**不必手動改**）：

| 跟著 `.cxroot` 走 | 從哪裡長出來 |
|---|---|
| compose project 前綴 `<專案>_dev\|test\|prod` | `cx_project_for()`（`bin/lib/common.sh`） |
| SonarQube 的 project 與網路 `<專案>_devsecops[_net]` | `cx_sonar_project()` / `cx_sonar_net()` |
| `cx scan dast` 用的 `<專案>_test_net` | `bin/cmd/scan.sh` |
| push guard 的白名單與拒絕訊息 | `cx_guard_allow_re()`（`bin/lib/guard.sh`） |
| `cx git remote-init` 建立的三個 repo 名 | `bin/cmd/git.sh` |
| `cx fresh` 的確認字串 `DESTROY <專案>` | `bin/cmd/fresh.sh` |
| `.env` 的 `PROJECT_SLUG` / `IMAGE_PREFIX` → compose 網路名與映像前綴 | `cx setup env` |
| `cx verify` 建 config 快取用的 `-p <專案>_<mode>` | `bin/cmd/verify.sh` |
| `cx verify` 檢查 2.5 期待的網路名 `<專案>_<mode>_net` | `bin/lib/verify_checks.py`（讀 `CX_PROJECT_NAME`） |
| WAF 主動探測的 `docker compose -p <專案>_test` | `bin/lib/waf_probe.py`（讀 `CX_PROJECT_NAME`） |
| `cx up` / `cx down -v` / `cx db` 的訊息與**危險確認**所寫的專案名 | `cx_project_for()` |

> 這五項是 2026-09-04 的推送前審查抓出來的漏網之魚 —— 前面幾項早就接上
> `.cxroot` 了，這幾處還寫死 `pm_`。其中 `verify.sh` 與 `verify_checks.py`
> 那兩處是功能性的：改名後的專案 `cx verify` 的檢查 2.5 會三個模式全部 FAIL
>（拿 `pm_<mode>_net` 去比對真實的 `<專案>_<mode>_net`），
> 也就是一個全新的範本專案**開箱就報驗證失敗**。
> `cx down -v` 與 `cx db` 那兩處是安全性的：確認對話框會寫出**錯的專案名**。
>
> `bin/lib/*.py` 是子行程，看不到只被 source 的變數 ——
> 所以 `cx` 現在把 `CX_PROJECT_NAME` 一起 `export`。

> ⚠ `cx setup` **不會**安裝 push guard，它只印一行提示。要裝得自己跑 `cx git guard install`。
> 白名單在安裝當下就被烤進去，不會自己更新）。
>
> ⚠ 2026-09-04 起 push guard 預設**不安裝**，`cx setup` 也不再包含它。
> 下面關於白名單的內容只在你執行過 `cx git guard install` 之後才適用。
> 已經產生的 `.env` 也不會被回頭改寫 —— 新專案本來就該讓 `cx setup env` 重新產生。

仍然要**手動**改的：

| 位置 | 內容 |
|---|---|
| `README.md` / `claude.md` / `docs/` | 說明文字 |
| `env/ansible/inventory/group_vars/all/main.yml` | `app_name` / `app_slug` / `app_domain`（Ansible 那邊的單一來源） |
| `env/docker/compose/*.env` | 埠段（想跟舊專案同時跑就一定要換 —— `-p` 只隔離容器，不隔離 host 埠） |
| `sonar-project.properties` | `sonar.projectKey` / `sonar.projectName` |
| `.gitmodules` | 子模組的 URL |

### 驗證換名字真的有效

```bash
# 不必真的複製一份，直接用假的 .cxroot 值問 cx 會產生什麼
CX_PROJECT_NAME=shop CX_GH_ORG=Acme-Inc CX_REPO_MAIN=shop \
CX_REPO_BACKEND=shop-api CX_REPO_FRONTEND=shop-web \
bash -c '. bin/lib/common.sh; . bin/lib/guard.sh;
         echo "compose -p : $(cx_project_for dev)";
         echo "push 白名單: $CX_ALLOWED_REMOTE_RE"'
```

**2026-09-04 實測**：輸出 `shop_dev` 與
`^(https://github\.com/|git@github\.com:)Acme-Inc/(shop|shop-api|shop-web)(\.git)?/?$`，
且該白名單會拒絕 `Information-Study/pm`、仍然拒絕永久黑名單的 `team-of-P/*`。

---

## 2. 從這個範本開一個新專案

**建議用 `cx init`** —— 完整流程、兩個模式的差別、每一個閘門的原文、以及實測紀錄，
都在 [`guide-developer.md`](guide-developer.md) 的 **§0**：

```bash
cx init shop [--org <組織>] [--gh | --remote <URL>] [--mode carryover|scaffold]
```

它會先完整封存並驗證封存可用才進閘門，出事可以 `cx fresh --rollback`。

底下是**手動等價做法**，給不想用 `cx init` 的情況。它不封存、不驗證、沒有 rollback，
而且 `.cxroot` 要自己改：

```bash
# 1. 複製，但不要帶產出物與祕密
rsync -a --exclude .git --exclude node_modules --exclude vendor \
        --exclude .cx --exclude reports --exclude .env \
        --exclude ansible/collections \
        --exclude 'env/ansible/inventory/hosts.yml' \
        --exclude 'env/ansible/inventory/group_vars/all/vault.yml' \
        pm/ newproj/

cd newproj
$EDITOR .cxroot          # 改專案名、GitHub 組織、repo 名

# 2. 重建
./cx setup               # .env（新密碼 + 新的 PROJECT_SLUG）、目錄、collections
                         # push guard 是選用的，要的話另外跑 cx git guard install
./cx setup native        # = system + tools + deps（一行裝完整套原生工具鏈）
                         #   sudo 不可用時會把 apt 指令印出來讓你自己貼，
                         #   免 root 的那一半照樣裝完

# 3. 確認
./cx doctor              # 看「兩條 runner 各自的完整性」那一段
./cx dev up -d --build
./cx verify              # 報告落在 reports/verify/<時間戳>.md
```

> `cx setup guard` 已經包含在 `cx setup` 裡，但它是在**你改完 `.cxroot` 之後**
> 才讀白名單的。順序寫反（先 setup 再改 `.cxroot`）的話要補跑一次
> `./cx setup guard`，否則 hook 裡烤的還是舊專案的白名單。

> `--exclude .git` 是刻意的：新專案應該有自己的歷史。
> 要保留歷史的話請改用 `git clone` 再自己改 remote，
> 並記得 `cx git push` 的白名單是從 `.cxroot` 讀的。

---

## 3. 範本自帶什麼

| 能力 | 入口 |
|---|---|
| Docker 三模式（dev / test / prod，可同時運行） | `cx dev\|test\|prod up` |
| 多階段映像（php 7 個 stage、nuxt 5 個） | `docker/php`、`docker/nuxt` |
| 反向代理 + Livewire/Filament 路由 | `docker/edge` |
| ModSecurity + OWASP CRS | `docker/waf` |
| Ansible 原生部署（12 role，實測全綠（task 數各次執行不同，見 docs/progress.md 的實跑紀錄）） | `cx deploy` |
| DevSecOps 四道防線 + 專屬退出碼 | `cx scan` |
| 三 repo 同進同出的 git 操作 | `cx git` |
| 兩條 runner（容器／原生）各自獨立 | `--runner` |
| 一行安裝整套原生工具鏈 | `cx setup native` |
| 用 VS Code 開專案（WSL 也可以） | `cx code` |
| 開 phpMyAdmin（只有 dev） | `cx pma` |
| 39 項驗收清單 | `cx verify` |

換掉名字之後這些全部可以直接用 —— 它們依賴的是 `.cxroot` 與
`env/docker/compose/*.env` 的變數，不是寫死的字串。
