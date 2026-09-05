# 進度追蹤

> 最後更新：**2026-09-05**
>
> 最後一次完整回歸：`cx doctor` 35 通過 / 0 警告 / 0 失敗；`cx verify all` 0 失敗；
> `cx test cli`、`cx lint all`、`cx deploy lint` 皆 rc=0；三個模式的 15 個容器同時運行（dev 5 ・ test 6 ・ prod 4）。
>
> ⚠ **通過項數刻意不寫在這裡。** 它每加一條檢查就過期一次，而過期得毫無徵兆 ——
> 本檔曾經長期停在「52 項」而實際早已不同。要看數字請跑 `cx verify all`，
> 或看 `reports/verify/` 最新的那一份。
> 這份文件的維護原則：**沒跑過的就寫沒跑過。** 不要因為程式碼看起來對就標成已驗證。
> 可機器驗證的部分請以 `cx verify` 的輸出為準，不要手抄。

## 怎麼取得「現在」的狀態

```bash
cx doctor          # 環境：工具鏈、Docker、埠、子模組、執行位元、Phase 2 產出物
cx verify          # 靜態 + 應用端點 + Ansible（不需要容器在跑）
cx verify all      # 加上執行期驗收（需要三個模式都 up）
```

`cx verify` 每次都會產生一份帶時間戳的 Markdown 報告到 `reports/verify/`，
內容是 `PASS / FAIL / SKIP` 的逐項表格。**SKIP 不等於 PASS** —— 它的意思是
「這次沒辦法驗」，例如容器沒起來或工具沒裝。

---

## Phase 進度

| Phase | 內容 | 狀態 | 驗證方式 |
|---|---|---|---|
| 0 | `claude.md` 專案指南 | ✅ 完成 | — |
| 1 | 更名、`cx` 骨架、備份、刪除舊紀錄 | ✅ 完成 | — |
| 2 | Docker 三模式 + 多階段映像 + edge + WAF | ✅ **完成並實測** | `cx verify all` 0 失敗（項數見報告） |
| 3 | 前後端重建 + 三 Git 初始化 | ✅ 完成 | migration / 測試 / 端點皆已實跑 |
| 4 | DevSecOps 四道防線 + `cx scan` | ✅ **四道全部跑得動** | 見下表 |
| 5 | Ansible 12 role + playbook | ✅ **對真實 systemd 目標完整跑通**（475 task、failed=0） | `cx deploy apply`（見下方「Ansible 真機進度」） |
| 6 | `README.md`、`ansible/README.md`、本文件 | ✅ 完成 | — |

---

## `cx` 動詞實作狀態

| 動詞 | 狀態 | 備註 |
|---|---|---|
| `setup` | ✅ | env / dirs / **native** / system / tools / deps（`guard` 仍在，但**不含**在無參數的 `setup` 裡） |
| `doctor` | ✅ | 含 Phase 2 產出物與動詞完整性檢查（**35 項**，含 dispatcher 對照表、埠、子模組、可執行位元） |
| `dev` `prod` `up` `down` `restart` `ps` `logs` `sh` `build` `config` `dc` | ✅ | 全部經 `cx_compose_init`，四個 compose 陷阱集中處理 |
| `test`（compose 動作） | ✅ | `cx test up` 等同 `cx --mode test up` |
| `test back/front/all/coverage/larastan` | ✅ | 後端走 sqlite `:memory:`（另有**應用層 hard guard**：任何非 sqlite 的目標都 fail-fast，退出碼 3）；前端的 `nuxt typecheck` 原本缺 `tsconfig.json` 與 vue-tsc/typescript/@types/node，已補齊 |
| `test cli` | ✅ | `cx` 自己的行為測試（bats-core，**97 個案例**）。bats 把 skip 算成成功，與本專案 SKIP≠PASS 的教條衝突，所以 `_test_cli` 會另外把跳過數印出來，並支援 `CX_TEST_STRICT=1` |
| `db` | ✅ | status / shell / wait / migrate / fresh / seed / dump / restore / admin |
| `scan` | ✅ | code / sast / sca / dast / secrets / all |
| `sonar` | ✅ | up / down / status / logs / token / url / wait |
| `verify` | ✅ | **cli / docs / tui / static / runtime / app / waf / acl / ansible / all**。前三個不需要 Docker 也不需要 `.env`，剛 clone 下來的樹就跑得完 |
| `deploy` | ✅ | syntax / lint / check / ping / facts / vars / apply / app / rollback / galaxy / **hosts**（init/add/rm/show/check/edit） |
| `git` | ✅ | status / fetch / pull / sync / commit（`save`）/ branch / **feature** / **flow-init** / **config** / guard / remote-init / **remote-set** / scan-secrets / push。gitflow：feature 只開在子模組，主庫的 dev 在 finish 時同步 gitlink |
| `art` `composer` `npm` | ✅ | 容器與原生兩條路都可用，`--runner` 可強制；`npm --backend` 是新增的（舊 `npm-php` service 從來不存在） |
| `lint` | ✅ | ansible / php / **js（ESLint + Prettier）** / sh。`sh` 有一小撮「其實是正確性缺陷」的 warning 視同 error（`fatal_warn`） |
| `style` | ✅ | php（Pint）/ js（Prettier）—— **會改檔案**，與 `lint` 的分工是硬的 |
| `acl` | ✅ | POSIX ACL：check / apply / user add\|rm |
| `rename` | ✅ | 把整個範本改成新的專案名；`--dry-run` 先列變更點，**不碰 `.git`**。由 `cx verify cli` 的 `TPL-*` 四項守著一致性 |
| `tui` `install` `uninstall` `help` | ✅ | |
| `code` | ✅ | 用 VS Code 開專案根（不是所在的子目錄） |
| `pma` | ✅ | 開 phpMyAdmin；只有 dev 有，埠從合併後的 compose 設定讀 |
| `php` | ✅ | 直接跑 php（`cx art` 只涵蓋 artisan），兩條 runner 都支援 |
| `setup system` | ✅ | 需要 root 的系統套件；有確認閘門，sudo 不可用時只印指令 |
| `setup native` | ✅ | system → tools → deps 一次做完（2026-09-04 新增） |
| `fresh` | ✅ | preflight → backup → verify-archive → 閘門 → migrate → delete → **rebuild → verify-rebuild → git-init**，以及 `--rollback`／`--from`／`--resume-from`。⚠ 這一列在 2026-09-05 之前寫的是「重建階段與 `--rollback` 仍未實作」—— 那在實作完成後就過期了，是本專案最典型的「文件與實際相反」 |

---

## 兩條 runner（容器／原生）

`--runner docker|native|auto` 是全域旗標。被指定的那一邊不可用時**硬失敗**，
不會偷偷退回另一邊 —— 允許靜默 fallback 的話，「原生路徑可以獨立運作」
就永遠無法被驗證。

| 指令 | docker | native |
|---|---|---|
| `cx art` / `cx php` | ✅ | ✅ |
| `cx composer` | ✅ | ✅ |
| `cx npm` / `cx npm --backend` | ✅ | ✅ |
| `cx test front` | ✅ | ✅ |
| `cx db migrate/seed/admin/fresh` | ✅ | ✅ |
| `cx test back` | ✅ | ⚠ 需要 `php8.5-sqlite3` |
| `cx db status/shell/wait/dump` | ✅ | ⚠ 需要 `mysql-client` |
| `cx test coverage` | ✅ | 設計上只有容器（需要 test 映像的 xdebug） |
| `cx db restore` | ✅ | 設計上只有容器 |

兩個 ⚠ 都是**系統套件、需要 root**，`cx setup system` 會列出指令。
詳見 [`runners.md`](runners.md)。

## 範本化：專案名與程式碼解耦（2026-09-04）

這個 repo 要當成新專案的起點，所以「pm」這個名字不可以寫死在任何會造成**衝突**的地方。
以下原本是硬編碼，現在全部從 `.cxroot` 的 `CX_PROJECT_NAME` 長出來：

| 原本寫死 | 現在 | 寫死會怎樣 |
|---|---|---|
| `-p pm_<mode>` | `cx_project_for()` | 改名的新專案仍建出 `pm_dev`，跟本專案搶容器／volume |
| `pm_<mode>_net`（compose） | `${PROJECT_SLUG}_<mode>_net` | 網路名是全 daemon 唯一的，直接相撞 |
| `pm_devsecops` / `pm_devsecops_net` | `cx_sonar_project()` / `cx_sonar_net()` | 兩個專案共用同一台 SonarQube |
| `pm_test_net`（ZAP 用） | `$(cx_project)_test_net` | DAST 掃到別的專案的 WAF |
| `Information-Study/pm(-backend|-frontend)` 白名單 | `cx_guard_allow_re()` | 新專案的 hook **拒絕它自己的合法遠端** |
| `DESTROY pm`（fresh 確認字串） | `DESTROY $(cx_project)` | 確認字串跟專案對不上 |
| `.env` 的 `PROJECT_SLUG` / `IMAGE_PREFIX` | `cx setup env` 從 `.cxroot` 填 | 映像 tag 與網路名還是 pm |

**實測**：用假的 `.cxroot`（`shop` / `Acme-Inc` / `shop-api` / `shop-web`）產生：

```
compose -p : shop_dev
push 白名單: ^(https://github\.com/|git@github\.com:)Acme-Inc/(shop|shop-api|shop-web)(\.git)?/?$
```

該 hook 接受 `Acme-Inc/{shop,shop-api,shop-web}`、拒絕 `Information-Study/pm`、
仍然拒絕永久黑名單的 `team-of-P/*`。
另外在一個「只有 `.cxroot` + `.env.example` + `bin/`」的空目錄上實測
`cx --root <空目錄> setup dirs` 與 `setup env`：11 個葉目錄與 `reports/.gitignore`
全部從無到有建起來，`.env` 的 `PROJECT_SLUG=shop`、`IMAGE_PREFIX=shop`、
密碼 32 字元、權限 0600、重跑不覆蓋。

> ⚠ `.cxroot` 改完之後要重跑 `cx setup guard` —— hook 是產生出來的檔案，
> 白名單在安裝當下就被烤進去。

詳見 [`template.md`](template.md)。

---

## 刪除與重建（2026-09-04 實測）

把 `backend/vendor`、`frontend/node_modules`、`backend/node_modules`、
`reports/`、`.cx/`、`ansible/collections/` 全部 `rm -rf` 之後（共 1.9 GB）：

| 步驟 | 結果 |
|---|---|
| `cx help` / `cx git status` / `cx code` / `cx pma --url` | rc=0（cx 本身不依賴任何產出物） |
| `cx doctor` | rc=3 —— 正確，它就是該報缺東西 |
| `cx setup` | 重建 reports/ 與 .cx/，**不覆蓋 `.env`** |
| `cx setup deps` | 重建三棵相依樹（204 + 89 + 278 MB） |
| `cx deploy galaxy` | 重建 `ansible/collections`（38 MB） |
| `cx dev restart nuxt` | 容器當時在跑，node_modules 被抽掉會讓 dev server 壞掉，要重啟 |
| 之後 | `cx doctor` 32/0/0、`cx verify` 39 通過 0 失敗、容器仍在跑、端點全 200 |
| `reports/` | `.gitignore` 與 `README.md` 都由 `cx setup dirs` 自動補回，之後 `git status reports/` 是空的 |

### 第一輪失敗，暴露三個缺陷（都已修）

第一輪跑的那個 shell 沒有把 `~/.local/bin` 放進 PATH（`~/.profile` 只在
login shell 生效）。連鎖反應：composer / node / ansible-galaxy 全部「不存在」，
但 `npm` **存在** —— WSL 把 Windows 的 PATH 併了進來，抓到
`/mnt/c/Program Files/nodejs/npm`。那支在 WSL 專案目錄裡跑會
`CMD.EXE 不支援 UNC 路徑`，而且 `npm ci` 會「成功」地留下一棵 24 KB 的殘骸。

| 缺陷 | 修法 |
|---|---|
| `cx_have` 把 Windows interop 執行檔當成原生工具鏈 | 新增 `cx_have_native`／`cx_win_interop_path`：解析到 `/mnt/<磁碟>/` 或 `.exe` 一律不算。`cx pma` 開瀏覽器仍用 `cx_have`（那裡確實需要 `explorer.exe`） |
| `cx setup deps` 拿 Windows npm 去建置，且對已裝但 PATH 看不到的工具說「請安裝」 | 改用 `cx_have_native`，並區分「沒裝」與「裝在 `~/.local/bin` 但 PATH 看不到」 |
| `cx doctor` 只檢查 `frontend/node_modules` 目錄存在 | 改檢查 `node_modules/nuxt`；另外新增「PATH 上有 Windows 的工具」與「已裝但不在 PATH」兩項檢查 |

教訓：真正的原因（PATH）跟看到的症狀（`vite build` 失敗）隔了三層，
中間每一層都「成功」。這正是 `--runner` 硬失敗原則要防的同一類問題 ——
只是這次漏在 `cx_have` 這個更底層的地方。

詳見 [`template.md`](template.md) 與 [`troubleshooting.md`](troubleshooting.md)。

## 掃描與測試的實跑（2026-09-04）

刪除重建通過之後把每一道都實際跑了一次，抓到 **8 個缺陷**，
其中 4 個的共同特徵是**會顯示成功**——這類最貴，因為沒人會去查。

### 會假裝通過的

| 缺陷 | 症狀 | 為什麼危險 |
|---|---|---|
| `cx test coverage` 吞掉退出碼 | 1 failed 1 passed，rc 仍是 `0` | 函式最後一個指令是 `docker cp` / `cx_ok`。CI 上是一個永遠綠的步驟 |
| Larastan 摘要取錯欄位 | 印 `errors=[]` | 標準格式裡頂層 `errors` 是「通用錯誤」陣列不是計數，**100 個檔案錯誤時它仍然是 `[]`**；計數在 `totals.file_errors`。但**還有一種扁平格式** `{"result":"failed","errors":N}`，那裡它才是整數 —— 解析器與文件都必須兩種都吃（2026-09-05 補上後者） |
| `npm audit` 網路失敗 | 報成「有 finding」，CI 收到 22 | `exit 1` 一碼兩義。一次網路抖動就變成一份假的資安報告 |
| 覆蓋率報告用固定的 `/tmp` 路徑 | phpunit exit 255，但 `docker cp` 仍成功並印 ✔ | 複製出來的是**上一次的舊報告** |

### 會說謊的訊息

| 缺陷 | 症狀 |
|---|---|
| `cx fresh` 的確認閘門在 `_fresh_migrate` **之後** | 使用者按取消，畫面印「未變更任何檔案」，`git status` 卻多出 3 個 `M` |
| WAF「攔截率」對照 | 同一畫面上「主動探測擋下 100%」與「WAF 擋下 0 項」並列。後者量的是被動掃描的 alert 差異，恆為 0 |

### 真正的安全問題

| 缺陷 | 說明 |
|---|---|
| `phpunit.xml` 的 `force="true"` 在容器裡無效 | PHPUnit 的 force 只寫 `putenv()` 與 `$_ENV`，不寫 `$_SERVER`；Laravel 讀 `$_SERVER` 優先。**實測容器裡裸跑 `php artisan test` 打的是真的 dev MySQL**。目前沒有測試用 `RefreshDatabase`，所以還沒造成損失。已列入 claude.md §0 紅線 |
| `cx fresh` 封存資料庫必定失敗 | `${CX_DB_DATABASE:-pwg}` 與 `${MYSQL_ROOT_PASSWORD:-password}` 兩個 fallback 都會生效（外層 shell 沒有這兩個變數），而且 `--filter name=mysql` 不分專案／模式。封存是刪除前的唯一安全網，它不該靠猜。修正後實測 dump 出 10 個 table |

### 順手清掉的

- 容器路徑以 root 在 bind mount 的 `backend/` 留下 `root:root` 的
  `.phpunit.result.cache` 與 `storage/*-backend.xml` ——
  原生 runner 寫不進去，submodule 多出刪不掉的未提交變更。
  改成 `-u $(id -u):$(id -g)` 執行。
- `_test_env_pairs` / `_test_php` / `_test_coverage` 三份環境變數清單，
  後兩份各自抄了一遍而且漂移（6 個 vs 3 個）。現在都讀同一個來源。

---

## 四道防線

| 防線 | 工具 | 狀態 | 最後結果 |
|---|---|---|---|
| ① Quality | Larastan | ✅ | 0 errors（level 5 + `checkModelProperties`） |
| ① Quality | SonarQube scanner | ⚠ 可執行但未跑 | 需要 `cx sonar up` 起常駐 server |
| ② SAST | Semgrep | ✅ | 298 條規則 / 267 檔；**0 ERROR**、9 warning、5 筆有書面理由的抑制 |
| ③ SCA | Trivy fs（vuln + secret + misconfig） | ✅ | 乾淨 |
| ③ SCA | composer audit / npm audit | ✅ | 乾淨 |
| ④ DAST | OWASP ZAP baseline | ✅ **已執行** | **FAIL-NEW 0**、WARN-NEW 3、PASS 64（`reports/dast/`） |
| ④ DAST | ModSecurity WAF 攔截率 | ✅ **已量測** | 攻擊 6 項全擋（**100%**）、正常請求 0 誤擋（`reports/dast/compare/waf-probe.json`） |
| — | gitleaks 全歷史 | ✅ | 三個 repo 皆乾淨 |

閘門定義（來自 `claude.md` §5）：

* ① Larastan level 達標 + Sonar Quality Gate PASSED
* ② **無 ERROR 等級 finding**（warning 仍會完整列出，但不擋）
* ③ 無 HIGH/CRITICAL，除非在 `.trivyignore.yaml` 且**有到期日**
* ④ 無 High risk alert

---

## 2026-09-05 稽核與修復

對「原始需求是否確實落地」做了一輪逐項查證，找到並修掉 **26 個缺陷**，
其中三個會讓已宣告完成的功能實際上是壞的：

| # | 缺陷 | 為什麼之前沒被發現 |
|---|---|---|
| 1 | **原生部署的 Filament 後台是全壞的** | `nginx_php_prefixes` 只有字面 `/livewire`，而 Livewire v4 的端點前綴由 `APP_KEY` 推導（`/livewire-<hash>/`）。比對不到就掉進 `location /` 被轉給 Nuxt。24.04／26.04 兩次 `failed=0` 的部署都帶著這個缺陷 —— 因為驗證只斷言「攻擊被擋成 403」，從來沒有斷言「正常的 Livewire 請求過得去」 |
| 2 | **test 模式缺 phpMyAdmin** | 規格明文要求，`docker/env/test.env` 也預留了 `PHPMYADMIN_PORT=18891`，但 service 從來沒被寫出來 |
| 3 | **`cx setup system` 一路把成功報成失敗** | `_setup_system_have` 少一個 `acl)` 分支，於是 apt 完全成功之後複驗仍判定「裝完還是不可用」 |

新增的機制（讓同一類缺陷下次會被自動抓到）：

* `cx verify` 多了 **cli / docs / tui / waf / acl** 五個範圍。前三個不需要
  Docker 也不需要 `.env`，在剛 clone 下來的樹上就跑得完
* `cx style`（Pint + Prettier）與 `cx lint` 的五個範圍（含 `shellcheck`）
* `cx fresh` 的**重建階段與 `--rollback`** —— 封存的另一半終於存在，
  而且第一次真的被還原過
* `cx doctor` 補上文件早就宣稱會做的**埠**與**子模組**檢查
* TUI 補上 15 個原本到不了的動作

完整的需求追溯與實測結果見 [`acceptance.md`](acceptance.md)。

### 供應鏈釘版本，順手抓到 Docker 與原生跑在不同的 CRS 大版本上

全庫的外部映像本來有九個是浮動的。把它們一一釘住的過程中，
`owasp/modsecurity-crs:nginx-alpine` 揭露了一件比「版本漂移」嚴重得多的事：

| | CRS 版本 | 來源 |
|---|---|---|
| Docker（`cx test`） | **3.3.10** | `:nginx-alpine` 這個 tag 完全沒有版本成分，而它當時指向的是 3.3 系列 |
| 原生（Ansible） | **4.30.0** | MyGuard 的 apt repo |

也就是說 **Docker 側量到的 WAF 行為，跟實際上線的那一套不是同一個大版本**，
而 `docker/waf/.../main.conf` 從一開始就是照 CRS 4 寫的
（裡面那條 `setvar:tx.crs_setup_version=400` 與 901001 的註解）。

把 Docker 釘到 `4.28.0-nginx-alpine-202608131208` 之後，主動探測立刻紅了：
攻擊仍然 100% 擋下，但**正常的 Livewire POST 被擋成 403** ——
排除清單只對 CRS 3.3 調校過。追下去是連續兩條 CRS 4 才有的規則：

1. `941390`（Javascript method detected）—— 補上之後 Docker 過了
2. `942550`（JSON-Based SQL Injection）—— 原生的 4.30 又冒出這一條

**兩次都代表原生部署的 Filament 後台一直有這個誤判，只是沒有人量過。**

所以最後不是再補第三條 ID，而是改成**依 tag 移除**
（`ctl:ruleRemoveByTag=attack-sqli` / `attack-xss`）：
逐條列 ID 在這裡是結構性錯誤 —— 兩條路徑本來就跑不同版的 CRS，
而 CRS 每次改版都會加規則。範圍沒有變寬（原本列的 941/942 就是這兩個家族，
只是列不齊），而這兩條路徑之外的攻擊面完全沒有放寬。

修完之後兩條路徑的實測（引擎都切到 `On`）：

| | Docker（CRS 4.28） | 原生（CRS 4.30） |
|---|---|---|
| 6 項攻擊 | 全部 403 | 全部 403 |
| 正常 Livewire POST | 通過 | 419（Laravel 自己擋 CSRF token —— 代表**過了 WAF**） |
| `/admin/login`、`/` | 通過 | 200 / 200 |

守門員是 `cx scan dast` 的主動探測（`bin/lib/waf_probe.py`）：
它同時量「攻擊擋不擋得住」與「正常請求過不過得去」，
而第二項正是這兩次缺陷唯一會現形的地方。

一句話總結本輪的教訓：**這個專案已知的缺陷有一半以上不是「程式寫錯」，
而是兩個地方對同一件事的說法不一致，而且沒有任何東西在盯著。**
所以新增的檢查一律跨檔比對，而且兩邊都從實際的東西推導 ——
再開一份手打的清單只會變成下一個會漂移的地方。

---

## 2026-09-05（第二輪）新增功能與抓到的缺陷

這一輪的起點是四份 TUI 的使用回報。**其中三份的根因是同一個缺陷**，
而那個缺陷本身不在被回報的功能裡。

### 一個缺陷解釋了三份回報

回報說「執行錯誤時沒有錯誤訊息」「沒有 acl 選單」「git 缺少 pull」。
前兩者其實一直都在（`tui.sh` 有 `_tui_acl`，也有 pull）。所以先查為什麼看不到：

```
cx --ui dialog tui   （機器上沒裝 dialog）→ 零輸出、exit 0
```

`_cx_dlg` 執行 `dialog` 得到 127 → `_tui_menu` 的 `if` 為假 → 回傳 1 →
`cmd_tui_main` 的 while 當成「使用者選了離開」→ 正常結束。
**使用者面對一個不抱怨也不做事的指令，於是合理推論「選單裡沒有那些功能」。**

修法是把「使用者取消」與「後端壞了」分開（0/1/255 vs 其餘），
並讓 `cx_ui_init` 在明確指定的後端不存在時當場報錯。

### 這一輪抓到的其他缺陷

| # | 缺陷 | 為什麼之前沒被發現 |
|---|---|---|
| R-1 | **`cx fresh` 會刪掉根目錄的 `docker-compose.yml` 與 `.dockerignore`** —— `_fresh_delete` 迴圈跑的是 `FRESH_DELETE` **加上** `FRESH_MIGRATE`，而後者含那兩個檔 | 舊註解寫「Phase 2 會重寫根目錄那兩份」，遷移做完之後那句就過期了。實測 `cx fresh --phase delete` 之後 `cx dev config` 回 EX_PRECOND「缺少 base compose」——**一個「重建成可以直接跑的新專案」的動詞，交出來的樹是不能跑的** |
| R-2 | **`cx git commit` 把失敗報成成功** —— 每個 `cx_run git add/commit` 都沒有接退出碼，然後無條件印 ✔ | 實測：pre-commit hook 失敗時印「✔ 主庫已提交（4 項，含 gitlink）」、exit 0，而 repo 裡一個 commit 都沒有 |
| R-3 | **骨架產生之後，範本自己的保護整組消失** —— `cx init shop` 產出的專案 `cx verify cli` 有 9 個 FAIL，其中 6 個是測試資料庫 guard 與 ESLint | `composer create-project` / `nuxi init` 產生的是**框架的**骨架。GRD-wire 的說明早就寫過同一件事，只是當時說的是 carryover，實際上 scaffold 更嚴重（連檔案都不存在） |
| R-4 | **WAF 的 body 上限比 nginx 小**（Docker 12.5MB < edge 64m），A16 的順序反了 | 原生側從 `app_max_upload_mb` 推導整條鏈並明文要求這個順序 —— 兩條路徑對同一件事的規則不一致，而 Docker 是錯的那一邊 |
| R-5 | **Docker 少了四個 PHP 前綴**（`/filament` `/login` `/logout` `/broadcasting`）與 `/images/` | 實測都回 Nitro 的 404。`/login` `/logout` 是 Laravel 預設的 auth 路由名，`/broadcasting/auth` 是 Echo 的授權端點，`/images/` 是 Filament 的資產路徑 |
| R-6 | **`^~ /admin` 會吃掉 `/admino`** —— `^~` 是純前綴，原生的 `(/|$)` 不會 | 邊界差異，比清單差異更難發現 |
| R-7 | **CSP / COEP / CORP 只有 Docker 有** —— 原生的 `nginx_csp` 是空字串 | 正好是反過來的：正式機才是真的會被打的那一邊 |
| R-8 | 我自己在修 TUI 時引進的回歸：用 `2>&1 \| tee` 抓輸出會讓子行程的 stdout/stderr 變成 pipe，而 `common.sh` 的顏色是看 `[[ -t 2 ]]` | 選單裡跑的每個指令都失去紅✘綠✔，**反而更難看出哪裡失敗**。改用 `script -qec` 給真的 pty（實測顏色保留、退出碼原樣帶回） |

### 新增的功能

| 動詞 | 做什麼 |
|---|---|
| `cx init <名稱>` / `cx re-init` | 把範本設定成新專案。**幾乎沒有自己的邏輯** —— 依序呼叫 `cx rename`（必須在前）、`cx fresh`、`cx git remote-init/remote-set`。閘門用 `INIT <新名字>` 而不是 fresh 的 `DESTROY <舊名字>` |
| `cx deploy hosts` | inventory 的產生與驗證（init/add/rm/show/check/edit）。`check` 擋 A15 的三種違反 |
| `cx git feature start/finish/list` | gitflow。從 dev 開、合回 dev（`--no-ff`），不推送也不刪分支 |
| `cx git config identity/editor/show` | 三個 repo 一起設，或 `--global`。editor 會拒絕 `true`/`false`/`:`/`cat` 這類 no-op |
| `cx git commit --repo` | 只提交 main / backend / frontend 其中一個 |
| `cx git remote-set` | 指到現成的 remote，不經過 gh |

### 新增的檢查

| id | 守什麼 |
|---|---|
| `A13-parity` | `docker/edge` 的 PHP 前綴 ⊇ `group_vars` 的 `nginx_php_prefixes` |
| `A16` | WAF 的 body 上限 ≥ edge 的 `client_max_body_size`（跨檔） |

### ⚠ 誠實說明：哪些東西**不能**拆到不同主機

使用者要求「把 nginx、前端、後端、資料庫部署到不同或相同主機」。
實際檢查後：**nginx / 前端 / 後端必須在同一台**，這不是設定問題而是架構事實 ——
`php_fpm_socket` 是 unix socket，前端 PM2 綁 `127.0.0.1:3000`。
要拆得改成 TCP + 內網授權 + upstream 指到遠端，那是架構變更。

**可以**拆的是資料庫層：多台 `web` + 其中一台兼 `db_primary`
（A15 要求 `db_primary` 剛好一台且必須也在 `web`，因為 migration 掛在 `web` 的 gate 上）。
`cx deploy hosts check` 會擋下違反，並提醒多台 web 要一併處理的四件事。

---

## 仍未驗證的項目

### Ansible 真機進度

驗證目標是一個 `pm/ansible-target:24.04` 容器（Ubuntu 24.04 + systemd + sshd +
sudo NOPASSWD，SSH 在 `127.0.0.1:2222`）。它跑真的 systemd，
`systemd_service`、handler、服務啟動順序全部是真的。

**2026-09-04：`site.yml` 已在這個目標上完整跑通 —— 475 個 task、`failed=0`。**
從 apt repo、MySQL 8.4、PHP 8.5、Node/PM2、nginx+ModSecurity 到 clone、
composer install、migration、nuxt build、換 symlink、健康檢查，全程沒有人工介入。

`cx deploy syntax` 與 `cx deploy lint`（production profile）全綠，
但那只證明語法與規則正確。以下是把它從「連 syntax 都沒跑過」推到全綠的實跑進展
（每一項都是只有真的裝起來才會現形的缺陷）：

| 日期 | 走到第幾個 task | 卡在哪 | 處置 |
|---|---|---|---|
| 09-04 | 178 | MySQL 執行期設定驗證 | handler 通知不跨 play 保留 → `verify.yml` 改成依實際值自癒 |
| 09-04 | 185 | 應用帳號 TCP 登入 | 目標機缺 `python3-cryptography`（8.4 的 `caching_sha2_password` 在非 socket 連線要 RSA）→ 加進 `common` 與 `mysql` 的套件清單 |
| 09-04 | 179 | `assert` 的 `fail_msg` 求值 | 被 `when` 略過的任務照樣寫入 register → 改 register 到另一個變數再 `set_fact` |
| 09-04 | 235 | `pm2-deploy.service` 起不來 | dump 是空的時候 `pm2 resurrect` 不留 pid file → `enabled` 與 `state: started` 拆開，只有 dump 裡真的有 process 才 start |
| 09-04 | 278 | `nginx -t` emerg：`client_max_body_size` 重複 | 發行版 `nginx.conf` 的 `http{}` 已宣告 → `facts.yml` 讀出 `nginx_existing_directives`，模板逐一跳過 |
| 09-04 | 308 | `regex_search` 丟 `'NoneType' object has no attribute 'group'` | 帶捕獲組時沒比對到會直接丟例外，`when` 也擋不住（args 在 finalization 求值）→ 改成純字串管線 |
| 09-04 | 335 | `mv: missing destination file operand` | 折疊純量（`>-`）的續行縮得比第一行深 → YAML 保留換行，指令被切成兩行 |
| 09-04 | 473 | healthcheck 4 項失敗 | ① queue unit 名稱被組成字面 `pm-queue@` + 未展開的反向參照 ② PM2 systemd 單元沒被接管 ③ 目標機解析不到 `app_domain` 卻重試 12 次 |
| 09-04 | **475** | **failed=0，全部通過** | `/up` 200、`/` 200、`/admin` 302；queue×2 / pm2 / schedule.timer / nginx / php-fpm / mysql 全部 active |

每一項的完整說明見 [`ansible-reference.md` §7–§8](ansible-reference.md) 與
[`troubleshooting.md`](troubleshooting.md)。

**2026-09-05：把 `waf_enabled` 打開之後又跑通了一輪 —— 533 個 task、`failed=0`。**
打開 WAF 這件事本身就抓到一個「存在了整段時間、但因為預設關閉所以沒人踩到」的缺陷
（下表 W-1）。

#### 2026-09-05 打開 WAF 與冪等性驗證抓到的缺陷（全部已修）

| # | 缺陷 | 為什麼一直沒被發現 |
|---|---|---|
| W-1 | `waf_packages_alternates` 有**兩套不相容的形狀**：role defaults 是 mapping（主要名稱 → 備選清單，`packages.yml` 用 `dict2items` 讀），而 `group_vars/all/main.yml` 寫成 list of `{name, packages}`。group_vars 優先序較高 → **整個備選機制從來沒有生效過** | `staging.yml` 的 `waf_enabled` 預設 false。打開的第一秒就炸，而且 ansible-core 2.19+ 只回一句 `can only concatenate list (not "CapturedExceptionMarker") to list`，完全指不到真正的原因。已改成 mapping，並在 `packages.yml` 加上形狀斷言，訊息直接說明該改 group_vars 哪一份 |
| W-2 | **用同一個 `release_id` 重跑必定失敗** —— clone 之後還有 composer install / npm ci / symlink 等寫入，工作目錄對 git 必然 dirty，git 模組回 `Local modifications exist (force=no)` | 平常 `release_id` 是每次新的時間戳。但「用同一個 id 重跑」正是**部署失敗後重試**最自然的動作。改成把 release 當**不可變產物**：`.git` 與 `artisan`（前端是 `package.json`）都在就不重新 clone，改讀既有 commit。前後端各一份 |
| W-3 | `'CHANGED' in stdout` —— 而金鑰正規化在沒變時 echo 的是 **`UNCHANGED`**，子字串包含恆真 | 於是 keyring 永遠回報 changed，掛在它上面的 `apt update` 每次部署都白跑一次。改成完全比對；nodejs 那份原本是寫死的 `changed_when: true`，改成用 `cmp` 比對並用**互不為子字串**的 `KEY_SAME` / `KEY_REPLACED` |
| W-4 | `common` 的 `file`（mode `02750`）與 `acl` 在 `/srv/pm` 上**互相覆蓋** —— mode 的群組三位元顯示的是 **ACL mask** 而不是 `group::`，而 ACL 給了 deploy `rwx` → mask 必為 `rwx` → stat 讀出 `02770` ≠ `02750` | 不只是 changed 數字難看：`file` 設回 `02750` 的當下 **mask 被縮成 `r-x`，deploy 對 `app_root` 的寫入權限就沒了**，要等 `acl.yml` 再跑一次才恢復。同一次執行會收斂，但用 `--tags` 只跑其中一個就會留下壞掉的權限 |
| W-5 | `/var/log/pm` 被 `common`、`mysql`、`nodejs_pm2` **三個 role 同時管**，各自要不同的 owner/group/mode → 每次部署互相翻轉 | mysql 改成「不存在才建、已存在就完全不碰屬性」 |
| W-6 | `command` + `creates:` 命中時回的是 `rc=0` + stdout `skipped, since ...`，**不是 task 層級的 skip**，所以 `changed_when: rc == 0` 照樣求值為真 | PM2 的 systemd 單元每次都謊報 changed。`changed_when` 補上 `'skipped, since' not in stdout` |
| W-7 | `find ... -delete` **不論有沒有刪到都回 0**，所以 `changed_when: rc == 0` 恆真 | 舊備份清理每次都回報 changed，實際上多數時候一個檔案都沒刪。改成 `-print -delete` 並看 stdout |
| W-8 | `mysql_user` 用 `plugin_auth_string` 時，MySQL 存的是加鹽雜湊，模組**無法比對**，`update_password: always` 等於每次重設密碼 | 預設改為 `on_create`。輪替密碼變成明說的動作：`-e mysql_app_password_update=always` |
| W-9 | `debconf` 的 password 型別是**唯寫**的（`debconf-get-selections` 不回傳密碼值），模組永遠比對不出有沒有變 | 標成 `changed_when: false` —— 真正的狀態收斂是套件安裝本身 |

#### 冪等性實測（`-e release_id=` 釘死，連跑）

必須釘住 `release_id`，否則它預設是每次新的時間戳，deploy role 本來就會 changed。

| 輪次 | changed | 說明 |
|---|---|---|
| 全新機第一次 | 127 | `failed=0`、533 個 task |
| 修 W-1..W-9 之前的第二次 | 16 + **failed=1** | 失敗的就是 W-2 |
| 修完之後 | **9**、連兩次相同 | 已收斂 |

剩下的 9 項**全部是「每次部署本來就要做事」**，不是缺陷：
migrate 前的 mysqldump、`config:cache` / `view:cache` / `event:cache` /
`filament:optimize`、`npm ci`、Nuxt 建置、`pm2 startOrReload`、`pm2 save`。
對一支會重建並重新上線的部署 playbook 來說，`changed=0` 本來就不是正確的目標 ——
**基礎設施收斂的部分要冪等，重新部署的部分不該冪等**。

下列每一項仍要對**真的 staging 機器**（不是容器）跑過才算數：

| 項目 | 怎麼驗 |
|---|---|
| ~~MyGuard 套件名歧異~~ | ✅ 2026-09-05 已驗：三個主要名稱全部第一輪命中（`libnginx-mod-http-modsecurity 3:1.31.5-1myguard1~noble`、`libmodsecurity3 3.0.16-3myguard1~noble`、`modsecurity-crs 4.29.0+5.260831-3myguard1~noble`），不需要 alternates |
| MySQL 8.4 from Oracle repo | 真機安裝（Debian 的 `default-mysql-server` 是 MariaDB） |
| PHP 8.5 from ondrej PPA / sury | 真機安裝 |
| certbot snakeoil bootstrap（A5） | 全新機第一次部署，觀察 vhost 是否從 snakeoil 正確切到真憑證 |
| ~~CRS 排除規則在原生 nginx 的載入順序~~ | ✅ 2026-09-05 已驗：`/etc/nginx/waf/main.conf` 的順序是 crs-setup → exclusions-before → CRS 本體 → exclusions-after，實際載入 **684 條** CRS 規則，`exclusions-before` 的 Livewire 樣式是 `@rx ^/livewire(-[0-9a-zA-Z]+)?/`（前綴由 APP_KEY 推導，不能寫死），`nginx -t` 通過、服務 active |
| ~~安全標頭在 location 內的繼承~~ | ✅ 2026-09-05 已驗：`/`、`/up`、`/_nuxt/x.js`、`/storage/x` 四處都帶到標頭 |
| ~~Ansible 冪等性~~ | ✅ 2026-09-05 已驗，見上表 |
| ~~release prune 不刪 current~~ | ✅ 2026-09-05 已驗，完整走過「部署三次 → rollback 到**最舊**的那個 → 再部署一次」：<br>① `RELEASE01/02/03` 依序部署，第三次觸發 prune（共 4 個 → 刪掉最舊的 `IDEMPOTENCY_A`）<br>② rollback 到 `RELEASE01`（刻意挑最舊的 —— 那正是 `prune.yml` 檔頭警告的情境 (a)：「按 mtime 排序又不排除 current，rollback 之後 current 指的是比較舊的」），`current -> RELEASE01`、`/up` 回 200<br>③ 部署 `RELEASE04`，prune 印出「保護：RELEASE04｜current 與本次 release 都在保護名單內」，刪掉 `RELEASE01`<br>④ 結束後 `current -> RELEASE04` 解析得到、`/up` 回 200，沒有懸空 symlink |
| PM2 fork 跑 Nuxt `.output` | 真機或本機裝 pm2 後試跑 |
| 多主機 `serial` 滾動 | 需要兩台以上的目標機 |

流程：

```bash
cp ansible/inventory/hosts.yml.example ansible/inventory/hosts.yml   # 填真實主機
cx deploy ping staging          # 先確認 SSH 與 become
cx deploy check staging         # --check --diff 乾跑
cx deploy apply staging         # 真的跑（會列出目標主機並要求確認）
```

> `--check` 不是萬能：`command` / `shell` 在 check 模式會被 skip，
> 所以「乾跑通過」不等於「實際跑一定會過」。

### 應用層（不是基礎設施的問題）

| 項目 | 說明 |
|---|---|
| Sanctum SPA 完整登入流程 | `/sanctum/csrf-cookie` 回 204、`/api/user` 未認證回 401 都驗過了，但**沒有真的走完一次登入** —— 前端目前沒有登入頁 |
| Filament 後台的實際操作 | `/admin/login` 回 200，但沒有建立過管理員也沒有登入過（`cx db admin` 可建） |
| CORS 的真實跨源行為 | 設定值驗過（`config/cors.php` 指向 `FRONTEND_URL`、`supports_credentials: true`），但三個模式都是同源，沒有做過真的跨源請求 |
| 業務邏輯 | backend 目前是骨架：1 個 model、0 個 Filament Resource、4 個 migration 全是 scaffold。frontend 是 1 頁 |

### `cx fresh` 的重建階段

備份、驗證封存、確認閘門、刪除都可用且有測過。
**重建階段與 `--rollback` 仍未實作** —— 打了會得到 `EX_USAGE` 並指向本節。

---

## 環境相依

`cx doctor` 會逐項檢查。目前已知的落差：

| 項目 | 狀態 | 影響 |
|---|---|---|
| Docker daemon | ✅ 29.7.2 | — |
| host 的 `pdo_sqlite` | ✅ 已安裝 | `cx --runner native test back` 可用（2026-09-04 實測 rc=0） |
| SonarQube | 未啟動 | `cx scan code` 會略過 scanner 並警告 |
| 目標主機 | ✅ 本機容器，24.04 與 26.04 各一 | `cx deploy apply` **完整實跑**（不是 --check）：24.04 ok=498、26.04 ok=491，兩邊 failed=0。Dockerfile 在 `docker/ansible-target/`（2026-09-05） |

> `sudo usermod -aG docker $USER` 之後**必須** `wsl --shutdown`（Windows 端）再重開。
> `usermod` 只影響之後才建立的登入 session，既有的 shell 不會生效 —— 這是本專案
> 卡最久的一個環境問題。
