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
| 3 | `EX_PRECOND` | 前置條件不足（沒有 Docker、缺檔、工具沒裝、**沒有 TTY 卻執行 `cx tui`**） |
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
| （無）/ `all` | env + dirs + collections，最後盤點工具鏈。**不含 guard** —— push guard 是選用的，2026-09-04 起 `cx setup` 只會提示它存在 |
| `env` | 從 `.env.example` 產生 `.env`（隨機密碼、你的 UID/GID、`PROJECT_SLUG`）。**不覆蓋既有的** |
| `dirs` | 建立 `reports/` 與 `.cx/` 的葉目錄，並補回 `reports/.gitignore` |
| `guard` | 安裝三個 repo 的 pre-push hook（白名單從 `.cxroot` 產生）。**選用** —— `cx setup` 不含這一步 |
| **`native`** | **一行裝完整套原生工具鏈** = `system` → `tools` → `deps`。不吃名稱過濾器 —— `system` 與 `tools` 的清單互斥，要裝單一項目請直接用那兩個子指令 |
| `system [名稱...]` | **需要 root** 的系統套件：`php nginx git docker mysql-client php-sqlite acl jq` |
| `tools [名稱...]` | 免 root 安裝工具鏈。可選 `composer node ansible trivy gitleaks semgrep shellcheck bats` |
| `deps` | backend 的 `composer install` + `npm ci` + `vite build`、frontend 的 `npm ci` |

### 哪個工具在哪一邊

| | 工具 | 裝到哪 |
|---|---|---|
| `system`（要 root） | `php`（cli + 8 個擴充）・`nginx`・`git`・`docker`（含 compose v2）・`mysql-client`・`php-sqlite`・`acl`・`jq` | 系統 |
| `tools`（免 root） | `composer`・`node`（含 `npm` / `npx`）・`ansible`（含 `ansible-lint` / `yamllint`）・`trivy`・`gitleaks`・`semgrep`・`shellcheck`・`bats` | `~/.local` |
| 不必安裝 | `artisan` —— 它是 `backend/artisan`，隨 Laravel 一起來 | — |

打錯邊不會只丟一句「未知的工具」，會直接告訴你正確的指令：

```
$ cx setup system npm
✘ 未知的系統工具：npm（可用：php nginx git docker mysql-client php-sqlite acl jq）
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

**dev 與 test 兩個模式有；prod 刻意沒有。** prod 不放管理介面（額外的攻擊面，
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

那八個是系統套件，一定要 root。cx 的原則是：

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
ansible/ansible-lint、whiptail/gh、push guard（選用：0/3 與 3/3 都算通過，1-2/3 警告狀態不一致）、
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
cx test <cli|back|front|all|coverage|larastan>
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

## `cx acl` — 檔案權限（POSIX ACL）

```
cx acl <子指令> [參數...]
```

| 子指令 | 說明 |
|---|---|
| `check` | 唯讀驗證，`cx doctor` 也會看這一項 |
| `apply [backend\|frontend]` | 套用權限模型；不給就兩邊都套 |
| `user add <帳號> [--ro]` | 讓另一個開發者能改原始碼 |
| `user rm <帳號>` | 收回 |
| `status [路徑...]` | 看目前的 ACL |
| `fix-owner` | 把不屬於你的檔案要回來（列出並確認；需要 sudo） |
| `drop [路徑...]` | 清空 ACL，回到純 chmod（有確認閘門） |

旗標：`--web-user`、`--dev-user`（名稱或 uid）。
乾跑用**全域**旗標、寫在動詞前面：`cx --dry-run acl apply`。
**沒有 `-n` 這個短旗標** —— `cx acl -n` 會被當成子指令。

需要 `setfacl`：`cx setup system acl`。

### 為什麼是 ACL，不是 chmod / chown

現行模型是 setgid + 群組（`deploy:www-data`，目錄 `02750`／`02770`）。
**setgid 只讓新建的目錄繼承群組，不繼承權限位元** —— 位元仍由建立者的 umask 決定。

實測（Debian trixie，umask 022，兩個帳號同群組）：

```
php-fpm 建 storage/logs/laravel.log  →  rw-r--r-- www-data:www-data
deploy 追加寫入                       →  Permission denied
```

這就是 Laravel「明明 chown 過了還是 permission denied」的成因。
`chmod -R 777` 能繞過，但 `storage/` 裡有 session、快取與上傳檔。

default ACL（`setfacl -d`）讓**每一個新建的檔案與目錄**自動帶上兩邊的權限，
完全不受 umask 影響，而 others 仍然是 `0`。同一組實測套上之後：

```
web 建檔 → dev 可寫   ✔
dev 建檔 → web 可寫   ✔
無關帳號讀 laravel.log / .env   ✘ 讀不到
web 改 backend/artisan          ✘ 擋住（web 只該讀原始碼）
```

### 三種權限分開處理

| 對象 | 規則 |
|---|---|
| **backend** | 整棵樹 web `rX`、dev `rwX`；`storage/` 與 `bootstrap/cache/` 兩邊 `rwX`；`.env` web 只讀；others 一律 `0` |
| **frontend** | 整棵樹 web `rX`、dev `rwX`。前端沒有「應用程式寫回原始碼」的情境，static 直送與 PM2 反代都只需要讀 |
| **user** | `cx acl user add <帳號>` 給 `rwX`（`--ro` 給 `rX`），含 default 規則，所以他新建的檔案 dev 也寫得動 |

權限用大寫 `X`：只有已經是目錄或已有執行位元的檔案才給 `x`。
小寫 `x` 會讓每一個 `.php` 都變成可執行 —— 沒必要的攻擊面。

### `Operation not permitted` 的意思

`setfacl` 需要**檔案的擁有者或 root** —— 同群組、甚至有寫入權都不夠。
樹裡只要有一個別人的檔案，`setfacl -R` 就會停在那裡，前面設好的留著、
後面的沒設到 —— 半套狀態最難查。

所以 `apply` / `user` 之前會先掃一遍擁有權，把「哪些檔、屬於誰、怎麼修」
一次講完，而不是讓 setfacl 吐一句 `Operation not permitted` 就停。

實際來源（2026-09-04 踩到）：容器的 entrypoint 以 root 執行，
`artisan package:discover` 與 `storage:link` 在 bind mount 裡留下 `root:root`：

```
root:root  backend/bootstrap/cache/packages.php
root:root  backend/public/storage
```

entrypoint 已經修好（生成後立刻 `chown` 回 `www-data`；symlink 那個要用 `-h`，
不然會改到它指向的目標）。既有的殘骸用 `cx acl fix-owner` 清掉。

以 root 執行時（`sudo cx acl apply`）不做這個檢查 —— root 本來就設得動任何檔案。

### 本機 web 與 dev 常常是同一個 uid

容器裡的 `www-data` 在 build 時已被對齊成 `APP_UID`（`docker/php/Dockerfile`
的 `groupmod`/`usermod`），而 `APP_UID` 預設就是你的 uid。
所以本機開發其實不需要 ACL —— `cx acl check` 會直接把這件事講出來，
免得你以為自己漏設了什麼。規則仍然寫上去，之後 `APP_UID` 改了才不會突然壞掉。

### 部署主機

目標機由 Ansible 的 `common` role 處理（`tasks/acl.yml`，同一套模型），
不需要在目標機上跑 `cx`。開關是 `common_manage_acl`（預設 `true`）。

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

| 範圍 | 內容 | 需要什麼 |
|---|---|---|
| `cli` | cx 自己：動詞／旗標／補全／help 四方同步 | 什麼都不用 |
| `docs` | 文件與實作是否一致（教的變數真的被讀嗎、路徑對嗎） | 什麼都不用 |
| `tui` | 選單每一項都指得到真的存在的指令，且每個動詞都到得了 | 什麼都不用 |
| `static` | compose 合併結果、Dockerfile、版本鎖定 | 要有 `.env` |
| `ansible` | syntax-check + ansible-lint + yamllint | 要有 ansible |
| `runtime` | supervisord、vendor、APP_KEY、xdebug | 容器在跑 |
| `app` | `/up`、`/admin`、`/sanctum`、前端 | 容器在跑 |
| `waf` | 引擎狀態、攻擊被擋、**Livewire 正常請求不被誤擋** | test 模式在跑 |
| `acl` | setfacl 可用、檔案系統支援、`cx acl check` | setfacl |
| `all` | 全部，會依序把三個模式都起起來 | 很慢 |

省略範圍 = `cli docs tui static app ansible`。
報告預設寫到 `reports/verify/<時間戳>.md`。

三個結果嚴格分開：**PASS**（真的驗過）、**FAIL**（真的壞了）、
**SKIP**（這次沒辦法驗，**不算通過**）。

### `cli` / `docs` / `tui` 為什麼值得獨立出來

這個專案已知的缺陷有一半以上不是「程式寫錯」，而是**兩個地方對同一件事的
說法不一致**，而且沒有任何東西在盯著：

| 曾經發生的 | 現在由哪一項擋住 |
|---|---|
| `help` 說 doctor 會檢查埠與子模組，doctor 兩個都沒實作 | `CLI-help` |
| `_scan_usage` 寫著 `--fail-on-findings`，parser 直接拒絕 | `CLI-flags` |
| 補全的 `$verbs` 有 `acl`，`case` 沒有 `acl` 分支 | `CLI-verbs` |
| `CX_SETUP_SYSTEM_TOOLS` 有 `acl`，`_setup_system_have` 沒有 | `CLI-setup` |
| TUI 的 `galaxy` 指到不存在的 `cx setup galaxy` | `TUI-resolve` |
| `ansible/README` 說「從未在真機跑過」，另兩份文件記著兩次完整部署 | `DOC-ansible-run` |
| README 教人設 `waf_mode`，沒有任何 role 讀它 | `DOC-ansible-vars` |

這一類的共通點是：單看任何一個檔案都完全正確。所以檢查一定要跨檔比對，
而且兩邊都從**實際的東西**推導 —— 再開一份手打的清單只會變成下一個會漂移的地方。

這三個範圍完全不碰 Docker 也不需要 `.env`，在剛 clone 下來、什麼都還沒裝的
樹上就跑得完，秒級。

### `waf` 為什麼要有自己的範圍

`app` 範圍只打 edge，完全不經過 WAF；而 `cx scan dast` 的閘門是
「無 High risk alert」，它不會告訴你**正常請求被擋掉了**。
2026-09-05 之前的狀態正是：攻擊 100% 全擋、Filament 後台完全不能用，
兩件事同時成立而且沒有任何檢查會發現。

`waf-livewire` 這一項會現場從 `/admin/login` 的 HTML 撈出 Livewire 的端點前綴
（由 `APP_KEY` 推導，寫死就會在下一次 `key:generate` 之後失效），
送一個含 HTML 與 SQL 關鍵字的元件快照，比對「經 WAF」與「直連 edge」的狀態碼。
兩者相同才算通過。

---

## `cx deploy` — Ansible

```
cx deploy <子指令> [限制] [額外參數轉給 ansible…]
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
| `rollback [限制]` | 互動式回滾到前一個 release | 同上 |
| `facts <主機>` | 抓一台主機的 ansible facts | |
| `vars [限制]` | 印出該群組合併後的變數（查「我設的值到底有沒有生效」） | |

`check` / `apply` / `app` / `ping` 的**第二個之後**的參數會原樣轉給 ansible：

```bash
cx deploy check staging -e php_repo_source=distro
cx deploy check staging --tags php
```

轉發前會印出 `額外參數：…`，所以看得出來有沒有真的傳下去。
（2026-09-04 之前這些參數會被安靜丟掉 —— 指令跑完、用的卻是預設值。）

第一個位置放旗標仍然會被擋（那通常是想寫 `--limit` 的筆誤）。
`cx deploy apply --yes` 也會被擋：ansible 對「比對不到任何主機」的 pattern
只給 warning 然後 exit 0 —— 於是 apply 會安靜地什麼都沒做卻回報成功。

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
| `save [-m 訊息]` | `commit` 的別名 |
| `branch list\|new\|switch\|delete <名稱> [--repo main\|backend\|frontend\|all]` | 預設三個 repo 一起；`new` 另接 `--from <ref>`（switch/delete **不吃**，會 EX_USAGE）；主庫拒絕 `feature/*` |
| `remote-init` | 用 `gh` 在 `.cxroot` 的 `CX_GH_ORG` 底下建三個 public repo（**有確認閘門**） |
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
5. `cx git sync` —— 把子模組從 detached HEAD 接回追蹤分支：內容相同就純 `checkout`、HEAD 領先就 `-B` 快轉、**分支領先或已分岔則保持 detached**（不會倒退分支）
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

1. **遠端白名單**（只有裝了 hook 才生效；預設未安裝）。唯一合法的是
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

## `cx git` 的 gitflow、單一 repo 與設定

### 分支模型只有一個來源

`.cxroot` 的兩行：

```
CX_GIT_MAIN_BRANCH=main      # 發布線
CX_GIT_DEV_BRANCH=dev        # 開發主線
```

`git.sh` 原本有**六處寫死 `main`**。現在 `_git_main_branch` / `_git_dev_branch`
是唯一來源，`branch delete` 也會拒絕刪掉這兩條（`_git_is_protected_branch`）。

### feature：只開在子模組，從該子模組的 dev 開、合回 dev

```bash
cx git flow-init                            # 先補齊拓撲（冪等，只補缺的）
cx git feature start login --repo backend   # 只在 backend 建 feature/login（從它的 dev）
cx git feature list
cx git feature finish --repo backend        # 合回 backend 的 dev（--no-ff），
                                            # 再讓主庫的 dev 只提交這一顆 gitlink
                                            # 不推送、不刪分支
```

`finish` 刻意**不做**推送與刪分支：那兩件事各自有自己的閘門，混進來會讓
`finish` 變成一個「一次做了三件不可逆的事」的動詞。合併完會告訴你下一步。

只做 feature 這一條線。release / hotfix 牽涉版本號與 tag，而本專案目前沒有
版本號策略 —— 做一半的 release 流程比沒有更糟。

### branch 的起點與範圍

```bash
cx git branch new fix/x                    # 預設從 dev 開
cx git branch new fix/x --from main        # 指定起點
cx git branch new fix/x --repo backend     # 只在某一個 repo
```

原本是裸的 `switch -c <名稱>`（沒有起點），也就是「從你現在剛好在的地方開」——
gitflow 之下 feature 必須從 dev 開，而「現在剛好在哪」不是可重現的東西。

### 只提交一個 repo

```bash
cx git commit --repo frontend -m "fix(ui): …"
```

`--repo` 吃 `main` / `backend` / `frontend` / `all`（預設 `all`）。
只提交子模組時會提醒你主庫的 gitlink 還指向舊的 commit，並給出補上的指令。

> ⚠ 2026-09-05 之前，`cx git commit` 的每一步都**沒有接退出碼**，然後無條件印
> `✔ 已提交`。實測：pre-commit hook 失敗時它印「✔ 主庫已提交（4 項，含
> gitlink）」並回傳 0，而 repo 裡一個 commit 都沒有。現在每一步都會接，
> 失敗時回 `EX_FAIL` 並指向 git 自己的訊息。

### git 身分與編輯器

```bash
cx git config show                                    # 三個 repo 目前的設定
cx git config identity --name "你的名字" --email you@example.com
cx git config identity --name … --email … --global    # 寫進 ~/.gitconfig
cx git config editor "code --wait"
```

`cx git commit` 會先檢查身分 —— 沒有的話 `git commit` 會失敗，而那個失敗
原本是被吞掉的。

`editor` 會拒絕 `true` / `false` / `:` / `cat` 這類 no-op：把它們寫進
`core.editor` 的後果是**commit 訊息永遠是空的**，而 git 只會說
「Aborting commit due to empty commit message」，完全指不到原因。
（本機實測遇過 `GIT_EDITOR=true` 的環境。）

### 指到現成的遠端

```bash
cx git remote-init                       # 用 gh 建立三個 repo 並接上
cx git remote-set git@github.com:me/shop.git   # 指到已經存在的
```

`remote-set` 只做 set-url + 補 fetch refspec 那一半，不建立 repo。
只給主庫 URL 時，backend / frontend 由同一個目錄推導。
位址不在推送白名單（由 `.cxroot` 推導）時它會先警告，而不是等到 push 才擋。

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
cx fresh [--phase preflight|backup|migrate|delete|rebuild|verify|git-init|all]
         [--resume-from rebuild|verify|git-init]
         [--mode backup-only|carryover(預設)|scaffold] [--rollback] [--from <封存目錄>]
```

流程：**preflight → 備份 → 驗證封存 → 確認閘門 → 遷移 → 刪除 → 重建 → 驗證重建 → 三 Git 初始化**。

> **PF-10：這棵樹必須是一般的 clone。** `.git` 是檔案（git worktree）時 `cx fresh` 直接拒絕、
> 什麼都不動 —— worktree 的物件庫在 `CX_ROOT` 之外，封存抓不到它、刪除也刪不掉它，
> 而整條流程會「成功」。2026-09-05 之前這個情況會產出一份**通過驗證但不含主庫歷史**的封存。

`_fresh_nuke` 的護欄（任何一條不成立就中止，不是跳過）：
- 拒絕 symlink（避免被指到樹外）
- 路徑必須**嚴格**位於 `CX_ROOT` 之下
- 拒絕 `CX_ROOT` 本身、`$HOME`、`/`
- 不可以 root 執行

備份驗證不是「檔案存在就算數」：從 MANIFEST 推導出**預期產物清單**逐一比對，
每個 tar 都 `tar -tzf` 過一遍，每個 git bundle 都**真的解一次**
（`git init --bare` + `fetch`）—— `git bundle verify` 只讀 header，
一個被截斷的 bundle 它照樣說 OK。

### 重建（`--mode`）

| 模式 | 做什麼 |
|---|---|
| `backup-only` | 只封存，不刪也不建 |
| `scaffold` | 全新骨架：`composer create-project laravel/laravel` + `filament/filament:^5.0` + `larastan:^3.0`，以及 `nuxi init --template minimal` |
| `carryover` | 全新骨架，再從封存的 src tar 把**應用層**目錄疊回去（預設） |

carryover 疊回的是 `backend` 的 `app/database/routes/resources/tests`
與 `frontend` 的 `app/components/pages/…`。骨架檔（`config/`、`bootstrap/`、
`package.json`、`nuxt.config.ts`）**刻意用新版的** —— 框架升級真正會變的就是那些，
而反過來做需要一份「這一版新增了哪些骨架檔」的清單，那份清單不存在。

重建的工具鏈不沿用 `cx_runner()`：重建當下本專案的 app 映像還沒建
（原始碼剛被刪掉），所以容器路徑用的是一次性的官方 `composer` / `node` 映像。

> `nuxi init` 在非互動終端下 `--template` 與 `--gitInit` **兩個都是必填的**，
> 「布林旗標不給等於 false」在這裡不成立。

### `--rollback` — 從封存還原

```
cx fresh --rollback [--from <封存目錄>]
```

省略 `--from` 就用 `<封存根>/LATEST`。

順序與封存相反：**驗證封存 → 列出會被覆蓋的路徑 → 確認閘門 → 主庫 `.git`
→ 前後端原始碼 → 前後端的真實 gitdir（放回 MANIFEST 記錄的位置）→ 對帳**。

- 先驗證再還原：不用一份壞掉的封存去覆蓋一棵好的樹。
- 被覆蓋的內容先移到 `.cx-restore-backup/<時間戳>/` 而不是直接刪 ——
  還原到一半失敗時至少還拿得回原本的狀態。
- 對帳會比對 HEAD 與 commit 數，跟 MANIFEST 不一致就回非零。
- **資料庫不在還原範圍**：把檔案還原與資料庫還原綁在一起，任一邊失敗都會讓
  另一邊處於不確定狀態，而資料庫還原不可逆。要還原資料庫用 `cx db restore`。

> 子模組的 gitdir 是這一步的坑：`backend/.git` 是一個 32 bytes 的**指標檔**
> （`gitdir: ../.git/modules/backend`），真正的 gitdir 在別的地方。
> 只還原 src tar 的話，`backend/` 會是一棵沒有 git 的普通目錄。

---

## `cx init` / `cx re-init` — 把範本變成一個新專案

```bash
cx --dry-run init shop --org my-org        # 先看會做什麼
cx init shop --org my-org --gh             # 改名 → 重建 → 用 gh 建三個 repo
cx init shop --remote git@github.com:me/shop.git
cx re-init --mode carryover                # 名字不變，重建骨架但留下自己的程式碼
```

### 它幾乎沒有自己的邏輯，而那是刻意的

`cx init` 只做三件事：把名字改對、按正確順序呼叫既有的動詞、在最前面問一次。

| 步驟 | 由誰做 |
|---|---|
| 改寫專案身分 | `cx rename <新名稱> [--org]` |
| 刪 `.git`、重建骨架、重新連結 submodule、`git init` | `cx fresh --mode carryover`（**預設**）或 `--mode scaffold` |
| 建立或接上遠端 | `cx git remote-init`（gh）或 `cx git remote-set <URL>` |

破壞性邏輯、封存與 rollback 全都在 `cx fresh` —— 那是本專案唯一經過對抗式
稽核與實跑驗證的那一份。再寫一份「其實差不多」的流程，等於讓保護各自演化然後分岔。

### 順序不可調換

**`rename` 必須在 `fresh` 之前。** `_fresh_git_init` 會用 `.cxroot` 的
`CX_REPO_BACKEND` / `CX_REPO_FRONTEND` 重新產生 `.gitmodules`；反過來做的話，
`.gitmodules` 會帶著範本的舊名字被寫進新專案的**第一個 commit**。

實測（2026-09-05，`cx init shop --org my-org`）：

```
CX_PROJECT_NAME=shop ・ CX_GH_ORG=my-org ・ CX_REPO_BACKEND=shop-backend
.gitmodules → url = ../shop-backend.git    ← 新名字，證明順序是對的
主庫 commit 數：1（全新歷史）
```

### 確認閘門與 `cx fresh` 的不一樣

`cx fresh` 要你打 `DESTROY <目前的專案名>`。在 init 的情境裡那個名字還是**範本的**
名字 —— 讓人打 `DESTROY pm` 而他其實想建立 `shop`，是在問錯的問題。
所以 init 要求的是 `INIT <新名字>`（`re-init` 則是 `RE-INIT <目前的名字>`），
並且額外列出 fresh 的清單裡沒有的損失：`.env` 的密碼、
`ansible/inventory/hosts.yml`、以及仍叫舊名字的容器與 volume。

### 骨架產生之後會自動裝回「範本自己的東西」

`composer create-project` 與 `nuxi init` 產生的是**框架的**骨架，
裡面沒有本專案加上去的保護。所以重建的最後一步會跑 `bin/lib/scaffold_patch.py`，
把這兩組裝回去：

| 裝回什麼 | 少了會怎樣 |
|---|---|
| `tests/bootstrap.php`、`tests/DatabaseSafetyGuard.php`、`TestCase.php` 的 `createApplication()` 覆寫、`phpunit.xml` 的 `bootstrap=` | 測試資料庫的 hard guard 整組消失 |
| `eslint.config.mjs`、兩個 devDependency、`nuxt.config` 的 `modules` | 前端沒有 ESLint 基線 |

> 這一步是 2026-09-05 補的：在它之前，`cx init shop` 產出的專案跑
> `cx verify cli` 有 **9 個 FAIL**，其中 6 個就是上面這兩組。
> `GRD-wire` 的說明裡早就寫過同一件事會發生 —— 只是當時說的是 carryover，
> 實際上 scaffold 更嚴重（連檔案都不存在）。
>
> 每個動作都是冪等的：連跑兩次第二次會說「已經是最新狀態」。

---

## `cx deploy hosts` — Ansible 主機清單

```bash
cx deploy hosts init                                   # 建立空的 hosts.yml
cx deploy hosts add web-1 --ip 203.0.113.11 --user ubuntu
cx deploy hosts add web-2 --ip 203.0.113.12 --user ubuntu   # 第二台預設不是 db_primary
cx deploy hosts show
cx deploy hosts check --ansible                        # 結構 + A15 + 讓 ansible 自己剖析
cx deploy hosts rm web-2
cx deploy hosts edit                                   # 用編輯器直接開（註解會保留）
```

`ansible/inventory/hosts.yml` 是 `cx deploy` 每一個動詞都需要、卻是**唯一沒有
工具幫忙產生**的檔案。原本從選單走到部署那一步會撞牆，訊息只說「缺少
hosts.yml」，然後叫人離開 cx 自己 `cp` 範例檔。

### 群組模型（來源：`ansible/site.yml` 的 roles 區塊）

| 群組 | 決定什麼 |
|---|---|
| `pm_servers` | `site.yml` 的作用對象。所有主機都要在裡面（`common` / `hardening`） |
| `web` | php-fpm / nginx / node+PM2 / `deploy_backend` / `deploy_frontend` / `healthcheck` |
| `db_primary` | MySQL，而且**由它執行 `artisan migrate`**。剛好一台，且必須也在 `web` 裡 |

`check` 會擋下三種真的會壞的狀況：`db_primary` 是空的、`db_primary` 超過一台、
`db_primary` 有成員不在 `web`（A15 —— migration 掛在 `web` 的 gate 上，
不在 `web` 就一次都不會跑，而 `site.yml` 的 preflight 也會擋）。

### ⚠ 哪些東西**不能**拆到不同主機

nginx、前端、後端目前**必須在同一台**。這不是設定問題，是架構事實：

* `php_fpm_socket` 是 **unix socket**（`ansible/roles/php/templates/pool.conf.j2`），
  nginx 只連得到同一台的 PHP
* 前端 PM2 綁 `127.0.0.1:3000`（`deploy_frontend/defaults/main.yml`）

要真的拆開，得把 php-fpm 改成 TCP、PM2 綁到內網位址、nginx 的 upstream 指到
遠端主機，並處理三者之間的網路與授權 —— 那是架構變更，不是這個工具的範圍。

**可以**拆的是資料庫：多台 `web` + 其中一台兼 `db_primary`。
那個拓撲要另外處理 `mysql_bind_address`、`db_host`、`mysql_app_user_hosts`
與 `deploy_serial`，`hosts.yml.example` 的檔尾有完整寫法，`check` 也會提醒。

> `add` / `rm` 會**重新產生**整個檔案，所以手寫的註解會消失（結構與值會保留）。
> 要手寫請用 `cx deploy hosts edit`，那條路徑不經過產生器。

---

## `cx rename` — 把範本改成新的專案名

```bash
cx --dry-run rename shop --org my-org   # 只列出變更點，不動任何檔案
cx rename shop               # 列出變更點 → 確認閘門 → 套用
```

### 為什麼需要一個動詞

`cx` 的 shell / Python 層是**乾淨**的 —— 專案身分一律從 `.cxroot` 的
`CX_PROJECT_NAME` 推導（`cx_project` / `cx_project_for` / `cx_sonar_project`）。
但有四個地方是硬編碼或**第二事實來源**：

| 位置 | 就地改名時會怎樣 |
|---|---|
| `.env` 的 `PROJECT_SLUG` / `IMAGE_PREFIX` | **最嚴重的一個。** `_setup_env` 只在**產生** `.env` 時寫入，檔案已存在就早退、從不回頭核對 —— 於是 compose 專案前綴仍是舊的，網路還叫 `pm_dev_net`，而且沒有任何地方會說出來 |
| `sonar-project.properties` 的 `projectKey` / `projectName` | SonarQube 上還是舊專案 |
| `group_vars/all/main.yml` 的 `app_name` / `app_slug` / `db_name` / `db_user` / 三個 repo URL | 部署出去的資料庫名與帳號名還是舊的 |
| `site.yml` 的 `hosts:` 群組名 ←→ `deploy.sh` 的 `--list-hosts` | 兩者不一致時 `cx deploy ping` 會**找不到任何主機** |

### 會改什麼、不會改什麼

會改上表那四類，加上 `.cxroot` 自己（含三個 repo 名）與 `.env.example`。

**不會**動 `.git`、不會碰任何 remote、不會刪除任何 docker volume。
改名不該動版本歷史，remote 要不要改是另一個決定。

名稱規則是 `^[a-z][a-z0-9_-]{1,30}$` —— 那是交集：compose 專案名只吃小寫英數與
`-` `_`，MySQL 帳號名上限 32 字元，而 Ansible 群組名不能含 `-`（會被當成運算子，
所以群組名一律轉成底線：`shop_servers`）。

### 改完之後要自己做的四件事

動詞刻意不自動做這些 —— 它們都會動到既有資料或需要判斷：

```bash
cx dev down -v && cx test down -v && cx prod down -v   # 舊的容器／網路／volume 還叫舊名字
cx dev up -d --build                                   # 映像 tag 前綴變了
cx setup guard                                         # git hook 的白名單裡有專案名
cx verify cli                                          # TPL-* 四項應該全綠
```
`ansible/inventory/hosts.yml` 的群組名也要自己改（那個檔不進版控）。

### 檢查比自動化重要

`cx verify cli` 的 **`TPL-*` 四項**會在每次驗收時比對上面那些點，
所以就算有人手動改名改到一半、或是 `cx rename` 漏掉某處，都抓得到。
實測：只改 `.cxroot` 不改其他 → `TPL-env` / `TPL-sonar` / `TPL-ansible` 三項立刻 FAIL。

> `TPL-group` 檢查的是 `site.yml` 與 `deploy.sh` **彼此**一致，
> 不是「群組名等於專案名」—— 前者是會讓部署整個失效的性質，後者只是慣例。

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

## `cx test cli` — cx 自己的行為測試（bats）

```
cx test cli [--strict]
```

`cx` 有 8000+ 行 bash，而在這之前**零行為測試**。既有的兩道都不執行任何
cx 程式路徑：`cx lint sh` 是 shellcheck（靜態），`cx verify cli/docs/tui`
是跨檔一致性（也是靜態）。`bin/cmd/lint.sh` 自己就寫著 shellcheck 抓不到本專案
最貴的那類缺陷 —— `_setup_system_have` 少一個 `case` 分支是**完全合法的 bash**。

| 檔案 | 涵蓋 |
|---|---|
| `00_dispatch.bats` | 全域旗標驗證、動詞解析、每個動詞的 `--help` 都跑得起來 |
| `10_exitcodes.bats` | `EX_*` 的**數值契約**（CI 會拿去分支判斷，所以恰好一個地方硬編碼，而那裡是測試不是文件） |
| `20_runner.bats` | 三條 runner 路徑、WSL interop 偵測 |
| `30_dryrun.bats` | `--dry-run` 跑完之後整棵樹的指紋不變 |
| `40_gates.bats` | 破壞性閘門（fresh 的打字確認、acl user rm、push 黑名單、deploy apply 拒絕 --yes） |
| `50_archive.bats` | 封存的失效模式（截斷的 bundle、缺檔、對帳、冪等、備份不被直接刪） |
| `60_fresh.bats` | 階段機、`--resume-from`、麵包屑、還原往返 |
| `70_project.bats` | 改名之後所有推導值都跟著走 |
| `80_verify.bats` | PASS/FAIL/SKIP 語意（含一個**正向對照**：故意製造缺陷，確認真的會 FAIL） |

### 設計上的三個決定

**fixture 跑的是真程式碼，對的是假的樹。** `cx --root <目錄>` 只要求該目錄有
`.cxroot`，其餘全部從 `$CX_ROOT/bin/` 載入 —— 所以 fixture 把真的 `bin/` 與 `cx`
symlink 進來。絕不 source `common.sh` 進 bats 再直接呼叫函式：那會繞過 cx 自己的
旗標解析、`set -Eeuo pipefail`、ERR trap，以及 `cx:196` 的
`"$fn" "$@" || _rc=$?` —— 而退出碼的契約正是活在那一行。
破壞性測試（fresh／archive）用完整的 git fixture，且 helper 會斷言
`CX_TEST_ROOT` 位於 bats 的臨時目錄底下才繼續。

**Docker 不 mock。** 需要觀察「daemon 不可用」行為的用
`DOCKER_HOST=unix:///nonexistent/docker.sock`；真的需要 daemon 的 `skip`。
**不從 PATH 拿掉 docker** —— 「CLI 不存在」與「daemon 不通」是兩個不同的分支、
不同的訊息，混在一起就是在測錯的程式碼。

**bats 把 `skip` 算成成功，這與本專案的「SKIP ≠ PASS」直接衝突。**
`cx test cli` 會把跳過的數量與原因印出來，並支援 `--strict`
（或 `CX_TEST_STRICT=1`）讓 CI 把任何跳過當成失敗。

### 不 vendor bats-support / bats-assert

它們同樣沒有 release asset，引進來就是兩個沒有校驗的下載，或一份 vendor 進
public repo 的第三方 bash（那會被 `cx scan sca` 掃到，也會讓 `cx lint sh`
開始檢查別人的程式碼）。需要的只有 `assert_success` / `assert_output`，
那是 `bin/test/helpers/common.bash` 裡十幾行 —— 而且自己寫的版本可以印出
完整的 cx argv 與輸出尾巴。

安裝：`cx setup tools bats`。版本釘死（`CX_BATS_VERSION`），並帶一個
**本專案自己記下的** SHA256 —— 上游沒有出校驗檔，所以那個雜湊防的是
「釘版之後 URL 的內容被換掉」，**不是**「上游 release 被攻陷」。

---

## `cx style` — 程式碼風格（**會改檔案**）

```
cx style [php|js|all] [--check] [-- 工具參數...]
```

| 範圍 | 工具 | 位置 |
|---|---|---|
| `php` | Laravel Pint | `backend/vendor/bin/pint` |
| `js` | Prettier | `frontend/node_modules/.bin/prettier` |
| `all` | 兩者（預設） | |

兩個工具都**已經隨既有相依裝好**（`composer.json` 的 require-dev 與
`package.json` 的 devDependencies），不需要另外安裝。
在 2026-09-05 之前它們沒有任何動詞叫得到 —— 買了沒用。

雙 runner。容器路徑帶 `-u $(id -u)`：`backend/` 在 dev 是 bind mount，
以 root 跑會把改過的檔案變成 `root:root`。

`--check` 只檢查不改，有差異就回非零 —— CI 與提交前用這個。

---

## `cx lint` — 靜態檢查（**不改檔案**）

```
cx lint [ansible|php|js|sh|all] [目錄]
```

| 範圍 | 做什麼 |
|---|---|
| `ansible` | `bin/lib/ansible_lint.py`（YAML 剖析、FQCN、紅線、變數引用、changed_when） |
| `php` | `pint --test`（= `cx style php --check`） |
| `js` | **ESLint**（`@nuxt/eslint`）+ `prettier --check`。兩個都跑完才回傳最嚴重碼 |
| `sh` | `shellcheck` 掃 `cx` 與 `bin/**/*.sh` |
| `all` | 以上全部（預設） |

全部跑完才回傳最嚴重的退出碼，不是遇到第一個問題就停。
舊用法 `cx lint <目錄>` 仍然等於 `cx lint ansible <目錄>`。

**`lint` 與 `style` 的分工是硬的**：`lint` 絕不改檔案，`style` 才會。
混在同一個動詞底下，遲早有人在 CI 裡跑 lint 然後意外改了一整棵樹。

### ESLint 與 Prettier 的分工也是硬的

| | 管什麼 |
|---|---|
| ESLint | **會出錯的東西** —— 未使用的變數、Vue 的錯誤用法（`v-for` 沒 key…） |
| Prettier | 只管排版 |

`frontend/eslint.config.mjs` 刻意**不開任何排版類規則**，所以兩者不會互相打架，
也就不需要 `eslint-config-prettier` 去關掉一堆規則。
`cx style js` 維持只做 Prettier `--write`（lint 不改檔案的紀律不變）。

設定會 `import ./.nuxt/eslint.config.mjs` —— 那份由 `@nuxt/eslint` 模組在
`nuxt prepare` 時產生（`package.json` 的 `postinstall` 會跑），帶著 Nuxt 的
auto-import 全域（`defineNuxtConfig`、`useRuntimeConfig`…）。
**沒跑過 `prepare` 就沒有那個檔**，`cx lint js` 會回報 `EX_PRECOND`（環境問題）
而不是假的 lint 失敗。

> ⚠ `cx fresh --mode carryover` 會把這一整套弄不見：`_fresh_keep_dirs frontend`
> 只保留目錄，`nuxi init` 會重新產生 `package.json`（兩個 devDependency 消失）
> 與 `nuxt.config.ts`（modules 少掉 `@nuxt/eslint`），而 `eslint.config.mjs`
> 根本不在 KEEP 清單裡。三件事同時發生時 `cx lint js` **只會安靜地少跑一半**。
> 所以 `cx verify cli` 有 `LNT-eslint-*` 四項在盯著這件事。

> ⚠ **加模組進 `nuxt.config.ts` 之後，每一個會跑 Nuxt 的環境都要有那個相依。**
> dev 的 `node_modules` 是**具名 volume**，不會因為 `package.json` 變了就自己更新 ——
> 症狀是 dev 的 `/` 回 500，容器日誌寫 `Cannot resolve module "@nuxt/eslint"`，
> 而 test/prod 完全正常（它們的映像是 `npm ci` 重建的）。
> 兩步解決：
>
> ```bash
> cx --runner docker npm ci        # 更新 dev volume 裡的 node_modules
> docker restart pm_dev-nuxt-1     # dev server 要重啟才會重讀 nuxt.config
> ```
>
> test/prod 則是 `cx <模式> up -d --build nuxt`。
> `@nuxt/eslint` 是 devDependency，但 prod **執行期**不讀 `nuxt.config.ts`
>（跑的是 `.output/server/index.mjs`），所以只有建置階段需要它 —— 而建置階段的
> `npm ci` 本來就會裝 devDependencies。

`ansible` 那一支是 `--syntax-check` 的**替代品，不是等價物**。
ansible 裝好之後請改用 `cx deploy lint`。它會排除 `collections/`、`.cache/`、
`.ansible/`、`.git/`、`__pycache__/` —— 不排除的話它會去檢查上游 collection
的原始碼，回報 803 個跟本專案無關的 finding。

`sh` 的閘門只看 **error**，warning 完整顯示但不擋 —— 與 ② SAST 那條 lane 一致。
理由見本文件的 SAST 嚴重度閘門一節：用「有任何 finding 就失敗」當閘門的結果是
這條 lane 永遠紅燈，於是沒有人會再看它。
第一次跑就抓到三個 error（`sonar.sh` 的單元素迴圈、`scan.sh` 的前綴賦值作用域、
兩處以 `# shellcheck` 開頭的中文註解被當成指令解析），都已修。

**但有一小撮 shellcheck 歸類為 warning 的東西，其實是正確性缺陷，一律當 error 擋**
（`bin/cmd/lint.sh` 的 `fatal_warn`）：
`SC2215`（旗標被當成指令名）、`SC2216/7`（管給不讀 stdin 的指令）、
`SC2218`（函式在定義前被呼叫）、`SC2069`（`2>&1 >file` 寫反）、
`SC2064`（trap 用雙引號，變數在設 trap 當下就展開）、
`SC2140`（字串意外相接）、`SC2145`（陣列接在字串上）。

清單刻意保持很短，而且每一個加入前都確認過**目前的樹上是 0 命中** ——
所以這道閘門是綠的，不是一開就紅的裝飾品。

`SC2215` 是 2026-09-05 真的踩到才加的：註解夾在 `\` 續行中間時，bash 會把續行接
上來、`#` 吃掉整行、而那行沒有結尾的 `\`，於是**指令在那裡就結束了**。當時
`cx scan sast` 的 `docker run` 因此少了映像名稱，後面的 `-e …` 變成一條新指令。
`bash -n` 過得了 —— 那是合法語法，只是變成另一支程式。

---

## `cx tui`

不給動詞時的預設。whiptail 選單，把上面所有動詞包成互動式。
**沒有 tty 時不會退回 plain，而是硬失敗**（`EX_PRECOND` = 3）：

```
$ ./cx < /dev/null
✘ cx 的選單需要終端機（TTY）
    目前偵測到：CX_UI=plain、fd8 否 TTY
    非互動環境請直接給動詞，例如： cx doctor / cx scan all / cx git status
; echo $?
3
```

這是刻意的：選單是互動介面，在腳本／CI／pipe 裡「安靜地做一半」比直接停下更糟。
非互動環境一律明確給動詞。

同理，`--ui plain` 也會讓選單不可用 —— `cx_interactive()` 要求
「fd 8 是 tty」**且**「`CX_UI != plain`」兩個條件同時成立。

選單執行動詞時會**開真正的子行程**（`cx --ui plain --mode … --runner … <動詞>`），
不是在同一個 shell 裡呼叫函式 —— 理由見 `bin/cmd/tui.sh` 開頭的說明。

### 模式與 runner

主選單標題會顯示目前狀態 `[模式：dev・runner：auto]`，兩者都可以在選單裡切換：

| 位置 | 作用 |
|---|---|
| 主選單 → `切換模式` | 之後每一個指令都帶 `--mode <dev\|test\|prod>` |
| 環境 → `切換 runner` | 之後每一個指令都帶 `--runner <auto\|docker\|native>` |

> 2026-09-04 之前這兩個只能從命令列給。標題印著 `[模式：dev]` 卻沒有任何入口
> 可以改它 —— 看得到、改不了。

「容器」子選單是明確對某個模式操作，進入時會暫時切過去、離開時還原，
所以在 `test` 的容器選單裡按 `up` 不會把你的 session 模式留在 test。

### 整備環境

環境 → `整備環境` 對應 `cx setup` 的每一段，可以分開跑：

| 選項 | 等同 |
|---|---|
| 基本初始化 | `cx setup`（.env + 目錄 + collections） |
| ★ 一次裝完原生工具鏈 | `cx setup native`（system → tools → deps） |
| 需要 root 的系統套件 | `cx setup system` |
| 免 root 的工具鏈 | `cx setup tools` |
| 專案相依 | `cx setup deps` |
| 只產生 .env | `cx setup env` |
| 只建立目錄 | `cx setup dirs` |
| 安裝 push guard | `cx setup guard` |
| 安裝 ansible collections | `cx deploy galaxy` |

> 最後那一項在 2026-09-05 之前是壞的：選單把它接成 `cx setup galaxy`，
> 而 `setup` 沒有這個子指令，點下去只會得到 exit 2。
> 現在 `cx verify tui` 的 `TUI-resolve` 會擋住這一類。

搭配上面的 runner 切換，這就是「安裝執行環境，並區分 docker 與原生」的入口。

### 自訂選單

主選單 → `自訂選單` 讀 `.cx/menu.conf`（可用 `CX_MENU_FILE` 覆寫）。
第一次進入會自動產生一份帶範例的範本。格式是每行一項：

```
標籤|要傳給 cx 的參數
```

`#` 開頭是註解，空行忽略。參數會原樣接在 `cx` 後面，並自動帶上目前的
`--mode` 與 `--runner`。例如：

```
重建 dev 並驗收|dev up -d --build
只掃祕密|scan secrets
後端測試（原生）|test back
```

子選單最後一項可以直接開編輯器改這份檔案，存檔後立即生效（不必重開選單）。
`.cx/` 已被 `.gitignore` 排除，所以自訂選單是每台機器各自的。

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
