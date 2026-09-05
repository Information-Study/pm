# 目錄版面契約

## 1. 版面是編譯期常數，不是設定項

```
~/pm/
├── bin/          cx 自己的模組
├── env/          環境定義
│   ├── docker/   compose overlay、Dockerfile、edge、WAF、entrypoint
│   └── ansible/  12 個 role + site.yml + playbooks
├── docs/         說明文件（cx 開發相關的在 docs/cx/）
├── src/          應用程式
│   ├── backend/  submodule → Laravel + Filament
│   └── frontend/ submodule → Nuxt + Vue
├── reports/      掃描與驗收輸出
└── cx .cxroot docker-compose.yml README.md claude.md …
```

`.cxroot` 的 `CX_LAYOUT_VERSION` 記錄這棵樹是哪一版；
`bin/lib/common.sh` 的 `CX_LAYOUT_REQUIRED` 記錄這一版 `cx` 認得哪一版。
兩者不一致時 `cx_assert_layout()` 會以 `EX_PRECOND`（3）中止並指到這份文件。

**`env/` 與 `src/` 這兩個名字寫死在程式碼裡。** 要改版面就是改版號跑一次遷移，
不是改一個變數。

### 為什麼不做成 `CX_DIR_*` 變數

因為常數**只能覆蓋一半的系統**：

| 檔案類型 | 讀得到 shell 變數？ |
|---|---|
| `bin/**/*.sh`、`cx` | ✅ source 進來 |
| `bin/lib/*.py` | ⚠ 只有 **export** 的看得到（子行程） |
| `env/docker/*/Dockerfile` | ❌ 實務上不行（`COPY ${ARG}/` 會毀掉 layer cache 的可讀性） |
| `.dockerignore`（26 處）、`.semgrepignore`、`sonar-project.properties`、`.vscode/launch.json` | ❌ 完全不行 |
| `env/ansible/**` | ❌ |

結果會是「130 處變成可設定，40 處仍是死的字面值」。有人改了
`CX_DIR_BACKEND`，shell 那半跟著走、Dockerfile 那半不動 →
**`.dockerignore` 不再排除 `src/backend/.env`，而 Dockerfile 是
`COPY src/backend/ ./`** —— 開發者的 `.env` 就這樣進了映像
（`.dockerignore` 的註解記錄過這件事真的發生過）。

更糟的是這種半套抽象會**通過**「定義了沒人讀」那一類檢查（shell 確實讀了），
只是 Dockerfile 沒讀。**比沒有抽象更糟。**

### 守著它的三條檢查（`cx verify cli`）

| 檢查 | 盯什麼 | 壞掉的症狀 |
|---|---|---|
| `LAY-legacy` | 全樹沒有殘留的舊版面字面路徑（含 `.md`） | 漏改一處不會有人告訴你 |
| `LAY-ignore` | `src/` 不可被 ignore、祕密檔必須被 ignore | 見 §3 |
| `LAY-version` | `.cxroot` 與 `common.sh` 的版號雙向一致 | 版號退回裝飾 |

`LAY-legacy` 掃 `.md` 是刻意的：文件裡的舊路徑不會讓程式壞掉，
但會讓下一個人 `cd` 到一個不存在的目錄，然後懷疑自己而不是懷疑文件。

---

## 2. v2 → v3 的遷移程序

### 2.1 順序不可調換：`.gitignore` 排第一

`.gitignore` 有四條**根錨定**的祕密規則。其中三條在 `ansible/` 底下，
被 `env/ansible/.gitignore`（自身錨定，搬走照樣有效）重複覆蓋 ——
**但 `/docker/ansible-target/authorized_keys` 沒有任何巢狀保護**。

漏改那一行 → `git add -A` 把它掃進索引 → 推上 **PUBLIC** repo，
而 `cx git push` 的 gitleaks **擋不住**：SSH 公鑰不是 gitleaks 的 pattern。

**這是整個遷移裡唯一「一次失誤 = 不可撤回」的路徑。**

```bash
# 先改規則（檔案還沒搬也能驗樣式）
git check-ignore --no-index -v env/docker/ansible-target/authorized_keys
git check-ignore --no-index -v src src/backend      # 必須 rc=1（沒被 ignore）
```

> `src/` 被 ignore 的後果是 `git submodule add` 失敗 —— 根 `.gitignore` 
> **不可**列入子模組路徑（`git-submodule(1)`：被 ignore 的路徑要加 `--force`）。

### 2.2 搬目錄

```bash
mkdir -p env src
git mv docker env/docker
git mv ansible env/ansible
for m in dev test prod; do git mv env/docker/env/$m.env env/docker/compose/$m.env; done
rmdir env/docker/env
git mv backend  src/backend
git mv frontend src/frontend
```

> `docker/env/` 改名成 `env/docker/compose/` 是因為直譯會變成
> `env/docker/env/dev.env` —— 三層 env，而專案裡已經有三個叫 env 的東西
>（根 `.env`、模式覆寫檔、ansible 的 `app_env`）。
> 改成與 overlay 同目錄同 stem 之後，「模式 X 的一切就是 `dev.yml` + `dev.env`
> 這兩個檔」變成目錄結構自己講出來的事。

### 2.3 ⚠ submodule：一律 `git mv`，絕不 `deinit` + `submodule add`

`git mv` 只改 `.gitmodules` 的 `path`，**不改 `[submodule "backend"]` 這個名字**。
實測（git 2.53）：

| 項目 | 搬移前 | 搬移後 |
|---|---|---|
| `.gitmodules` 的 name | `[submodule "backend"]` | **不變** |
| `.gitmodules` 的 path | `backend` | `src/backend` |
| 指標檔 `src/backend/.git` | `gitdir: ../.git/modules/backend` | `gitdir: ../../.git/modules/backend` |
| 真實 gitdir | `.git/modules/backend` | **不變**（那裡用的是「名字」） |
| `core.worktree` | `../../../backend` | `../../../src/backend`（git 自己改的） |

**「名字」與「路徑」是兩件事，而這個區別是可運作性的關鍵。**
`bin/cmd/git.sh` 的 detached 復原用 `basename "$r"` 去 `.gitmodules` 查追蹤分支，
而 `basename "src/backend"` = `backend` = 子模組名。
改用 `deinit` + `submodule add src/backend` 重加會讓名字變成 `src/backend`，
那一行就**靜默落回 `echo main`** —— 而它的用途是決定 push 前要 checkout 哪條分支。

### 2.4 搬完的九項驗證（commit 之前跑）

```bash
cat .gitmodules                                   # path 變了，名字沒變
cat src/backend/.git                              # gitdir: ../../.git/modules/backend
git -C src/backend rev-parse --absolute-git-dir   # 仍在 .git/modules/backend
git -C src/backend config --get core.worktree     # ../../../src/backend
git ls-files --stage src/backend src/frontend     # 兩個 160000
git ls-files --stage backend frontend             # 必須是空的
git rev-parse :src/backend                        # 與搬移前的 SHA 相同
git submodule status                              # 不是 missing
git check-ignore -v src src/backend               # 必須 rc=1、無輸出
```

### 2.5 `git mv` 失敗時的手動退路

git < 1.8.5、或樹上有殘留狀態導致 `git mv` 拒絕時：

```bash
mv backend src/backend
# 1) .gitmodules：path = backend → path = src/backend（**名字不要動**）
# 2) 指標檔（注意相對深度多了一層）
printf 'gitdir: ../../.git/modules/backend\n' > src/backend/.git
# 3) 反向指標（相對於 gitdir：.git/modules/backend → ../../.. = 專案根）
git -C src/backend config core.worktree ../../../src/backend
# 4) 索引
git rm --cached backend
git add src/backend .gitmodules
# 5) 跑一次 §2.4 的九項
```

### 2.6 字面替換之後一定要跑的東西

```bash
cx verify cli docs tui              # LAY-legacy 的輸出就是 TODO 清單
for m in dev test prod; do cx --mode $m config >/dev/null; done   # 抓漏改的 compose 路徑
cx dev up -d --build && cx test up -d --build && cx prod up -d --build
cx verify all                       # FAIL=0 **且 SKIP 沒有增加**
cx test cli
```

> ⚠ **`cx --mode <m> config` 這一步不能省。** `cx_compose_init` 對 `<模式>.env`
> 缺檔是硬失敗（`EX_PRECOND`），但那是 2026-09-06 才加的 ——
> 在那之前路徑寫錯一個字只會讓 compose 少一個 `--env-file`，
> 於是埠段靜默落回 `${VAR:-預設}`，三個模式搶埠。

### 2.7 遷移腳本處理不了的三類（人工找）

批次替換是以「整段路徑」為單位的，所以這三類一定會漏：

1. **變數形式**：`$CX_ROOT/$c`、`$CX_ROOT/$side`、`$CX_ROOT/$other`
2. **pathspec**：`':(exclude)backend'`、`git add -- "$side"`、`ls-tree HEAD "$c"`
3. **邊界形式**：`COPY backend/ ./`（後面是空白）、`./backend:`（後面是冒號）

第 3 類的症狀特別誤導：`dev` 模式**不會壞**（dev stage 不 COPY 原始碼，
它用 bind mount），只有 `test` / `prod` 的 build 會失敗。

還有一個誤傷方向：`for c in . backend frontend` 這種**含主庫**的迴圈，
無條件加 `src/` 會變成 `$CX_ROOT/src/.`。

### 2.8 最後才改版號

`.cxroot` 的 `CX_LAYOUT_VERSION` 與 `common.sh` 的 `CX_LAYOUT_REQUIRED`
要一起改（`LAY-version` 盯著），並更新 `bin/test/helpers/fixture.bash` 的三處。
