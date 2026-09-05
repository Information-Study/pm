# 進度追蹤

> 最後更新：**2026-09-04**
>
> 最後一次完整回歸：`cx doctor` 25 通過 / 1 警告 / **0 失敗**；
> `cx verify all` **52 項全過**；12 個 cx 動詞（doctor / verify / scan ×4 /
> test ×2 / deploy ×2 / db / git）全數 exit 0；三個模式的 14 個容器同時運行。
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
| 2 | Docker 三模式 + 多階段映像 + edge + WAF | ✅ **完成並實測** | `cx verify all`（52 項全過） |
| 3 | 前後端重建 + 三 Git 初始化 | ✅ 完成 | migration / 測試 / 端點皆已實跑 |
| 4 | DevSecOps 四道防線 + `cx scan` | ✅ **四道全部跑得動** | 見下表 |
| 5 | Ansible 12 role + playbook | ✅ **對真實 systemd 目標完整跑通**（475 task、failed=0） | `cx deploy apply`（見下方「Ansible 真機進度」） |
| 6 | `README.md`、`ansible/README.md`、本文件 | ✅ 完成 | — |

---

## `cx` 動詞實作狀態

| 動詞 | 狀態 | 備註 |
|---|---|---|
| `setup` | ✅ | env / dirs / **native** / system / tools / deps（`guard` 仍在，但**不含**在無參數的 `setup` 裡） |
| `doctor` | ✅ | 含 Phase 2 產出物與動詞完整性檢查（33 項，含 dispatcher 對照表） |
| `dev` `prod` `up` `down` `restart` `ps` `logs` `sh` `build` `config` `dc` | ✅ | 全部經 `cx_compose_init`，四個 compose 陷阱集中處理 |
| `test`（compose 動作） | ✅ | `cx test up` 等同 `cx --mode test up` |
| `test back/front/all/coverage/larastan` | ✅ | 後端走 sqlite `:memory:`；前端的 `nuxt typecheck` 原本缺 `tsconfig.json` 與 vue-tsc/typescript/@types/node，已補齊 |
| `db` | ✅ | status / shell / wait / migrate / fresh / seed / dump / restore / admin |
| `scan` | ✅ | code / sast / sca / dast / secrets / all |
| `sonar` | ✅ | up / down / status / logs / token / url / wait |
| `verify` | ✅ | static / runtime / app / ansible / all |
| `deploy` | ✅ | syntax / lint / check / ping / facts / vars / apply / app / rollback / galaxy |
| `git` | ✅ | status / **fetch** / **pull** / sync / commit / branch / guard / remote-init / scan-secrets / push |
| `art` `composer` `npm` | ✅ | 容器與原生兩條路都可用，`--runner` 可強制；`npm --backend` 是新增的（舊 `npm-php` service 從來不存在） |
| `lint` `tui` `install` `uninstall` `help` | ✅ | |
| `code` | ✅ | 用 VS Code 開專案根（不是所在的子目錄） |
| `pma` | ✅ | 開 phpMyAdmin；只有 dev 有，埠從合併後的 compose 設定讀 |
| `php` | ✅ | 直接跑 php（`cx art` 只涵蓋 artisan），兩條 runner 都支援 |
| `setup system` | ✅ | 需要 root 的系統套件；有確認閘門，sudo 不可用時只印指令 |
| `setup native` | ✅ | system → tools → deps 一次做完（2026-09-04 新增） |
| `fresh` | ⚠ 部分 | 備份／驗證／確認閘門／刪除都可用；**重建階段與 `--rollback` 仍未實作** |

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
| 之後 | `cx doctor` 32/0/0、`cx verify` 39 通過 0 失敗、17 個容器仍在跑、端點全 200 |
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

一句話總結本輪的教訓：**這個專案已知的缺陷有一半以上不是「程式寫錯」，
而是兩個地方對同一件事的說法不一致，而且沒有任何東西在盯著。**
所以新增的檢查一律跨檔比對，而且兩邊都從實際的東西推導 ——
再開一份手打的清單只會變成下一個會漂移的地方。

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

下列每一項仍要對**真的 staging 機器**（不是容器）跑過才算數：

| 項目 | 怎麼驗 |
|---|---|
| MyGuard 套件名歧異 | `packages.yml` 會用 `apt-cache policy` 逐一探測，全落空時 fail 並附上 `apt-cache search` 的實際輸出 —— **這段邏輯本身也沒跑過** |
| MySQL 8.4 from Oracle repo | 真機安裝（Debian 的 `default-mysql-server` 是 MariaDB） |
| PHP 8.5 from ondrej PPA / sury | 真機安裝 |
| certbot snakeoil bootstrap（A5） | 全新機第一次部署，觀察 vhost 是否從 snakeoil 正確切到真憑證 |
| CRS 排除規則在原生 nginx 的載入順序 | Docker 側已實測；原生側的 `nginx_myguard` 是另一套路徑 |
| 安全標頭在 location 內的繼承 | `curl -I` 打 `/storage/x` 與 `/_nuxt/x` |
| release prune 不刪 current | 部署三次 + rollback 後再部署一次 |
| PM2 fork 跑 Nuxt `.output` | 真機或本機裝 pm2 後試跑 |

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
