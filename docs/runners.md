# 兩條 runner：容器 與 原生

> 專案的每一個功能都要能**完全用 Docker** 跑完，或**完全用原生工具鏈**跑完。
> 兩條路各自獨立，不互相依賴。這份文件說明怎麼選、各自需要什麼、以及實測結果。

---

## 1. 怎麼選

`--runner` 是**全域旗標**，放在動詞之前：

```bash
cx --runner docker composer install    # 一定用容器
cx --runner native composer install    # 一定用原生 composer
cx composer install                    # auto（預設）：有 Docker 就用 Docker
```

| 值 | 行為 |
|---|---|
| `auto`（預設） | 有可用的 Docker daemon 就走容器，否則走原生 |
| `docker` | **一定**走容器。daemon 不可用 → 硬失敗 `EX_PRECOND`(3) |
| `native` | **一定**走原生。缺工具 → 硬失敗 `EX_PRECOND`(3) |

### 為什麼被指定的那一邊不可用時要硬失敗

因為只要允許靜默 fallback，「原生路徑可以獨立運作」這件事就**永遠無法被驗證**
—— 你以為在測原生，實際上跑的是容器，而且沒有任何訊息告訴你。

實測（用一個一定連不上的 `DOCKER_HOST` 讓 daemon 不可用）：

```
$ cx --runner docker art --version
✘ cx art 需要 Docker，但 Docker daemon 不可用
    你指定了 --runner docker。要改用原生工具鏈： --runner native
rc=3

$ cx art --version          # 同樣的環境，但沒有指定 runner
runner: native（自動）
rc=0
```

`auto` 會降級，`--runner docker` 不會。這正是想要的行為。

### 每次都會印出這次跑在哪裡

```
runner: docker（自動） — 容器內的 composer
runner: native（指定） — composer 2.10.3
```

不必用猜的，也不必事後從行為反推。

---

## 2. 各自需要什麼

### docker runner

- Docker daemon 可用
- `docker-compose.yml` + `docker/compose/<mode>.yml` + Dockerfile

不需要 host 上有 php / composer / node —— 全部在映像裡。

### native runner

| 動詞 | 需要 |
|---|---|
| `cx art` | `php` + `backend/vendor` |
| `cx composer` | `composer`、`php` |
| `cx npm` | `npm` |
| `cx npm --backend` | `npm` |
| `cx test back` | `php` + `pdo_sqlite` + `backend/vendor` |
| `cx test front` | `npm` + `frontend/node_modules` |
| `cx db migrate/seed/admin/fresh` | `php` + `backend/vendor` |
| `cx db status/shell/wait` | `mysql` client |
| `cx db dump` | `mysqldump`、`gzip` |
| `cx test coverage` | **只有容器路徑**（需要 test 映像裡的 xdebug） |
| `cx db restore` | **只有容器路徑** |

| `cx scan dast` | **只有容器路徑**（ZAP 要 Java） |
| `cx pma` / `cx sonar` / 所有 compose 動詞 | **只有容器路徑** |

### 一行把原生那一邊裝起來

```bash
cx setup native          # = setup system + setup tools + setup deps
```

拆開來看是兩份清單：

| | 工具 | 指令 |
|---|---|---|
| 需要 root | `php`（cli + 擴充）・`nginx`・`git`・`docker`・`mysql-client`・`php-sqlite` | `cx setup system [名稱...]` |
| 免 root（`~/.local`） | `composer`・`node`（含 `npm`）・`ansible`・`trivy`・`gitleaks`・`semgrep` | `cx setup tools [名稱...]` |

**cx 絕不偷偷跑 sudo。** `setup system` 會先把完整的 `apt-get install` 指令列出來
再問你；`sudo` 需要密碼或不可用時，它**只印出那一行**並回傳 `EX_PRECOND`(3) ——
那不是失敗，在 CI 或不給 sudo 的機器上那就是正常流程。
`cx setup native` 遇到這種情況會記下來但**繼續**跑免 root 的那一半。

裝完之後 `cx_runner_need_native` 缺工具時的提示也會直接指向正確的子指令，
例如缺 `php` 時是 `cx setup system php`，缺 `composer` 時是 `cx setup tools composer`。

### ⚠ 裝好還不夠：`~/.local/bin` 必須在 PATH 上

`~/.profile` 有把它加進 PATH 的那一段，但 **`~/.profile` 只在 login shell 生效**。
Windows Terminal、VS Code 的終端機、部分 `wsl.exe` 呼叫進來的是非 login shell，
它們讀的是 `~/.bashrc`。

```bash
echo $PATH | tr : '\n' | grep '\.local/bin'      # 沒輸出就是中了
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
```

**在 WSL 上這不只是「工具找不到」而已。** WSL 預設把 Windows 的 PATH 併進來，
所以 `/mnt/c/Program Files/nodejs/npm` 一直都在。Linux 版的 npm 不在 PATH 時，
`npm` 會**靜默**解析到 Windows 那支 —— 它在 WSL 的專案目錄裡跑會
`CMD.EXE 不支援 UNC 路徑`，而且 `npm ci` 會「成功」地留下一棵殘缺的
`node_modules`（2026-09-04 實測 24 KB，裡面沒有 `nuxt`），
錯誤要到 `vite build` 才炸。

所以原生路徑的判斷用的是 `cx_have_native` 而不是 `cx_have`：
解析到 `/mnt/<磁碟>/` 或 `.exe` 結尾的一律不算數。
（`cx pma` 要開瀏覽器時反而**需要** `explorer.exe`，那裡仍用 `cx_have`。）

`cx doctor` 會把這兩種情況分開講：

```
✘ PATH 上有 Windows 的工具    npm=/mnt/c/Program Files/nodejs/npm
✘ PATH                        composer npm 已裝在 /home/sixtou/.local/bin，但不在 PATH 上
```

「裝了但看不到」跟「真的沒裝」的處置完全不同 —— 前者照著「請跑 cx setup tools」
重裝幾次都不會好，因為東西從來就是裝好的。

`cx doctor` 會把兩條路分開報，缺什麼、缺了會影響哪個動詞都寫清楚：

```
══ 兩條 runner 各自的完整性 ══
  ✔ docker runner                daemon 可用、compose 與 Dockerfile 齊全
  ✔ native runner                php / composer / npm 齊全
  ✔ native backend/vendor        已安裝
  ✔ native frontend/node_modules 已安裝
  ⚠ native pdo_sqlite            缺 —— 原生後端測試不可用（sudo apt install php8.5-sqlite3）
  ⚠ native mysql client          缺 —— 原生 cx db 不可用（sudo apt install mysql-client）
```

---

## 3. 兩條路的產出**不保證可以互換**

這是最容易踩到的地方。

### `backend/vendor`

容器是 `php:8.5-fpm-alpine`（musl），host 是 Ubuntu（glibc），而且擴充清單不同。
composer 會照「當下這個 php」解相依，所以兩邊解出來的樹可能不一樣。

這是**刻意**的：原生的 vendor 給 IDE 與原生 `cx scan code` 用，
容器的 vendor 由映像自己管（dev 模式用具名 volume 疊在 bind mount 上，
讓映像內那一份贏過 host 的）。

### `node_modules`

原生模組（Vite 8 的 rolldown binding）是照安裝當下的 libc 編的。

- host（glibc）裝的 → 掛進 Alpine 容器會爆 `Cannot find native binding`
- Alpine 裝的 → 拿回 host 跑也會爆，錯誤訊息一模一樣

所以 `cx npm --backend` 的容器路徑刻意用 **`node:24.20-bookworm-slim`（glibc）**
而不是 Alpine：bookworm 的 glibc 比 host 舊，編出來的模組在 host 上也能跑
（向前相容），反過來則不行。

前端則是完全隔離：容器裡的 `node_modules` 是具名 volume，由映像種子化，
跟 host 的 `frontend/node_modules` 是兩份，互不影響。

---

## 4. `cx db` 的原生路徑

容器路徑打的是 compose 的 mysql 容器；原生路徑打的是 `.env` 指到的那台 MySQL
（Ansible 部署出來的就是這種）。

### 連線設定的來源順序

1. 專案根的 `.env` —— 這個 repo 的真相（`cx setup env` 產生的隨機密碼在這裡）
2. `backend/.env` —— 真機部署的真相（Ansible 寫到 `shared/.env`）；**空值不算數**
3. `CX_DB_HOST` / `CX_DB_PORT` 環境變數 —— 臨時指定實際位置

第 2 步的「空值不算數」不是小事：Docker 開發環境裡 `backend/.env` 的
`DB_PASSWORD` 是**空的**（容器的密碼是 compose 注入的環境變數，不寫在那個檔），
少了這條規則就會拿到空密碼，而 MySQL 回的是

```
Access denied for user 'pm'@'...' (using password: NO)
```

看起來像密碼錯了，其實是根本沒帶密碼。

### `DB_HOST=mysql` 解析不到

`backend/.env` 記的是「容器眼中的世界」，`mysql` 是 compose 的 service 名，
host 上不存在。原生路徑會先檢查並講清楚，而不是讓 Laravel 丟一大串
vendor stack trace：

```bash
CX_DB_HOST=127.0.0.1 CX_DB_PORT=3306  cx --runner native db migrate   # dev 發布的埠
CX_DB_HOST=127.0.0.1 CX_DB_PORT=13306 cx --runner native db status    # test
```

真機部署時 `backend/.env` 本來就是 `127.0.0.1`，不需要覆寫。

### 密碼不進行程列表

- mysql client：用臨時的 `--defaults-file`（建立時就 `chmod 600`，用完立刻刪）
- artisan：用 **`export`** 而不是 `env DB_PASSWORD=... php`

`/proc/<pid>/cmdline` 是全機器可讀的，`/proc/<pid>/environ` 只有同一個使用者讀得到。

---

## 5. 實測結果（2026-09-04）

| 指令 | docker | native |
|---|---|---|
| `cx art` | ✔ | ✔ |
| `cx composer` | ✔ | ✔ |
| `cx npm`（frontend） | ✔ | ✔ |
| `cx npm --backend` | ✔ | ✔ |
| `cx test front` | ✔ | ✔ |
| `cx test back` | ✔ | 需要 `php8.5-sqlite3` |
| `cx db migrate` | ✔ | ✔ |
| `cx db status` | ✔ | 需要 `mysql-client` |
| `cx test coverage` | ✔ | 設計上只有容器路徑 |
| `cx db restore` | ✔ | 設計上只有容器路徑 |

強制語意也實測過：

| 情境 | 結果 |
|---|---|
| `--runner docker` + daemon 不可用 | rc=3，訊息指出「你指定了 --runner docker」 |
| `--runner native` + 缺工具 | rc=3，逐一列出缺哪些、各自怎麼裝 |
| `auto` + daemon 不可用 | 自動降級到 native，rc=0 |
| `--runner bogus` | rc=2 |

`cx --runner native db migrate` 是真的打到 MySQL 並回 `INFO Nothing to migrate.`
—— 用原生 PHP 的 pdo_mysql、根 `.env` 的密碼、透過 dev 容器發布的 3306。
