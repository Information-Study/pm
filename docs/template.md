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
| `backend/vendor/` | 204 MB | `cx setup deps` |
| `frontend/node_modules/` | 278 MB | `cx setup deps` |
| `backend/node_modules/` | 89 MB | `cx setup deps` |
| `ansible/collections/` | 39 MB | `cx setup`（或 `cx deploy galaxy`） |
| `reports/`（內容） | 依掃描次數 | `cx setup dirs`（連 `.gitignore` 一起補回）+ 重跑掃描 |
| `.cx/`（快取與鎖） | 1.3 GB | `cx setup dirs` |

**2026-09-04 實測**：把上面六個全部 `rm -rf` 之後

```
cx help / cx doctor / cx git status   仍然 rc=0（cx 本身不依賴任何產出物）
cx setup                              重建 reports/ .cx/ collections/，且不覆蓋 .env
cx setup deps                         28 秒重建三棵相依樹（54 / 464 / 77 項）
cx dev restart nuxt                   （容器當時在跑，要重啟才會恢復）
之後 cx doctor 0 失敗、17 個容器仍在跑、所有端點 200
```

> **⚠ 容器正在跑的時候刪，要記得重啟。**
> dev 的 nuxt 是「bind mount 原始碼 + 具名 volume 蓋住 node_modules」，
> 照理說刪 host 的 `frontend/node_modules` 不該影響容器 ——
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

> `reports/.gitignore` 是**進版控的檔案**而不是目錄，`rm -rf reports` 會一起帶走。
> 少了它，之後每一次掃描的產出都會變成待提交的檔案。
> `cx setup dirs` 會把它補回來（實測過）。
> 唯一要靠 git 拿回來的是 `reports/README.md` —— 那是純文件：
> `git checkout -- reports/README.md`。

`.cx/` 佔 1.3 GB 是 Trivy 與 Semgrep 的規則快取 —— 複製專案當範本時
**一定要排除**，否則會帶著一整包沒用的快取。

### B. 不可重建 —— 複製之前要決定怎麼處理

| 檔案 | 說明 |
|---|---|
| `.env` | `cx setup env` 會產生**新的隨機密碼**。新專案應該讓它重新產生，不要複製 |
| `ansible/inventory/hosts.yml` | 真實主機清單，不進版控 |
| `ansible/inventory/group_vars/all/vault.yml` | 加密的祕密 |
| `ansible/inventory/group_vars/<env>.yml` | 環境別設定 |
| `.cx/sonar-token` | SonarQube token |
| `reports/db/` | 資料庫備份（是資料，不是產出物） |

`cx setup env` **不會覆蓋既有的 `.env`** —— 要重新產生必須自己先備份並刪除。
這是刻意的：覆蓋掉一個正在用的密碼是不可逆的。

### C. 專案識別 —— 換名字時要改的地方

| 位置 | 內容 |
|---|---|
| `.cxroot` | 專案名、GitHub 組織、三個 repo 名 |
| `README.md` / `claude.md` / `docs/` | 說明文字 |
| `ansible/inventory/group_vars/all/main.yml` | `app_name` / `app_slug` / `app_domain` |
| `docker/env/*.env` | 埠段（想跟舊專案同時跑就要換） |
| `.gitmodules` | 子模組的 URL |

`.cxroot` 是單一來源：`cx` 的白名單、`cx git remote-init` 建立的 repo 名、
compose 的 project 前綴都從那裡讀。

---

## 2. 從這個範本開一個新專案

```bash
# 1. 複製，但不要帶產出物與祕密
rsync -a --exclude .git --exclude node_modules --exclude vendor \
        --exclude .cx --exclude reports --exclude .env \
        --exclude ansible/collections \
        --exclude 'ansible/inventory/hosts.yml' \
        --exclude 'ansible/inventory/group_vars/all/vault.yml' \
        pm/ newproj/

cd newproj
$EDITOR .cxroot          # 改專案名、GitHub 組織、repo 名

# 2. 重建
./cx setup               # .env（新密碼）、目錄、guard、collections
./cx setup system        # 需要 root 的系統套件（會先列出來並要求確認）
./cx setup tools         # 免 root 的工具鏈到 ~/.local
./cx setup deps          # vendor 與 node_modules

# 3. 確認
./cx doctor
./cx dev up -d --build
./cx verify
```

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
| Ansible 原生部署（12 role，實測 476 task 全綠） | `cx deploy` |
| DevSecOps 四道防線 + 專屬退出碼 | `cx scan` |
| 三 repo 同進同出的 git 操作 | `cx git` |
| 兩條 runner（容器／原生）各自獨立 | `--runner` |
| 52 項驗收清單 | `cx verify` |

換掉名字之後這些全部可以直接用 —— 它們依賴的是 `.cxroot` 與
`docker/env/*.env` 的變數，不是寫死的字串。
