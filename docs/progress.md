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
| `setup` | ✅ | env / dirs / guard / tools / deps |
| `doctor` | ✅ | 含 Phase 2 產出物與動詞完整性檢查 |
| `dev` `prod` `up` `down` `restart` `ps` `logs` `sh` `build` `config` `dc` | ✅ | 全部經 `cx_compose_init`，四個 compose 陷阱集中處理 |
| `test`（compose 動作） | ✅ | `cx test up` 等同 `cx --mode test up` |
| `test back/front/all/coverage/larastan` | ✅ | 後端走 sqlite `:memory:`；前端的 `nuxt typecheck` 原本缺 `tsconfig.json` 與 vue-tsc/typescript/@types/node，已補齊 |
| `db` | ✅ | status / shell / wait / migrate / fresh / seed / dump / restore / admin |
| `scan` | ✅ | code / sast / sca / dast / secrets / all |
| `sonar` | ✅ | up / down / status / logs / token / url / wait |
| `verify` | ✅ | static / runtime / app / ansible / all |
| `deploy` | ✅ | syntax / lint / check / ping / facts / vars / apply / app / rollback / galaxy |
| `git` | ✅ | status / **fetch** / **pull** / sync / commit / branch / guard / remote-init / scan-secrets / push |
| `art` `composer` `npm` | ✅ | `npm --backend` 是新增的（舊 `npm-php` service 從來不存在） |
| `lint` `tui` `install` `uninstall` `help` | ✅ | |
| `fresh` | ⚠ 部分 | 備份／驗證／確認閘門／刪除都可用；**重建階段與 `--rollback` 仍未實作** |

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
| host 的 `pdo_sqlite` | ✘ 未安裝 | 只影響「在 host 上直接跑 `php artisan test`」。容器內已有，`cx test back` 不受影響 |
| SonarQube | 未啟動 | `cx scan code` 會略過 scanner 並警告 |
| 目標主機 | 無 | 整個 Phase 5 的執行期驗證 |

> `sudo usermod -aG docker $USER` 之後**必須** `wsl --shutdown`（Windows 端）再重開。
> `usermod` 只影響之後才建立的登入 session，既有的 shell 不會生效 —— 這是本專案
> 卡最久的一個環境問題。
