# 驗收清單（需求追溯）

> 這份文件把**原始需求**接到**可重跑的檢查**上。
>
> 它不是第四份權威來源 —— 每一列的「怎麼驗」都指向一個真的能執行的指令。
> 人工項目集中在 §7，每一列都必須附上實測輸出與日期。
>
> 原則（`claude.md` §12）：**沒跑過的就寫沒跑過。**
> `cx verify` 的三種結果嚴格分開 —— PASS（真的驗過）、FAIL（真的壞了）、
> SKIP（這次沒辦法驗，**不算通過**）。

---

## 1. 需求追溯矩陣

| # | 原始需求 | 怎麼驗 | 狀態 |
|---|---|---|---|
| R1 | 舊環境清理與專案全新初始化（刪 `.git`／前後端，重建 Nuxt 4 與 Laravel 13 + Filament v5 + Larastan，三個 Git） | `cx fresh --mode carryover` 與 `--rollback`（§6） | ✅ 2026-09-05 拋棄式副本實跑 |
| R2 | 三層式 Docker Compose（dev／test／prod） | `cx verify static app runtime`（§2） | ✅ |
| R3 | DevSecOps 四道防線（Quality → SAST → SCA → DAST）＋ ModSecurity WAF | `cx scan all`、`cx verify waf`（§4） | ✅ |
| R4 | Ansible 原生部署（PM2 + Nginx + MyGuard APT） | `cx deploy syntax/lint/check/apply`（§5） | ✅ 對 systemd 容器；雲端機仍未驗 |
| R5 | 統一入口 `cx`（TUI + CLI，全域可用，涵蓋 git／ansible／npm／php／artisan／composer） | `cx verify cli tui`、§3 的動詞矩陣 | ✅ |
| R6 | 文件（`claude.md`／`README.md`／`ansible/README.md`） | `cx verify docs` | ✅ |
| R7 | facl 檔案權限 | `cx verify acl`、`cx acl check`（§7） | ✅ |
| R8 | 完整測試清單並跑完 | 本文件 + `reports/verify/<時間戳>.md` | ✅ |

### 一次跑完全部

```bash
cx verify all          # cli docs tui static runtime app waf acl ansible
cx scan all            # 四道防線 + 祕密掃描
cx test all            # 後端 PHPUnit + 前端型別檢查
```

`cx verify all` 之外的人工項目見 §7。

---

## 2. 三個模式 × 能力矩陣

每一格的驗證方式都在 `cx verify` 裡，編號對應報告中的 ID。

| 能力 | dev | test | prod | 檢查 ID |
|---|---|---|---|---|
| edge 反向代理 | 8080 | 18080 | 80 | `ep-*` |
| Nuxt 前端 | 3000（HMR） | 13000 | 不發布 | `ep-*` |
| Laravel 後端 | 經 edge | 經 edge | 經 edge | `ep-*` |
| MySQL | 127.0.0.1:3306 | 127.0.0.1:13306 | **不發布** | `D13`、`D7` |
| phpMyAdmin | 8891 | **18891** | **無** | `check_prod_closed` |
| ModSecurity WAF | — | 18081 | — | `waf-*` |
| xdebug | 有（`debug`） | 裝了但預設 `off`（`docker/env/test.env` 的 `XDEBUG_MODE=off`；`cx test coverage` 會臨時打開） | **無**（build 斷言） | `D12`、`rt-*` |
| `display_errors` | On | **Off** | **Off** | `zz-mode-*.ini` |
| `APP_DEBUG` | true | false | false | `docker/env/*.env` |
| 原始碼掛載 | bind mount | 烘進映像 | 烘進映像 | `D14` |
| supervisord（5 個程序） | ✔ | ✔ | ✔ | `D5-*` |
| 一次性掃描容器 | — | ✔ | — | `3.8` |

> test 的 `display_errors` 在 2026-09-05 之前是 On（沿用 `zz-mode-dev.ini`）。
> test 正是被 ZAP 掃、被 ModSecurity 擋的那個模式 —— 錯誤顯示打開等於在 DAST
> 的攻擊面上多開一個資訊洩漏。現在有專屬的 `zz-mode-test.ini`。

---

## 3. 動詞 × runner 矩陣

「原生」那一欄是關鍵：專案的每一個功能都要能**完全用 Docker**或
**完全用原生工具鏈**跑完，兩條路各自獨立。被指定的那一邊不可用時一律硬失敗，
不會偷偷退回另一邊 —— 允許靜默 fallback 的話，「原生路徑可以獨立運作」
這件事就永遠無法被驗證。

| 動詞 | docker | native | 備註 |
|---|---|---|---|
| `art` / `php` | ✔ | ✔ | 原生需要 `backend/vendor` |
| `composer` | ✔ | ✔ | 兩邊的 vendor 不保證可互換（musl vs glibc） |
| `npm` / `npm --backend` | ✔ | ✔ | backend 的容器路徑刻意用 glibc 映像 |
| `db`（除 restore） | ✔ | ✔ | mysql client 跑在 mysql 容器裡 |
| `db restore` | ✔ | ✔ | |
| `test back` / `test front` | ✔ | ✔ | 原生需要 `pdo_sqlite` |
| `test coverage` | ✔ | ✘ | 需要容器內的 xdebug |
| `style` / `lint php\|js` | ✔ | ✔ | |
| `lint sh` | — | ✔ | shellcheck 是 host 工具 |
| `scan code` / `sast` / `sca` | ✔ | ✔ | |
| `scan dast` | ✔ | ✘ | 本機沒有 Java runtime |
| `scan secrets` | ✔ | ✔ | gitleaks 兩邊都是 host 工具 |
| compose 動詞 / `pma` / `sonar` | ✔ | ✘ | 這些**就是**容器操作 |
| `git` / `acl` / `deploy` / `verify` / `doctor` | — | ✔ | 與 runner 無關 |

`✘` 的那幾格不是缺陷，是誠實的宣告：打了會得到帶理由的 `EX_PRECOND`，
不會靜默降級。`cx verify` 的 `LC-declared-gaps` 盯著這一點。

### Docker 不可用時

```bash
DOCKER_HOST=unix:///nonexistent.sock cx doctor          # 應報「daemon 不通」
DOCKER_HOST=unix:///nonexistent.sock cx --runner auto composer -V   # 退回原生
DOCKER_HOST=unix:///nonexistent.sock cx --runner docker composer -V # 硬失敗 rc=3
```

---

## 4. DevSecOps 四道防線

| # | 防線 | 工具 | 閘門 | 退出碼 |
|---|---|---|---|---|
| ① | Quality | Larastan + SonarQube scanner | Larastan level 達標 + Quality Gate PASSED | 20 |
| ② | SAST | Semgrep | 無 **ERROR** 等級 finding（warning 顯示但不擋） | 21 |
| ③ | SCA | Trivy + composer audit + npm audit | 無 HIGH/CRITICAL，除非在 `.trivyignore.yaml` 且有到期日 | 22 |
| ④ | DAST | OWASP ZAP + ModSecurity | 無 High risk alert；**且正常請求不被誤擋** | 23 |

`cx scan all` 會**全部跑完**再回傳最嚴重的那個碼，不是遇到第一個 finding 就停。

> ④ 的「且正常請求不被誤擋」是 2026-09-05 補的。在那之前這條 lane 只看
> 「攻擊有沒有被擋」，於是「攻擊 100% 全擋、Filament 後台完全不能用」
> 這兩件事可以同時成立而沒有任何檢查會發現 —— 而那正是當時的真實狀態。

---

## 5. Ansible 原生部署

| 項目 | 怎麼驗 | 狀態 |
|---|---|---|
| 三個 playbook 的語法 | `cx deploy syntax` | ✅ |
| ansible-lint（production）+ yamllint | `cx deploy lint` | ✅ 0 finding／182 檔 |
| 對 Ubuntu 24.04 systemd 目標完整實跑 | `cx deploy apply` | ✅ ok=498 failed=0 |
| 對 Ubuntu 26.04 systemd 目標完整實跑 | `cx deploy apply` | ✅ ok=491 failed=0 |
| Livewire 端點真的走得到 PHP | role 的 `nginx_verify` 斷言 | ✅ 2026-09-05 補上 |
| MyGuard 套件名解析 | 需要真實機器 | ⬜ 未驗 |
| MySQL 8.4 from Oracle repo | 需要真實機器 | ⬜ 未驗 |
| certbot 真憑證流程 | 需要有公網 DNS 的機器 | ⬜ 未驗 |
| 多主機 `serial` / `any_errors_fatal` | 需要多台機器 | ⬜ 未驗 |

完整未驗清單見 [`progress.md`](progress.md)。

---

## 6. `cx fresh` 的完整循環

在 scratchpad 的**拋棄式副本**上跑，不動真的專案：

```bash
SP=<scratchpad>
git clone <專案> "$SP/fresh-drill"
export CX_ARCHIVE_ROOT="$SP/archive"
cx --root "$SP/fresh-drill" --yes fresh --mode carryover
cx --root "$SP/fresh-drill" --yes fresh --rollback
```

`--yes` 只在拋棄式副本上用。對真的專案一律讓確認閘門跑完
（刪除前要輸入 `DESTROY <專案名>`）。

---

## 7. 人工項目與證據

自動化驗不到的項目集中在這裡。每一列都要有**指令**與**實測輸出**。

| # | 項目 | 指令 | 實測結果 | 日期 |
|---|---|---|---|---|
| M1 | TUI 主選單與子選單畫得出來、進得去、離得開 | `script -q <log> -c 'cx tui'` 配鍵盤序列 | ✅ 主選單 9 項全部渲染；環境／容器／工具三個子選單都進得去並正確顯示內容（環境子選單在 2026-09-05 加入 `rename` 後為 9 項） | 2026-09-05 |
| M2 | phpMyAdmin 真的能登入並看到資料表 | `curl -s http://127.0.0.1:8891/ \| grep -c 'name="pma_password"'` → 1，然後瀏覽器實際登入 | ⚠ 部分：**登入表單現在確實會出現**（2026-09-05 修掉自動登入後實測，見下方）；「登入後看得到資料表」仍未走完 | 2026-09-05 |
| M3 | Filament 後台實際登入並操作 | `cx db admin` → 瀏覽器 | ⬜ 未驗（沒有建立過管理員） | |
| M4 | Sanctum SPA 完整登入流程 | 需要前端有登入頁 | ⬜ 未驗（前端目前沒有登入頁） | |
| M5 | 真實跨源 CORS 行為 | 三個模式目前都是同源 | ⬜ 未驗 |  |

> M3–M5 維持「未驗」。`/admin/login` 回 200、`/sanctum/csrf-cookie` 回 204、
> `/api/user` 未認證回 401 都是自動驗過的，但那不等於「走完一次登入」。
> 沒跑過的就寫沒跑過。
>
> ⚠ **M2 的「只驗到 HTTP 200」本身就是這一輪抓到的安全缺陷的藏身處。**
> 2026-09-05 的安全審查實測：`curl http://127.0.0.1:8891/` 不帶任何 cookie，
> 回的是 140,814 bytes 的**已登入**頁面（`<title>127.0.0.1:8891 / mysql |
> phpMyAdmin 5.2.3</title>`、內文有 `root@172.18.0.4` 與 logout 連結），
> 不是登入表單。原因是 `docker/compose/{dev,test}.yml` 設了 `PMA_USER: root`，
> 而官方映像一看到 PMA_USER 就把 `auth_type` 從 cookie 換成 config ——
> 登入畫面整個消失，任何連得到那個埠的人都自動以 **MySQL root** 登入。
>
> 自動登入的頁面回的**也是 200**，所以「只驗 HTTP 200」這個判準對它完全無感。
> 這正是本專案一再遇到的那一類：檢查存在、但它量的不是它宣稱在量的東西。
> 修法是移除那兩個環境變數（回到 cookie 認證，也就是 `bin/cmd/pma.sh` 一直以來
> 告訴使用者的流程），並新增 `SEC-pma-auth` 靜態檢查盯住它不會再被加回去。
> 修後實測：同一個請求變成 18,531 bytes 的登入表單（`name="pma_username"` /
> `name="pma_password"` 都在）；從 app_net 上的 `app` 容器內取也是 18,578 bytes
> 的登入表單，也就是容器網路那條升權路徑一併關閉。

---

## 6.5 本輪實測結果（2026-09-05）

環境：WSL2 Ubuntu 26.04.1・Docker 29.7.2・Compose v5.5.0・PHP 8.5.4・Node 24.20.0
三個模式全部從這個工作樹重新 build 並啟動（17 個容器同時運行）。

### `cx verify all`

**通過 88 ・ 失敗 0 ・ 未驗 2**（2026-09-05 本輪結束時；本輪開始時是 70）

本輪新增的檢查（每一項都是「同一類缺陷下次會被自動抓到」）：

| 家族 | 守什麼 |
|---|---|
| `hard-caps` / `hard-stop` | 三模式每個 service 的 `no-new-privileges` + `cap_drop: ALL`、`cap_add` 必須是允許表的子集；`app` 的 `stop_grace_period` 必須大於 `supervisord.conf` 的 `stopwaitsecs`（跨檔） |
| `4b` | 所有外部映像釘到明確版本 —— 拒絕 `latest`／`stable`／只有 major 的 tag |
| `GRD-*` | 測試資料庫防護的接線（`phpunit.xml` 真的指向 `tests/bootstrap.php`） |
| `LNT-eslint-*` | ESLint 的四個零件都在位（`cx fresh --mode carryover` 會把它們一起弄不見） |
| `TPL-*` | 專案身分的四個第二事實來源與 `.cxroot` 一致 |
| `CLI-bats` | `cx test cli` 的接線 |

未驗的兩項是 `waf-block` 與 `waf-livewire` —— 宣告的引擎是 `DetectionOnly`，
在那個狀態下這兩項沒有意義，所以誠實地 SKIP。把引擎切成 `On` 單獨驗過，兩項都通過
（見下表），而 `cx scan dast` 的主動探測每次都會涵蓋它們。

### 三條 runner 路徑

| 動詞 | `--runner docker` | `--runner native` |
|---|---|---|
| `art --version` | ✅ Laravel 13.30.1 | ✅ Laravel 13.30.1 |
| `php -v` | ✅ OPcache 8.5.10 | ✅ OPcache 8.5.4 |
| `composer --version` | ✅ | ✅ |
| `npm --version` / `npm --backend` | ✅ 11.19.0 | ✅ 11.19.0 |
| `db status` | ✅ | ✅（需 `CX_DB_HOST=127.0.0.1`，工具會主動說明） |
| `test back` | ✅ 2 passed | ✅ 2 passed |
| `test front` | ✅ | ✅ |
| `scan sca` | ✅ rc=0 | ✅ rc=0（與 docker 路徑同一份 trivy.yaml） |

### Docker 不可用時（`DOCKER_HOST=unix:///nonexistent.sock`）

| 情境 | 期望 | 實測 |
|---|---|---|
| `--runner auto` 的 art／composer／npm／scan secrets | 自動退回原生 | ✅ rc=0 |
| `--runner docker` 的同一批 | **硬失敗**，不可靜默退回 | ✅ rc=3，訊息指向 `--runner native` |
| `dev up` / `pma` / `sonar` / `scan dast` / `verify runtime` | 可行動的錯誤 | ✅ rc=3 |
| `doctor` / `verify cli docs tui` / `lint sh` / `git status` / `acl check` | 照常可用 | ✅ |

### 四道防線（`cx scan all`）

| 防線 | 結果 |
|---|---|
| ① Quality — Larastan | ✅ 乾淨 |
| ① Quality — SonarQube scanner | ⬜ 略過（本機沒有 `SONAR_TOKEN`；伺服器本身是 UP 的） |
| ② SAST — Semgrep | ✅ 無 ERROR 等級 finding |
| ③ SCA — Trivy / composer audit / npm audit | ✅ 全部乾淨（docker 與 native 兩條路都 rc=0） |
| ④ DAST — ZAP baseline ×2 | ✅ 無 High risk alert（兩輪真的分別在 DetectionOnly 與 On 之下跑） |
| ④ DAST — 主動探測 | ✅ 攻擊 6/6 全擋（100%）、正常請求 **0 誤擋**（含 Livewire POST） |
| 祕密掃描 — gitleaks | ✅ 三個 repo 全歷史乾淨，檔名 `gitleaks-{pm,backend,frontend}.json` |

引擎在探測後**自動還原**成 `docker/env/test.env` 宣告的 `DetectionOnly`（實測確認）。

### WAF（引擎切成 `On` 單獨驗）

| 請求 | 經 WAF 18081 | 直連 edge 18080 |
|---|---|---|
| 查詢字串的 XSS（真攻擊） | **403** | 200 |
| Livewire POST 含 `<script>` + `UNION SELECT` | **419** | 419 |

419 = CSRF token 不符，代表請求**到得了 Laravel**。修正前是 403 vs 419 ——
也就是 Filament 後台在 WAF 開啟時整個不能用。

### `cx acl`（facl）

| 項目 | 結果 |
|---|---|
| `apply` → `check` | ✅ ACL 模型完整 |
| host 建立的新檔案 | ✅ 繼承 `user:1000:rwx`、`other::---` |
| **容器內以 root 建立的新檔案** | ✅ 同樣繼承 —— 這正是 ACL 要解決的那個問題 |
| `user add` / `user rm <其他帳號>` | ✅ 可逆 |
| `user rm <web/dev 身分>` | ✅ 被擋（rc=2）並指出兩條正路 |

### Ansible

| 項目 | 結果 |
|---|---|
| `deploy syntax` | ✅ 三個 playbook |
| `deploy lint` | ✅ 0 finding／182 檔 |
| `deploy ping staging` | ✅ pong |
| `deploy apply staging --tags nginx` | ✅ ok=97 changed=5 **failed=0** |
| 目標機上渲染出來的 `php_regex` | ✅ 含 `livewire(-[0-9a-zA-Z]+)?` |

> 部署前目標機上那一份（2026-09-05 早上用舊模板部署、當時 failed=0）是
> `^/(api\|admin\|livewire\|…)(/\|$)` —— 比對不到 `/livewire-<hash>/update`。
> 也就是說那次「成功」的部署，Filament 後台其實是壞的。這是 N2 的直接證據。

### `cx fresh`

在 scratchpad 的拋棄式副本上（不動真的專案）：

| 項目 | 結果 |
|---|---|
| `fresh --mode carryover` | ✅ exit=0 |
| 重建的後端 | Laravel ^13.17 + Filament ^5.0 + Larastan ^3.0 |
| 重建的前端 | Nuxt ^4.5.2 + Vue ^3.5.42 |
| carryover 疊回使用者程式碼 | ✅ 存活 |
| 三個 Git 初始化 | ✅ 各自 main、各 1 commit、`.gitmodules` 用相對 URL |
| `fresh --rollback` | ✅ exit=0（兩次），HEAD 與 commit 數都與 MANIFEST 一致 |

### 7.1 TUI

TUI 需要 TTY，非互動環境會回 `EX_PRECOND` 並印出可行動訊息（這一點是自動驗的）。
選單結構的正確性由 `cx verify tui` 自動驗：

* `TUI-resolve` —— 每個選單項目送出的參數都解析得到真的存在的動詞與子指令
* `TUI-coverage` —— 每個動詞都到得了選單，除了刻意只走命令列的那幾個

真的用 whiptail 走一遍仍然需要人：那是在驗「畫面畫得出來、按鍵回得了上一層」。

---

## 8. 已知的缺口與理由

| 項目 | 為什麼還沒做 |
|---|---|
| 沒有 CI | `docs/devsecops.md` 有一份 11 步的 pipeline 配方，但沒有 `.github/`。配方本身可以逐條手動跑完當成整合測試 |
| 部署的不是被測過的產物 | `cx deploy` 從 git 遠端 clone，而通過 DAST 的是 test 模式的映像。要接起來需要 artifact registry，目前刻意不做 —— 但這個落差要寫出來 |
| `cx test coverage` / `cx scan dast` 只有容器路徑 | 前者需要容器內的 xdebug、後者需要 Java runtime。兩者都硬失敗並附理由，不靜默降級 |
| 業務邏輯 | backend 是骨架（1 個 model、0 個 Filament Resource），frontend 是 1 頁。這是範本專案，不是產品 |
