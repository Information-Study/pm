# cx 動詞參考

> 這份是逐個動詞的完整參考。流程性的說明看 [`manual.md`](manual.md)。
> **`cx help` 的輸出永遠是權威** —— 這份文件是它的展開版。

---

## 全域旗標

放在動詞**之前**。

| 旗標 | 值 | 說明 |
|---|---|---|
| `--root <path>` | 目錄 | 指定專案根目錄。不給的話向上搜尋 `.cxroot` |
| `--mode <m>` | `dev` \| `test` \| `prod` | 預設 `dev`。決定 compose project 與 overlay |
| `--ui <u>` | `whiptail` \| `dialog` \| `plain` | 預設 `auto`（有 tty 就用 whiptail） |
| `--runner <r>` | `docker` \| `native` \| `auto` | 預設 `auto`（有 Docker daemon 就用容器）。強制的那一邊不可用時**硬失敗**，不會偷偷換邊 |
| `--dry-run` | — | 只印出要執行的指令，不改變任何狀態 |
| `--yes` / `-y` | — | 略過互動確認。**非互動環境專用** |
| `-h` / `--help` | — | 等同 `cx help` |

`--mode`、`--ui`、`--runner` 三個值都會被白名單驗證（`--root` 另外驗路徑與 `.cxroot`）。
`--mode` 會被拿去組 `-p <專案>_${CX_MODE}` 與
`-f docker/compose/${CX_MODE}.yml`，不驗證等於留一個檔名／專案名注入面。
`--runner` 不驗證的話，打錯的值會落進 `auto` 分支 —— 你以為在測原生，實際上跑的是容器。
`--ui` 不驗證的話，非法值會讓 `_cx_dlg` 的 case 找不到分支而「什麼都不做並回傳 0」，
而回傳 0 在 `cx_confirm` 眼中就是「使用者按了 Yes」—— 所有刪除閘門會同時失效。

## 退出碼

| 碼 | 常數 | 意義 |
|---|---|---|
| 0 | `EX_OK` | 成功 |
| 1 | `EX_FAIL` | 一般失敗 |
| 2 | `EX_USAGE` | 用法錯誤（未知動詞、未知參數） |
| 3 | `EX_PRECOND` | 前置條件不足（沒有 Docker、缺檔、工具沒裝） |
| 4 | `EX_ABORT` | 使用者取消 |
| 20 | `EX_SCAN_QUALITY` | ① Quality 有 finding |
| 21 | `EX_SCAN_SAST` | ② SAST 有 ERROR 等級 finding |
| 22 | `EX_SCAN_SCA` | ③ SCA 有 finding |
| 23 | `EX_SCAN_DAST` | ④ DAST 有 High risk alert |

**「有 finding」與「工具當掉」是不同的事。** `cx scan` 顯式捕捉工具的退出碼並
映射到專屬的 `EX_SCAN_*`，CI 才分得出來。

---

## `cx setup` — 初始化

```
cx setup [子指令]
```

| 子指令 | 做什麼 |
|---|---|
| （無）/ `all` | env + dirs + guard + collections，最後盤點工具鏈 |
| `env` | 從 `.env.example` 產生 `.env`（隨機密碼、你的 UID/GID、`PROJECT_SLUG`）。**不覆蓋既有的** |
| `dirs` | 建立 `reports/` 與 `.cx/` 的葉目錄，並補回 `reports/.gitignore` |
| `guard` | 安裝三個 repo 的 pre-push hook（白名單從 `.cxroot` 產生） |
| **`native`** | **一行裝完整套原生工具鏈** = `system` → `tools` → `deps`。不吃名稱過濾器 —— `system` 與 `tools` 的清單互斥，要裝單一項目請直接用那兩個子指令 |
| `system [名稱...]` | **需要 root** 的系統套件：`php nginx git docker mysql-client php-sqlite` |
| `tools [名稱...]` | 免 root 安裝工具鏈。可選 `composer node ansible trivy gitleaks semgrep` |
| `deps` | backend 的 `composer install` + `npm ci` + `vite build`、frontend 的 `npm ci` |

### 哪個工具在哪一邊

| | 工具 | 裝到哪 |
|---|---|---|
| `system`（要 root） | `php`（cli + 8 個擴充）・`nginx`・`git`・`docker`（含 compose v2）・`mysql-client`・`php-sqlite` | 系統 |
| `tools`（免 root） | `composer`・`node`（含 `npm` / `npx`）・`ansible`（含 `ansible-lint` / `yamllint`）・`trivy`・`gitleaks`・`semgrep` | `~/.local` |
| 不必安裝 | `artisan` —— 它是 `backend/artisan`，隨 Laravel 一起來 | — |

打錯邊不會只丟一句「未知的工具」，會直接告訴你正確的指令：

```
$ cx setup system npm
✘ 未知的系統工具：npm（可用：php nginx git docker mysql-client php-sqlite）
    npm 隨 node 一起裝 → cx setup tools node
```

`cx setup native` 的順序是固定的：`system` 必須先跑，因為 composer 的安裝器需要 `php`。
`system` 因為缺 sudo 而只印出指令時（回傳 3），`native` 會**繼續**跑 `tools` ——
免 root 的那一半仍然裝得起來，沒有理由整個停掉。

**為什麼目錄要由你建立**：掛在「image 中不存在的路徑」上的具名 volume 一律被
Docker 建成 `root:root 0755`，之後以 uid 1000 執行的 Trivy / Semgrep / PHPStan / ZAP
全部 EACCES。

**密碼的字元集刻意限制在 `A-Za-z0-9`**：base64 會產生 `/` 與 `+`，而 `&` 是 sed 的
整段回填 —— 只要有任何一段流程用 sed 套密碼，密碼就會被靜默竄改，
一小時後才以 `Access denied` 現形。

冪等：跑第二次不會覆蓋 `.env`，也不會重裝已經對版的工具。

---

## `cx code` — 用 VS Code 開啟

```
cx code [路徑] [VS Code 參數...]
```

不給路徑就開**專案根**，不是你所在的子目錄 —— 這正是它存在的理由：
從 `backend/` 打 `code .` 開的是 `backend/`，而你多半想要整個工作區。

給了路徑則以**呼叫者的 cwd** 解析（`cd backend && cx code .` 開 `backend/`）。

執行檔依序找 `$CX_CODE_BIN` → `code` → `code-insiders` → `codium`。
都找不到時會告訴你 WSL 要裝哪個擴充，而不是丟 `command not found`。

---

## `cx pma` — 開啟 phpMyAdmin

```
cx pma            # 印出網址、帳號，並嘗試用瀏覽器開啟
cx pma --url      # 只印網址（給腳本用）
cx pma --no-open  # 印資訊但不開瀏覽器
```

**只有 dev 模式有。** test / prod 刻意不放管理介面（額外的攻擊面，
而且 prod 的 MySQL 根本不發布埠）。在別的模式打會被擋下並告訴你用
`cx --mode <m> db shell`。

埠是從**合併後**的 compose 設定讀出來的，不是寫死 8891 ——
`docker/env/dev.env` 可以覆寫，寫死就會給出錯的網址。

容器沒在跑時會告訴你怎麼起，而不是給一個開不起來的連結。

> 密碼不會印在終端機上（scrollback 與 tmux buffer 會留著），
> 只印出長度與「去哪裡看」。

---

## `cx php` — 直接跑 php

```
cx php -v
cx php -m
cx php -r 'echo PHP_VERSION;'
```

`cx art` 只涵蓋 artisan；很多時候要問的是 php 本身。
兩條 runner 都支援，而且會印出跑的是哪一個：

```
$ cx --runner docker php -r 'echo PHP_VERSION;'
runner: docker（指定） — 容器內的 php
8.5.10
$ cx --runner native php -r 'echo PHP_VERSION;'
runner: native（指定） — php 8.5.4
8.5.4
```

版本不同是正常的：容器裡是映像釘住的版本，原生是系統套件的版本。


### `cx setup system` 對 root 的態度

那六個是系統套件，一定要 root。cx 的原則是：

1. **絕不偷偷跑 sudo。** 要用 root 就明講，而且有確認閘門（會先列出
   完整的 `apt-get install` 指令再問你）。
2. **sudo 不可用時不算失敗** —— 把「你該自己貼哪一行」印出來就好。
   在 CI 或不給 sudo 的機器上，那才是正常流程。
3. **裝完要驗**，不能只看 apt 的退出碼。套件裝了不代表你要的東西就在
   （最典型的是 php 擴充：套件裝了但 .ini 沒啟用）。

已經有的工具會被略過，所以重跑是安靜的（冪等）。
判斷「有沒有」看的是實際的執行檔／擴充，不是套件資料庫 ——
使用者可能是用 PPA、手動、或 Docker Desktop 的 WSL integration 裝的。

---

## `cx doctor` — 診斷

```
cx doctor
```

不接參數。逐項檢查並回報 `通過 / 警告 / 失敗`。有任何失敗就回 `EX_PRECOND`。

檢查項目：專案標記、Docker daemon 與 compose、PHP 與必要／選用擴充、composer、
Larastan、node/npm 與版本相容性、frontend 相依、Trivy/gitleaks/Semgrep/ZAP、
ansible/ansible-lint、whiptail/gh、push guard（三個 repo）、
**可執行位元**（磁碟與 git index 都檢查）、Phase 2 產出物、動詞實作檔完整性。

> 可執行位元那一項不是多餘的：git index 曾經把 `cx` 的模式記成 `100644`
> 而磁碟是 755 —— 內容零差異、`git diff` 看不出來，但任何人 clone 下來
> 打 `./cx` 都是 `Permission denied`，單一入口在第 0 步就壞了。

---

## `cx dev` / `cx test` / `cx prod` / `cx up|down|…` — 容器操作

```
cx <模式> <動作> [參數...]
cx <動作> [參數...]          # 用 --mode 指定，預設 dev
```

動作：`up` `down` `restart` `ps` `logs` `sh` `build` `config` `dc`

這九個動作**也可以不帶模式直接當成頂層動詞**（`cx ps`、`cx config`、`cx logs -f`…），
沿用 `--mode`，預設 `dev`。它們靠 `cx` 的 `CX_CMD_FILE_OF` 對照表指到 `compose.sh`；
漏掉任何一筆的症狀是「`cx dev config` 好好的，但裸的 `cx config` 說未知的指令」。
`cx doctor` 的「動詞完整性」現在會檢查這張表。

| 動作 | 說明 |
|---|---|
| `up [-d] [--build]` | 啟動前會先建立 reports/ 葉目錄，並**斷言每個 bind mount 來源都存在** |
| `down [-v]` | `-v` 會刪掉所有 volume（含資料庫），**要求確認** |
| `restart [服務...]` | |
| `ps` | 容器與埠 |
| `logs [-f] [服務...]` | 沒給 `--tail` 時預設 `--tail=200` |
| `sh [服務]` | 預設 `app`。用 `sh` 不是 `bash` —— 映像是 Alpine |
| `build [--no-cache]` | 只建置不啟動 |
| `config` | 印出**合併後**的 compose 設定（除錯合併鏈用） |
| `dc <原生參數...>` | 逃生門，參數原樣交給 `docker compose` |

**為什麼要斷言 bind mount 來源**：來源不存在時 Docker 不會報錯，
它會靜默建立一個 `root:root 0755` 的空目錄再掛上去。於是 CRS 排除規則從未載入、
WAF 悄悄失效，而且沒有任何線索。

`cx test` 同時是「test 模式的 compose」與「跑測試套件」。
第一個參數落在動作白名單裡就走 compose，否則走測試 —— 兩組沒有交集，不會有歧義。

---

## `cx test` — 測試套件

```
cx test <back|front|all|coverage|larastan>
```

| 子指令 | 做什麼 | 需要什麼 |
|---|---|---|
| `back` | `php artisan test` | 不需要 MySQL（走 sqlite `:memory:`） |
| `front` | `nuxt typecheck` | frontend 的 node_modules |
| `all` | 兩者 | |
| `coverage` | 後端覆蓋率，報告搬到 `reports/quality/` | 臨時打開 `XDEBUG_MODE=coverage` |
| `larastan` | 等同 `cx scan code` 的第一段 | |

容器路徑會傳六個 `-e`（`DB_CONNECTION` `DB_DATABASE` `APP_ENV`
`CACHE_STORE` `SESSION_DRIVER` `QUEUE_CONNECTION`），來源是
`bin/cmd/test.sh` 的 `_test_env_pairs`，原生路徑讀同一份。

⚠ 這些 `-e` 不是「第二道保險」，是**唯一**一道。
`phpunit.xml` 的 `force="true"` 在容器裡無效 —— PHPUnit 的 force 只寫
`putenv()` 與 `$_ENV`，不寫 `$_SERVER`，而 Laravel 的 `Env` 讀 `$_SERVER`
優先，compose 的 `environment:` 永遠贏。**在容器裡裸跑 `php artisan test`
會打到真正的開發資料庫。** 詳見 claude.md §0 紅線 5。

容器路徑以 `-u $(id -u):$(id -g)` 執行，這樣 phpunit 在 bind mount 的
`backend/` 裡寫出來的 `.phpunit.result.cache` 才屬於你，
不會讓 `--runner native` 之後噴 `Permission denied`。

`cx test coverage` 在測試失敗時**回傳測試的退出碼**，報告照樣產生
（測試失敗的時候 junit 報告才是最有用的）。

---

## `cx db` — 資料庫

```
cx db <子指令> [參數...]        # 作用於 --mode，預設 dev
```

| 子指令 | 說明 | 閘門 |
|---|---|---|
| `status` | 連線資訊、資料表清單、migration 狀態 | |
| `shell [SQL]` | 進 mysql client；給了 SQL 就執行後結束 | |
| `wait` | 等 MySQL 就緒（CI 用） | |
| `migrate` | `artisan migrate --force` | |
| `seed` | `artisan db:seed --force` | |
| `fresh` | ⚠ `migrate:fresh --seed`，清空所有資料表 | 互動確認 |
| `dump [檔案]` | `mysqldump` → `reports/db/<mode>-<時間>.sql.gz`，並 `gzip -t` 驗證 | |
| `restore <檔案>` | ⚠ 從 dump 還原，會覆蓋現有資料 | 確認 + **輸入 `RESTORE <mode>`** |
| `admin` | `artisan make:filament-user` | |

**client 一律在 mysql 容器裡執行**，不是 app 容器。app 是 Alpine，
`apk add mysql-client` 裝到的其實是 **MariaDB client**，它預設會驗證伺服器憑證，
對上 MySQL 8.4 的自簽憑證每次都是
`ERROR 2026 (HY000): TLS/SSL error: self-signed certificate in certificate chain`
—— 訊息看起來像 TLS 壞了，其實只是用錯 client。

密碼從不經過 host 的行程列表：指令用 `sh -c '… -p"$MYSQL_ROOT_PASSWORD" …'`，
只在容器內展開。

---

## `cx art` / `cx composer` / `cx npm` — 工具包裝

```
cx art <artisan 參數...>
cx composer <composer 參數...>
cx npm [--backend] <npm 參數...>
```

三者都是「有 Docker 走容器、沒有就用本機」。`cx_dim` 會印出 `runner: docker`
或 `runner: native`，執行前先看那一行。

| | 容器 | 本機 fallback |
|---|---|---|
| `cx art` | `run --rm --entrypoint php app artisan` | `env -C backend php artisan` |
| `cx composer` | `run --rm --no-deps --entrypoint composer app` | `env -C backend composer` |
| `cx npm` | compose 的 `nuxt` service | `env -C frontend npm` |
| `cx npm --backend` | `node:24.20-bookworm-slim` 一次性容器 | `env -C backend npm`（**優先**） |

`cx composer` 會主動拒絕任何 `--ignore-platform-req*` 參數：
```
✘ 拒絕 --ignore-platform-reqs —— 正確診斷是 composer why-not <套件> <版本>
```

### `cx npm --backend` 為什麼是特例

backend 也有自己的 `package.json`（Vite + Tailwind，建置 Laravel 端的
`public/build/`）。舊版的 `init.sh` 呼叫一個叫 `npm-php` 的 service 來做這件事，
**但那個 service 從來沒有存在過** —— 所以後端資產在舊專案裡從來沒被建置過。
`welcome.blade.php` 有 `@vite(...)`，缺 `public/build/manifest.json` 時直接
`ViteManifestNotFoundException`。

它**不能**用 `app` service：`app` 是 `php:8.5-fpm-alpine`，裡面沒有 node，
實測是 `exec: "npm": executable file not found in $PATH`。

它也**不能**用 Alpine 的 node 映像：`backend/node_modules` 是掛在 host 上的
真實目錄，原生模組（Vite 8 的 rolldown binding）照安裝當下的 libc 編。
host 是 Ubuntu（glibc），掛進 Alpine（musl）會是
```
Error: Cannot find native binding
Cannot find module '@rolldown/binding-linux-x64-musl'
```
訊息指向 npm 的 optional dependencies bug，其實只是 libc 不匹配。
所以 fallback 映像刻意選 `bookworm-slim`（glibc），兩條路產生的
`node_modules` 可以互通。

---

## `cx scan` — 四道防線

```
cx scan <code|sast|sca|dast|secrets|all> [--runner docker|native|auto]
```

| 子指令 | 防線 | 工具 | 失敗退出碼 |
|---|---|---|---|
| `code` | ① Quality | Larastan (level 5) + SonarQube scanner | 20 |
| `sast` | ② SAST | Semgrep | 21 |
| `sca` | ③ SCA | Trivy + `composer audit` + `npm audit` | 22 |
| `dast` | ④ DAST | OWASP ZAP baseline | 23 |
| `secrets` | — | gitleaks（全歷史） | 22（與 ③ 共用） |
| `all` | ①②③④ + secrets | **全部跑完**，不在第一個 finding 停 | 五道之中最嚴重的那個 |

報告輸出到 `reports/{quality,sast,sca,secrets,dast}/`。
各檔案的實際名稱與讀法見 [`reports.md`](reports.md)。

**`--runner`**：`docker` 用容器、`native` 用 `~/.local` 的二進位、`auto`（預設）
**有 Docker daemon 就走容器**，沒有才走原生。ZAP 只有 docker 一條路（要 Java）。
`cx scan` 另外接受自己的 `--runner`，位置較近者優先。

### SAST 的嚴重度閘門

**不使用 `semgrep --error`。** 那個旗標的語意是「只要有任何 finding 就回傳非零」，
於是 INFO 等級的風格建議跟 SQL injection 有同樣的效果 —— 閘門一定會被關掉，
關掉之後就再也沒有閘門。

改成永遠產出 SARIF，再由 `bin/lib/sarif_gate.py` 依 `level` 分級：
只有 `error` 會讓 `cx scan sast` 回傳 `EX_SCAN_SAST`，`warning` 與 `note` 印出來但放行。

`.semgrepignore` **必須在專案根目錄** —— Semgrep 只在「掃描目標的根目錄」找它，
放在 `docker/security/` 底下完全不會被讀到。

### DAST 的退出碼映射

ZAP baseline 的退出碼不是「0 成功 / 非 0 失敗」：

| ZAP rc | 意義 | cx 的處置 |
|---|---|---|
| 0 | 沒有任何 alert | 通過 |
| 1 | 至少一個 FAIL | `EX_SCAN_DAST` |
| 2 | 只有 WARN | **通過**（並印出警告數） |
| ≥3 | 工具本身出錯（目標連不上、設定壞掉） | `EX_FAIL`，不是掃描失敗 |

把 2 當失敗會讓每一次掃描都紅，把 ≥3 當成功則會讓「ZAP 根本沒跑起來」
被記成「沒有漏洞」。

`_scan_dast_probe` 是**兩輪掃描之後**才跑的 WAF 攻擊探針（用真的 payload 量
攔截率與誤擋率，結果寫進 `reports/dast/compare/waf-probe.json`），
**不是**掃描前的可達性檢查 —— 目前沒有前置可達性檢查，所以
「ZAP 很快就跑完而且零 alert」仍然可能是目標根本沒起來。
判斷方法是看 `reports/dast/*/report.json` 裡有沒有實際掃到 URL。

ZAP 跑兩次：`DetectionOnly` 與 `On`，用來對照 WAF 到底擋掉了什麼。

`baseline.conf` 掛在 `/zap/pmconf/` 而不是 `/zap/wrk/` —— `/zap/wrk/` 是輸出目錄，
ZAP 會往裡面寫，把唯讀設定放進去會在某些版本被覆寫。

### SonarQube token

從 `.cx/sonar-token` 讀。**不用 `${SONAR_TOKEN:?}`** —— 在 `set -u` 之下，
`:?` 會直接讓整個 shell 結束，連「SonarQube 未設定，略過」這行訊息都印不出來。
沒有 token 就跳過 Sonar 那一段，Larastan 照跑。

---

## `cx sonar` — 常駐 SonarQube

```
cx sonar <up|down|status|token|url|logs|wait>
```

獨立的 compose project（`<專案>_devsecops`，本專案是 `pm_devsecops`），
跟三個模式互不相干。名字跟著 `.cxroot` 的 `CX_PROJECT_NAME` 走。
`cx sonar token` 引導產生 token 並存到 `.cx/sonar-token`（mode 0600）。

---

## `cx verify` — 驗收

```
cx verify [範圍...] [--report <檔案>] [--quiet]
```

| 範圍 | 內容 | 需要容器 |
|---|---|---|
| `static` | compose 合併結果、Dockerfile、版本鎖定 | 否 |
| `runtime` | supervisord、vendor、端點、資料庫 | **是**（先 `cx dev up -d`） |
| `ansible` | syntax-check + ansible-lint + yamllint | 否 |
| `app` | `/up`、`/admin`、`/sanctum`、前端 | 是 |
| `all` | 全部，會依序把三個模式都起起來 | 很慢 |

省略範圍 = `static app ansible`。
報告預設寫到 `reports/verify/<時間戳>.md`。

---

## `cx deploy` — Ansible

```
cx deploy <子指令> [限制]
```

| 子指令 | 對應 | 危險度 |
|---|---|---|
| `galaxy` | `ansible-galaxy install -r requirements.yml` | |
| `syntax` | `--syntax-check`（三個 playbook） | |
| `lint` | `ansible-lint`（production profile）+ `yamllint` | |
| `ping` | 確認 SSH 與 become | |
| `check [限制]` | `--check --diff` 乾跑 | |
| `apply [限制]` | ⚠ **真的部署** | 列出目標主機並要求確認 |
| `app [限制]` | 只跑應用層（`playbooks/deploy-only.yml`） | 同上 |
| `rollback` | 互動式回滾 | 同上 |

`[限制]` 會變成 `--limit`。

---

## `cx git` — 版本控制

```
cx git <子指令> [參數...]
```

| 子指令 | 說明 |
|---|---|
| `status` | 三個 repo 的分支 / 變更 / 上游 / 領先落後 |
| `fetch` | 三個 repo 一起 `fetch --prune`（唯讀，不動工作區） |
| `pull [--allow-merge]` | 三個 repo 一起更新（主庫先、子模組後，預設只允許快轉） |
| `sync` | 子模組 checkout 到追蹤分支 |
| `commit [-m 訊息]` | 子模組先、主庫 gitlink 後 |
| `branch list\|new\|switch\|delete <名稱>` | 三個 repo 同步操作 |
| `remote-init` | 用 `gh` 建立 Information-Study 的三個 public repo |
| `push [--force]` | 推送 |
| `scan-secrets` | 祕密掃描（commit / push 前會自動跑） |
| `guard install\|status\|remove` | pre-push hook |

### `status` 的數字不連線

`status` 讀的是 **remote-tracking ref**（`refs/remotes/origin/<分支>`），不問遠端。
所以「領先 0 ・ 落後 0」的意思是「跟你上次 fetch 到的內容一致」，
不是「跟 GitHub 上現在的內容一致」。

因此每一行都會附上**上次 fetch 的時間**（讀 `FETCH_HEAD` 的 mtime）：

```
pm
  branch : main
  head   : 0fd7188
  dirty  : 0 項
  origin : git@github.com:Information-Study/pm.git
  vs origin: 同步（上次 fetch：09-04 11:46）
```

沒有 remote-tracking ref 時會明講「先跑 cx git fetch」，而不是印 0/0。

### `fetch` 與 `pull` 的順序**相反**

| | 順序 | 為什麼 |
|---|---|---|
| `push` | 子模組 → 主庫 | 主庫的 gitlink 指向子模組的 commit，那個 commit 必須先存在於子模組的遠端 |
| `pull` | 主庫 → 子模組 | 主庫的 gitlink 才是「這一版該用哪個子模組 commit」的唯一真相 |

反過來做 `pull` 的話，子模組會被拉到**它自己分支的尖端**，而那不一定是主庫這一版
記錄的 commit —— 於是 pull 完 `git status` 立刻顯示子模組「有未提交的變更」，
但你其實只是把子模組拉到了別的版本。

`cx git pull` 的完整流程：

1. **三個 repo 任一髒就中止**（`EX_PRECOND`）。
   失敗會發生在「一半」的位置：主庫已快轉、子模組還沒動，而 merge 又被
   local changes 擋下。那個狀態很難描述、更難復原。
2. `fetch --prune`（黑名單遠端硬擋）
3. 主庫 `merge --ff-only origin/<分支>`
4. `git submodule update --init --recursive` —— 子模組移到 gitlink
5. `cx git sync` —— 把子模組從 detached HEAD 接回追蹤分支（用 `checkout -B`，不丟 commit）
6. 若子模組的 `origin/<分支>` 比 gitlink 新，**警告但不自動採用**

### 分岔時不自動合併

本地與遠端都各有新 commit 時，`pull` 直接停下來：

```
✘ 主庫已分岔：本地領先 2、落後 3
  想看差異： git -C /home/user/pm log --oneline --left-right main...origin/main
  確定要合併： cx git pull --allow-merge
  想丟掉本地： git -C /home/user/pm reset --hard origin/main（不可逆）
```

理由是主庫的**每一個 commit 都帶著子模組的 gitlink**。自動合併很可能產生一個
「backend 用 A 版、frontend 用 B 版」的組合 —— 那個組合從來沒有人測過，
而且 `git status` 看起來完全正常。

### `cx git push` 的閘門順序

1. **遠端白名單**。唯一合法的是
   `github.com/Information-Study/{pm,pm-backend,pm-frontend}`。
   `team-of-P/*` 永久禁止，**沒有任何旗標可以覆寫**。
2. **祕密掃描**。兩層：檔名層（`.env`、`*.pem`、`id_rsa`…）與內容層
   （AWS key、私鑰 PEM header、`APP_KEY=base64:`…）。
   內容層對每個 repo 都會先 `cd` 進去再掃 —— 早期版本沒有 `cd`，
   於是兩個子模組實際上掃了零個檔案。
3. **順序**。子模組先推、主庫後推。反過來的話主庫的 gitlink 會指向
   遠端不存在的 commit，別人 clone 下來 `submodule update` 直接失敗。
   任何子模組推失敗就中止，不會繼續推主庫。
4. **推完驗證 gitlink**。用 `git ls-remote` 確認主庫記錄的每個 gitlink
   在對應的遠端真的存在。
5. `--force` 需要**輸入 `REWRITE HISTORY`** 才會繼續。

detached HEAD 之下會先 `git checkout -q -B <追蹤分支> HEAD` 再推
（子模組在 `submodule update` 之後預設就是 detached）。

> `cx git sync` 用 `checkout -q -B "$b" "$head"` 而不是 `checkout -q "$b"`。
> 後者在「本地分支落後 gitlink」時會靜默把工作區切到舊的 commit，
> 看起來成功，實際上剛剛的提交不見了。

---

---

## `cx git` 的驗證紀錄（2026-09-04）

每一條都是對**真實遠端**（`github.com/Information-Study/*`）實跑的，
不是 `--dry-run`。

### 退出碼

| 指令 | rc | 期望 |
|---|---|---|
| `cx git status` | 0 | ✔ |
| `cx git fetch` | 0 | ✔ |
| `cx git fetch --oops` | 2 | ✔ `EX_USAGE` |
| `cx git pull --rebase` | 2 | ✔ `EX_USAGE`（只支援 `--ff-only` / `--allow-merge`） |
| `cx git pull`（工作區髒） | 3 | ✔ `EX_PRECOND` |
| `cx git sync` | 0 | ✔ |
| `cx git branch list` | 0 | ✔ |
| `cx git bogus` | 2 | ✔ `EX_USAGE` |
| `cx git guard status` | 0 | ✔ |
| `cx git scan-secrets` | 0 | ✔ |

### `pull` 的四條路徑

| 情境 | 結果 |
|---|---|
| 落後 1（本地 rewind 一個 commit） | 快轉到 `origin/main`，子模組對齊 gitlink 並接回 `main`，檔案內容確實回來（`docs/manual.md` 525 行） |
| 已是最新 | `✔ 主庫已是最新（領先 0）`，rc=0 |
| 分岔（領先 1、落後 1） | rc=3，列出三條路：看差異 / `--allow-merge` / `reset --hard` |
| 子模組遠端比 gitlink 新 | **警告但不自動採用**，rc=0，`backend` 的 HEAD 仍停在 gitlink |

最後一條是用一個臨時的本地 bare remote 測的 —— 一開始想用
`git update-ref` 直接偽造 `refs/remotes/origin/main`，但 `pull` 內部的
`fetch --prune` 會把它改回真值，警告因此不會觸發。
**這代表那個 fetch 是有效的**，偽造的 ref 騙不過它。

### 紅線：黑名單遠端

把 `backend` 的 origin 暫時改成 `team-of-P/PSYOP_DutyManager.git`：

| 指令 | rc | 訊息 |
|---|---|---|
| `cx git fetch` | 3 | `origin 在永久黑名單，拒絕連線` |
| `cx git pull` | 3 | 同上 |
| `cx git push` | 3 | `origin 在永久黑名單` |

三個入口都在**任何網路動作之前**擋下。
`fetch` / `pull` 也要擋的理由：拉下來就等於把舊專案的內容帶進工作區。

不在白名單但也不在黑名單的遠端（例如本地路徑）只警告、不阻擋 ——
唯讀操作允許刻意加的 upstream / fork。

### `branch` 的完整生命週期

`new` → `switch main` → `list` → `delete` → 拒絕刪除 `main`(rc=2)，
三個 repo 全程同進同出，結束後工作區乾淨、測試分支已清除。

### 從子目錄執行

`backend/`、`frontend/`、`ansible/roles/mysql/tasks/`、`bin/lib/`、`docs/`
五個位置各跑 `status` / `fetch` / `pull`，全部 rc=0。

---

## `cx fresh` — 清理與重建

```
cx fresh [--phase preflight|backup|migrate|delete|all] [--mode backup-only|carryover|scaffold]
```

流程：**備份 → 驗證備份 → 確認閘門 → 刪除 → 重建**。

`_fresh_nuke` 的護欄（任何一條不成立就中止，不是跳過）：
- 拒絕 symlink（避免被指到樹外）
- 路徑必須**嚴格**位於 `CX_ROOT` 之下
- 拒絕 `CX_ROOT` 本身、`$HOME`、`/`
- 不可以 root 執行

備份驗證不是「檔案存在就算數」：從 MANIFEST 推導出**預期產物清單**逐一比對，
每個 tar 都 `tar -tzf` 過一遍，每個 git bundle 都**真的解一次**
（`git init --bare` + `fetch`）—— `git bundle verify` 只讀 header，
一個被截斷的 bundle 它照樣說 OK。

尚未實作：`--rollback`、`--mode carryover|scaffold` 的重建階段（見 `claude.md` §12）。

---

## `cx install` / `cx uninstall`

```
cx install [--rc]
cx uninstall [--rc]
```

`install` 建立 `~/.local/bin/cx` symlink 並註冊 bash 補全。
`--rc` 會動 `~/.bashrc`。

`--dry-run` 之下**不會**碰 `~/.bashrc`。這不是小事：
`{ ...; } >> "$rc"` 的重導向在指令執行**之前**就先建立，
所以 `cx_run` 印出 `[dry-run]` 而不執行時，重導向已經生效了 ——
早期版本的 `--dry-run` 會真的截斷使用者的 `~/.bashrc`。
現在真實路徑也是先寫暫存檔再 `cp`。

---

## `cx lint`

```
cx lint [目錄]
```

沒裝 `ansible-lint` 時的替代品，用 `bin/lib/ansible_lint.py`。
會排除 `collections/`、`.cache/`、`.ansible/`、`.git/`、`__pycache__/`
—— 不排除的話它會去檢查上游 collection 的原始碼，回報 803 個跟本專案無關的 finding。

---

## `cx tui`

不給動詞時的預設。whiptail 選單，把上面所有動詞包成互動式。
沒有 tty 時自動退回 `plain`。

---

## 從子目錄執行

`cx` 向上搜尋 `.cxroot`，所以 `backend/`、`ansible/roles/mysql/` 底下
都可以直接跑：

```bash
cd backend && ../cx doctor          # 或者 cx install 之後直接 cx doctor
cd ansible/roles/mysql && cx deploy syntax
```

搜尋順序是「呼叫者的 cwd 往上」→ 找不到才退回「`cx` 自身所在目錄往上」。
`CX_INVOKE_PWD` 在任何 `cd` 之前就記下來，`cx_resolve` 用它把相對路徑
（例如 `cx verify --report out.md`）解析成呼叫者所在位置的路徑，
而不是專案根目錄的路徑。
