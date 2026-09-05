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
| xdebug | 有（`debug`） | 有（`develop`） | **無**（build 斷言） | `D12`、`rt-*` |
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
| M1 | TUI 逐頁走過 | `script -q <log> -c 'cx tui'` | 見下方 §7.1 | |
| M2 | phpMyAdmin 真的能登入並看到資料表 | 瀏覽器開 8891 / 18891 | | |
| M3 | Filament 後台實際登入並操作 | `cx db admin` → 瀏覽器 | | |
| M4 | Sanctum SPA 完整登入流程 | 需要前端有登入頁 | | |
| M5 | 真實跨源 CORS 行為 | 三個模式目前都是同源 | | |

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
