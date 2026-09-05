# 部署者指南

## 這份文件給誰看

給**要把這套系統放到真的伺服器上**的人。你的工作從「拿到一台或幾台 Ubuntu／Debian
機器」開始，到「網站在自己的網域上、用自己的憑證、跑得起來而且回得去上一版」為止。
你需要知道的是：兩條部署路徑各自負責什麼、主機怎麼分組、祕密放哪裡、
什麼指令會真的改機器、出事怎麼回滾。

寫程式的流程請看 [`guide-developer.md`](guide-developer.md)，
放行條件請看 [`guide-tester.md`](guide-tester.md)。
本文只寫「怎麼上線」與「為什麼是這樣」；
play 結構、12 個 role 的內部細節、MySQL 的五個坑在
[`ansible-reference.md`](ansible-reference.md)，
每個動詞的完整語法在 [`cx-reference.md`](cx-reference.md)。

> 本專案的文件規則是**沒跑過的就寫沒跑過**。
> 哪些東西真的在機器上跑過、哪些還沒，集中寫在 [§12](#12-已驗證與未驗證)。

---

## 1. 兩條部署路徑

這個專案有兩條會產出「正式構型」的路徑。它們**不是**互為備案，用途不同。

| | Docker `prod` 模式 | 原生 Ansible |
|---|---|---|
| 指令 | `cx prod up -d --build` | `cx deploy apply <限制>` |
| 產出 | 本機／CI 上的一組容器 | 目標主機上的 nginx + php-fpm + MySQL + PM2 |
| 原始碼 | **烘進映像**（沒有任何 bind mount） | `git clone` 到 `releases/<id>` |
| 對外埠 | 只發布 `80`（`EDGE_HTTP_PORT`） | nginx 的 80／443 |
| TLS | **沒有**。edge 沒有 `listen ssl` 區塊 | certbot（Let's Encrypt） |
| WAF | 無（prod overlay 沒有 waf 服務；`test` 模式才有） | nginx + ModSecurity + OWASP CRS |
| 管理工具 | 無 phpMyAdmin、不發布 MySQL 埠、xdebug 在 build 時被斷言擋掉 | 不裝管理工具 |
| 回滾 | 重建映像 | 換 `current` symlink（[§7](#7-回滾程序)） |

### 各自是拿來做什麼的

**Docker `prod` 模式**是「正式構型的可重現快照」。它的價值在於：原始碼烘進映像、
opcache 不驗證時間戳（`env/docker/php/zz-mode-prod.ini` 的
`opcache.validate_timestamps = 0` 加 `opcache.jit = tracing`，
改了容器內的檔案不會生效）、xdebug 被 build 斷言擋掉 —— 也就是說，
你在本機或 CI 跑起來的那一組容器，構型跟正式環境的意圖一致，
可以拿來確認「把原始碼凍住之後還跑得動」。
它**不是**用來對外服務的：`env/docker/compose/prod.yml` 刻意不發布 8443，因為 edge
沒有 TLS 監聽；發布了卻沒有 TLS，配上 `SESSION_SECURE_COOKIE=true` 會讓 Filament
登入陷入無限 419（cookie 只在 https 送出，CSRF token 永遠對不上）。

**原生 Ansible** 才是真的上線路徑。TLS、WAF、系統硬化、queue worker 的 systemd
unit、資料庫備份、release 保留與回滾，全部在這一邊。

### 為什麼兩邊的驗證結果可以互相參考

因為拓撲刻意做成一樣的：**edge（反向代理）在三個 Docker 模式都存在**，
原生那邊 nginx 也是同一個角色 —— `/` 給前端，
`/api`、`/admin`、`/up`、`/sanctum`、`/filament`、`/livewire-<hash>` 等前綴給 PHP
（完整清單是 `group_vars/all/main.yml` 的 `nginx_php_prefixes`；
`/storage` 不在裡面 —— 那是靜態檔，由 nginx 直接送）。
所以 `NUXT_PUBLIC_API_BASE_URL=""`（同源）在兩邊都是正確預設，
在 Docker 上驗過的路由行為，到原生上大致成立。

**大致成立不等於相同。** 兩邊 nginx 的逐項對照（哪些值一樣、哪些刻意不一樣）
在 [`nginx-reference.md`](nginx-reference.md) §2；
「Docker 好好的、上線就壞了」這類問題請從那份開始查。

---

## 2. 控制端的一次性準備

控制端是**你的電腦**，不是目標主機。

```bash
cx setup tools ansible        # 裝進 ~/.local/share/cx-venv，免 root
cx deploy galaxy              # 安裝 env/ansible/requirements.yml 列的 collections
```

`cx deploy galaxy` 在全新 clone 上是**必要**的：`ansible/collections/` 被
`.gitignore` 排除（那是 ansible-galaxy 下載的上游程式碼，不該進版控）。
少了它，`--syntax-check` 會失敗在
`couldn't resolve module/action 'community.general.timezone'` ——
那個訊息不會告訴你要跑 galaxy，所以 `cx deploy syntax` 會自己先檢查一遍並講清楚。

> 判斷 collection 是否安裝**不能**用 `ansible-galaxy collection list <名稱>` 的退出碼
> —— 實測即使 collection 不存在它也回 0。`bin/cmd/deploy.sh` 因此改成解析完整清單。

### SSH 與 known_hosts

`ansible.cfg` 的 `host_key_checking = True` 是刻意保留的。第一次連線前先：

```bash
ssh-keyscan -H <你的主機> >> ~/.ssh/known_hosts
```

目標主機被重建（換了 host key）時，ansible 只會把 ssh 那一大段
`REMOTE HOST IDENTIFICATION HAS CHANGED!` 包在
`UNREACHABLE! => {"msg": "…\r\n…"}` 的 JSON 裡丟出來，幾乎看不懂。
所以 `cx deploy` 的每一個需要真實主機的動詞，跑之前會先比對 `known_hosts`
與現場掃到的 key，不符就直接停下並印出那一行修法：

```
✘ known_hosts 裡的主機金鑰與目標現在的不符
    [127.0.0.1]:2222
        ssh-keygen -R '[127.0.0.1]:2222'
```

掃不到主機（機器沒起來）時**不會**誤報 —— 那種情況讓 ansible 說「連不上」比較清楚。

### become

`ansible.cfg` 是 `become_ask_pass = False`。所以登入帳號要嘛是 NOPASSWD sudo，
要嘛把 `ansible_become_password` 放進 vault。**不要**寫在 `hosts.yml` 裡。

### 不需要目標主機就能跑的兩件事

`cx deploy syntax` 與 `cx deploy lint` 會複製一份 inventory 到暫存目錄再跑，
`hosts.yml` 還不存在時會退而用 `hosts.yml.example`。所以這兩個在你連機器都還沒有
的時候就可以跑，也適合放進 CI。

> 不能直接把 `hosts.yml.example` 當 inventory 用：ansible 用**副檔名**挑解析器，
> `.example` 會走 ini plugin，得到 `Invalid host pattern '---'`。
> 所以它必須被複製成一個叫 `hosts.yml` 的暫存檔。

`cx verify ansible` 就是把上面兩者包成驗收項（`ans-syntax` / `ans-lint`），
沒裝 ansible 時回 SKIP 而不是 PASS。

---

## 3. 主機規劃

### 3.1 群組模型

來源是 `env/ansible/site.yml` 的 `roles` 區塊 —— 群組不是命名慣例，是**真的決定哪個
role 在哪台跑**的東西。

| 群組 | 誰在上面跑 |
|---|---|
| `pm_servers` | `site.yml` 的作用對象。**所有**主機都要在裡面（`common`、`hardening`） |
| `web_frontend` | `nodejs_pm2`、`deploy_frontend` |
| `web_backend` | `php`、`composer`、`deploy_backend`（**migration 在這裡**） |
| `web` | 上面兩者的 **`children` 聯集**。`nginx_myguard`、`certbot`、`healthcheck` 對它跑 |
| `db_primary` | `mysql`，而且**由它執行 `artisan migrate`**。剛好一台，必須也在 `web_backend` 裡 |
| `staging` / `production` | 環境群組。只負責套用 `group_vars/*.yml`，不影響 role 的執行與否 |

> **`web` 是 `children` 聯集，不是自己列 hosts。** 這是整個拆分能成立的關鍵 ——
> `site.yml` 裡既有的每一個 `groups['web']` gate 完全不用改，
> 單機拓撲（一台同時在兩個子群組裡）的行為 100% 不變。
> `cx deploy hosts` 產生的檔案就是這個形狀，`bin/test/70_project.bats` 有案例釘住。

**預設是單機**：`cx deploy hosts add <名稱> --ip <IP>` 加的第一台同時進
`web_frontend`、`web_backend` 與 `db_primary`。

### 3.2 A15：`db_primary` 剛好一台，而且必須也在 `web_backend`

migration 寫在 `deploy_backend` role 內部，gate 是：

```yaml
when: inventory_hostname in groups['db_primary']
```

**不是 `run_once`**，因為 `serial` 一旦不是 `100%`，`run_once` 的作用域就變成
「當前 batch」—— batch 1 跑一次、batch 2 再跑一次，兩次都宣稱自己是 run_once。

而 `deploy_backend` 只在 `web_backend` 群組執行。所以如果 `db_primary` 那台不在
`web_backend`，**migration 一次都不會執行，而且不會有任何錯誤訊息** ——
網站會停在 `Base table or view not found`。

`site.yml` 的 preflight play 有一條專門的斷言擋這件事，`cx deploy hosts check`
在還沒連線之前也會擋。兩道都有，是因為第二道的訊息比較早出現、比較便宜。

> ⚠ **那條斷言自己也寫著一個群組名。** 2026-09-06 把 `web` 拆開時，如果只改了
> role 的 gate 而忘了改斷言，斷言會**通過**，然後 migration 一次都不跑。
> `cx verify docs` 的 **`ANS-split`** 檢查專門盯這兩個群組名相不相同。

`db_primary` 也**不能超過一台**：gate 的對象必須唯一，兩台就會跑兩次 migrate。
這也是為什麼**一個 inventory 檔只能放一個環境**：`groups` 是「整份 inventory」的
視角，`--limit` 不會讓它變小。

### 3.3 前端與後端**可以**拆到不同主機（2026-09-06 起）

```bash
cx deploy hosts init --env production
cx deploy hosts add pm-fe-1 --ip 10.0.0.1 --no-be --no-db    # 只跑前端
cx deploy hosts add pm-be-1 --ip 10.0.0.2 --no-fe --be --db  # 跑後端與資料庫
cx deploy hosts check --ansible
```

> 這一節在 2026-09-06 之前寫著「**不能**拆」，並列出四個原因。
> 逐一查證之後，其中**兩個已經是變數了**（那份敘述過期了）：

| 原因 | 現況 |
|---|---|
| ① php-fpm 監聽 unix socket | **真的需要改** —— 但現在是 `php_fpm_listen` 這個變數 |
| ② 前端 PM2 綁 `127.0.0.1` | **已經是變數** `frontend_host`，而且完整接到 `HOST` 與 `NITRO_HOST` |
| ③ nginx 的 `fastcgi_pass` 與前端 upstream | **已經是變數** `nginx_fastcgi_pass` / `frontend_host` |
| ④ 網路、防火牆、FPM 沒有認證機制 | 真的是成本，見下 |

拆機必須設定的四個值：

```yaml
# group_vars/production.yml
php_fpm_listen: "0.0.0.0:9000"          # ① 從 unix socket 換成 TCP
php_fpm_allowed_clients: ["10.0.0.1"]   # ④ nginx 那台的內網位址
frontend_host: "10.0.0.1"               # ② Nitro 綁在別台連得到的介面上
nginx_fastcgi_pass: "10.0.0.2:9000"     # ③ nginx 指向後端那台的 FPM
hardening_ufw_allowed_tcp_ports: [22, 80, 443, 9000]   # ④ 放行 9000（限內網）
```

> ⚠ **第 ④ 點是真正的成本，不是設定的麻煩。**
> **FPM 對連進來的人不做任何驗證** —— 連得上 9000 就能以 `php_fpm_user` 的身分
> 執行 PHP。`listen.allowed_clients` 是唯一的存取控制，而且它是**取代**而非附加：
> 空清單在 FPM 的語意裡是「**允許所有來源**」，不是「拒絕所有」。
> 也就是說「忘記填」與「刻意開放」在設定檔上長得一模一樣。
> `php` role 有一條斷言會擋下「TCP 但 `allowed_clients` 為空」的組合，
> `cx deploy hosts check` 在分機拓撲下也會警告這兩個預設值。
>
> unix socket 之所以是預設，正是因為它天然只有同機可存取。**沒有要拆機就不要動它。**

**已驗證到哪裡**（本專案的規矩是「沒跑過的就寫沒跑過」）：

| 項目 | 狀態 |
|---|---|
| 群組解析（`web` 真的是兩個子群組的聯集） | ✅ `ansible-inventory --graph` 實測 |
| role gate 真的分開（fe 機 `backend=False`、be 機 `frontend=False`） | ✅ 條件求值實測 |
| `inventory.py` 的不變式與向後相容 | ✅ `bin/test/70_project.bats` 6 個案例 |
| `--syntax-check` / `ansible-lint` / `yamllint` | ✅ |
| **跨主機的 FPM / Nitro 實際流量** | ⬜ **未驗** —— 需要第二台真機 |

### 3.4 可以拆的是資料庫層### 3.4 資料庫層 —— `db_primary` 仍必須在 `web_backend` 裡

支援的拓撲是「多台 `web_backend`，其中一台**兼任** `db_primary`」：

```
web_backend = [pm-prod-be-1, pm-prod-be-2]
db_primary  = [pm-prod-be-1]        ← 這台同時跑 MySQL 與 artisan migrate
```

要讓 web-2 連得到資料庫，另外要處理（`hosts.yml.example` 檔尾有完整寫法）：

| 變數 | 為什麼 |
|---|---|
| `mysql_bind_address` | 預設 `127.0.0.1`，別台連不進來。改成內網位址 |
| `db_host` | 後端 `.env` 的 `DB_HOST`，要指到上面那個位址 |
| `mysql_app_user_hosts` | A3：`skip-name-resolve` 之下 MySQL 不做反解，比對的是**字面 host**。要加上 web-2 的內網 IP |
| `deploy_serial: 1` | 一台一台換，避免同時全掛（migration 不受影響 —— 它是群組 gate，不是 `run_once`） |
| `hardening_ufw_allowed_tcp_ports` | 開了 ufw 的話要放行內網 3306 |

「完全獨立的 DB 主機（不在 `web_backend` 裡）」目前**不支援**：那樣 migration 就沒有人跑。
真要做，得把 migration 拆成一個獨立的 play 讓 DB 主機執行 —— `site.yml` 的
A15 斷言訊息裡就寫了這個方向。

### 3.5 `cx deploy hosts` —— 產生與檢查 `hosts.yml`

`env/ansible/inventory/hosts.yml` 是 `cx deploy` 每一個需要主機的動詞都要用、卻
**不進版控**（含主機位址與帳號）的檔案。這組子指令是為了不必離開 cx 去手抄範例檔。

| 子指令 | 作用 | 參數 |
|---|---|---|
| `init` | 建立一個空的 `hosts.yml` | `--env staging\|production`、`--force`（檔案已存在時才需要） |
| `add <名稱>` | 加一台 | `--ip <IP>`（必填）、`--user`、`--port`、`--key`、`--env`、`--web` / `--no-web`、`--db` / `--no-db` |
| `rm <名稱>` | 移除一台 | |
| `show` | 列出主機與群組歸屬，並印出目前的問題 | |
| `check` | 只做驗證，有 `E` 級問題就回非 0 | `--ansible`（額外讓 `ansible-inventory` 自己剖析一次） |
| `edit` | 用編輯器直接開，存檔後自動跑一次 `check --ansible` | |

```bash
cx deploy hosts init --env production
cx deploy hosts add pm-prod-1 --ip 203.0.113.21 --user ubuntu
cx deploy hosts add pm-prod-2 --ip 203.0.113.22 --user ubuntu   # 第二台預設不是 db_primary
cx deploy hosts show
cx deploy hosts check --ansible
```

幾個從 `bin/lib/inventory.py` 讀出來、值得先知道的行為：

* **第一台預設同時是 `web` 與 `db_primary`**（單機拓撲，與 `hosts.yml.example` 一致）；
  之後加的預設只進 `web`。要改就用 `--db` / `--no-db` / `--no-web`。
* `add` / `rm` 是**重新產生整個檔案**，不是就地修補 —— 手寫的註解會消失
  （結構與值會保留）。換來的是三個群組不可能對不起來。要保留註解就用 `edit`。
* 產生出來的檔案**只會有一個環境群組**。`--env` 設定的是「這個檔案是哪個環境」，
  不是單台主機的屬性。這正好對應 §3.2 的「一個 inventory = 一個環境」。
* `cx deploy hosts` 只管 `env/ansible/inventory/hosts.yml` 這一個路徑，
  而 `ansible.cfg` 的 `inventory = ./inventory/hosts.yml` 也指著它。
  要同時管理兩個環境，就開兩個檔（`inventory/staging.yml`、`inventory/production.yml`）
  並自己帶 `-i` 跑 `ansible-playbook` —— 那條路 `cx deploy hosts` 幫不上忙。

`check` 會擋下的 **E 級**（會讓退出碼非 0）問題：

| 訊息 | 為什麼是致命的 |
|---|---|
| 沒有任何環境群組 | `group_vars/<env>.yml` 不會被套用 |
| 一台主機都沒有 | |
| 主機名不合法／重複 | 主機名會變成 `inventory_hostname`，被拼進路徑與 systemd unit 名 |
| 某台沒有 `ansible_host` | |
| `web` 是空的 | 不會有任何機器跑 nginx／php／前端 |
| `db_primary` 是空的 | migration 永遠不會執行 |
| `db_primary` 超過一台 | gate 的對象必須唯一 |
| `db_primary` 的成員不在 `web` | A15，見 §3.2 |

**W 級**（只提醒）：沒有 `ansible_user`（會用你目前的登入帳號）、
指定的私鑰檔不存在、`web` 超過一台（要另外處理 §3.4 那張表）。

---

## 4. 祕密

### 4.1 vault 的位置：`group_vars/all/vault.yml`，不是 `group_vars/vault.yml`

Ansible 把 `group_vars/<名字>.yml` 對應到「名為 `<名字>` 的群組」。
沒有叫 `vault` 的群組，所以 `group_vars/vault.yml` **永遠不會被載入，
而且不會有任何警告**。症狀是密碼像是沒設過：

```
mysql_root_password 未設定或長度不足 12 字元
```

你會去檢查 vault 的內容、檢查 vault 密碼，全部都是對的。

2026-09-04 對真實主機實測過三種放法：

| 放法 | 結果 |
|---|---|
| `group_vars/vault.yml` | ✘ vault 從未載入 |
| `group_vars/all.yml` + `group_vars/all/vault.yml` | ✘ 更糟：目錄會遮蔽同名的 `.yml`，vault 讀得到，但 `all.yml` 那 180 個變數整份消失 |
| `group_vars/all/main.yml` + `group_vars/all/vault.yml` | ✔ 兩邊都正確載入 |

所以本專案採**純目錄形式**：

```bash
cd ansible
ansible-vault create inventory/group_vars/all/vault.yml
ansible-vault edit   inventory/group_vars/all/vault.yml
```

### 4.2 vault 裡要有什麼

`inventory/group_vars/all/main.yml` 刻意**不給**這三個變數值，只在需要處以
`| default('')` 引用，讓對應 role 的 assert 能以清楚訊息擋下空值。

| 變數 | 用途 | 被誰讀 |
|---|---|---|
| `vault_mysql_root_password` | MySQL root 密碼 | `mysql_root_password` |
| `vault_mysql_app_password` | 應用帳號 `pm` 的密碼 | `db_password` / `app_db_password` |
| `vault_app_key` | Laravel `APP_KEY`（`base64:…`） | `app_key` |

密碼的硬性限制（來源：`env/ansible/roles/mysql/tasks/assert.yml`）：

* 長度 **≥ 12**（`mysql_password_min_length`，預設 12）；
* **不可含反斜線、雙引號、CR/LF**。理由不是潔癖：同一組密碼要同時寫進
  `/root/.my.cnf` 與 Laravel 的 `.env`，這三種字元在兩邊都沒有可靠的表達方式，
  與其寫一個猜測式的逸出，不如直接禁掉。assert 的訊息裡附了產生器：
  `openssl rand -base64 36 | tr -d '/+=\n'`。

`vault_app_key` **留空是正常且推薦的**：`shared/.env` 還沒有 `APP_KEY` 時，
`deploy_backend` 會跑一次 `artisan key:generate --force` 把它寫進去，之後永遠沿用。
`key:generate` 排在 `composer install` 之後（artisan 需要 `vendor/autoload.php`）。

> 一旦產生就不要換。`APP_KEY` 換掉會讓既有的加密欄位與 session 全部解不開。
> 要自己指定就在第一次部署**之前**填進 vault。

### 4.3 祕密在目標機上的唯一落點

`{{ app_root }}/backend/shared/.env`。`releases/<id>/.env` 是指過去的 symlink，
所以換版、回滾都不會動到它，也不會有第二份。

目錄權限是 `02750` / `02770`（setgid + 群組 `www-data`，others 一律 `0`），
再加一層 POSIX ACL —— 細節與「為什麼 setgid 不夠」見
[`ansible-reference.md` §6.6](ansible-reference.md)。

### 4.4 哪些檔案不進版控

`.gitignore` 已排除：`inventory/hosts.yml`、環境別的 `group_vars/staging.yml` 與
`group_vars/production.yml`、`.vault_pass`。
版控裡只有 `.example` 範本。**環境別的檔案本身也可能含祕密**
（`.example` 的檔頭就寫了整檔加密的做法）：

```bash
ansible-vault encrypt inventory/group_vars/production.yml
```

---

## 5. 部署流程

### 5.1 階梯

每一階都比上一階貴，也比上一階能發現更多東西。**不要跳階。**

```bash
cx deploy syntax              # 三個 playbook 的 --syntax-check（不需要主機）
cx deploy lint                # ansible-lint（production profile）+ yamllint（不需要主機）
cx deploy ping staging        # 確認 SSH 與 become 真的可用
cx deploy check staging       # --check --diff 乾跑
cx deploy apply staging       # ⚠ 真的部署
```

`[限制]` 是 `--limit` 的值（主機或群組樣式）。`check` 與 `vars` 不給就預設
`staging`；`apply` / `app` 不給就是**所有主機**，那時會先警告。

**全域旗標一律放在動詞之前：**

```bash
cx --yes deploy apply staging      # ✔
cx deploy apply --yes              # ✘ 會被 cx 擋下
```

擋下來是有原因的：`--yes` 放在後面會被當成主機樣式，而 ansible 對「比對不到任何
主機」只印 warning、退出碼 0 —— `apply` 會**安靜地什麼都不做卻回報成功**。

### 5.2 第二個之後的參數會原樣轉給 ansible

`check` / `apply` / `app` / `ping` 的第一個位置是限制，其餘原樣往下傳：

```bash
cx deploy check staging -e php_repo_source=distro
cx deploy check staging --tags php
cx deploy apply staging -e deploy_serial=1
cx deploy apply production -e mysql_app_password_update=always   # 輪替密碼，見 §10
```

`check` 與 `ping` 在轉發前會印一行 `額外參數：…`，所以看得出來有沒有真的傳下去。
`apply` / `app` / `rollback` **沒有**那一行 —— 要在動手之前確認參數真的接上了，
就先跑一次 `cx --dry-run deploy apply <限制> …`，`cx_run` 在 dry-run 之下會把
完整的 `ansible-playbook …` 指令原樣印出來。
（2026-09-04 之前這些參數會被安靜丟掉 —— 指令跑完、用的卻是預設值，
看起來像「`-e` 沒生效」。）

`serial` 與 `any_errors_fatal` **必須**用 `-e` 覆寫，寫在 `group_vars` 不保證有效：
它們是 play 層關鍵字，Ansible 建立 play 時就要決定，那時還沒有 host context。

### 5.3 `check` 能證明什麼、不能證明什麼

`--check` 之下 ansible 預設會**跳過**會寫入的 `command` / `shell`。
所以「乾跑通過」不等於「實跑會過」。反過來，唯讀探測都已標了 `check_mode: false`
（宣告 `changed_when: false` 原則上就要同時標它。刻意的例外有兩個：`pm2_ping`
會喚醒 PM2 daemon、`certbot_dry_run` 會打 ACME 伺服器，兩者實際有副作用，
所以不標 —— 見 [`ansible-reference.md` §6.4](ansible-reference.md)），
否則 `register` 出來的變數是空的，
下游 assert 會報出**指向完全錯誤方向**的訊息 —— 例如「APT 來源找不到 php8.5-fpm」，
但機器上明明裝好了。

2026-09-04 的一次全面清查補上 30 個 `check_mode: false`，
`cx deploy check` 從 **ok=70 failed=1** 變成 **ok=390 failed=0**。

`cx deploy lint` 與 `cx deploy check` 都通過，**仍然不代表可以上線**：
2026-09-04 把 `site.yml` 推到全綠的過程中修掉的八個缺陷，
沒有任何一個會被那兩者抓到，而且平均要跑到第 200 個 task 才碰到
（清單見 [`progress.md`](progress.md)）。唯一能證明的方式是對一台真的機器
`apply` 一次。

### 5.4 `apply` 的確認閘門

`apply` 與 `app` 會先解析出目標主機再問你：

```
playbook：site.yml
限制    ：staging
目標主機：pm-staging-1

這會實際修改上列主機：安裝套件、改系統設定、部署程式碼、可能執行資料庫 migration。
先跑過 cx deploy check staging 了嗎？
```

解析不出任何主機時**直接失敗**（`EX_PRECOND`），不會「沒事發生但回報成功」。
`cx --yes` 會跳過這個問句（並印一行 `[--yes] 自動確認：…`）。
`apply` / `app` / `rollback` 都會先取一個 `deploy` 專用的鎖，
另一個 cx 正在部署時第二個會被擋下。

### 5.5 `apply`（`site.yml`）與 `app`（`deploy-only.yml`）的差別

| | `cx deploy apply` | `cx deploy app` |
|---|---|---|
| playbook | `site.yml` | `playbooks/deploy-only.yml` |
| 涵蓋 | 12 個 role 全跑：preflight → 系統層（`common`…`certbot`）→ 應用層 → `hardening` | preflight + 系統層**存在性檢查** + `deploy_backend` → `deploy_frontend` → `healthcheck` |
| 前提 | 無 | `site.yml` 至少完整跑過一次 |
| 速度 | 慢 | 快很多 |

`deploy-only.yml` **不會安裝任何東西**。它的 pre_tasks 會實際 `stat` 一遍
`app_root`、`releases`、`shared`、`php` CLI、`composer`、`node`、`npm`、`pm2`，
缺任何一項就以「請先跑一次完整的 `site.yml`」fail fast，
而不是讓 `composer install` 在幾分鐘後莫名其妙失敗。
它還會再驗一次 PHP CLI 有沒有 `proc_open`（A2）—— 那個檢查 0.1 秒，
比讓 composer 跑到 `post-autoload-dump` 才死划算太多。

**下列情況必須用 `apply` 而不是 `app`**（來源：`deploy-only.yml` 檔頭）：

* 改了任何 `php_*` / `nginx_*` / `waf_*` / `mysql_*` / `pm2_*` 設定變數；
* 改了 `frontend_mode`（模式切換要 nginx 與 PM2 一起換）；
* 改了 `app_max_upload_mb`（A16：四個值要一起重新推導）；
* 憑證第一次簽發之後（要把 vhost 從 snakeoil 切到正式憑證，見 §8.1）。

### 5.6 除錯用的三個唯讀動詞

| 想知道 | 指令 |
|---|---|
| 我設的值到底有沒有生效 | `cx deploy vars <限制>`（`ansible-inventory --list --yaml`） |
| 目標機的 facts | `cx deploy facts <主機>` |
| SSH／become 通不通 | `cx deploy ping <限制>` |

### 5.7 退出碼

| 碼 | 常數 | 什麼時候 |
|---|---|---|
| 0 | `EX_OK` | 成功 |
| 1 | `EX_FAIL` | `lint` 有 finding；`hosts check` 有 E 級問題 |
| 2 | `EX_USAGE` | 未知子指令；第一個位置放了旗標；`facts` 沒給主機名 |
| 3 | `EX_PRECOND` | 沒有 ansible／缺 collection／缺 `hosts.yml`／host key 不符／解析不出目標主機 |
| 4 | `EX_ABORT` | 你在確認閘門選了不要 |

> ⚠ 上表只涵蓋 **cx 自己**判斷出來的失敗。playbook 真的跑起來之後失敗時，
> cx **不重新映射**退出碼，`ansible-playbook` 的碼會原樣透出 ——
> 實測「有主機失敗」是 **2**、「主機連不上」是 **4**，
> 正好與 `EX_USAGE` 和 `EX_ABORT` 撞號。
> 所以 CI 上不能用「rc == 1 才算部署失敗」來判斷，要用 `rc != 0`。

---

## 6. release / symlink 模型

### 6.1 佈局

根目錄是 `app_root`，預設 `/srv/{{ app_slug }}`（**不是** `/var/www`）。
前後端是**兩棵各自獨立的 release 樹** —— 兩者的部署節奏本來就不同
（後端要跑 migration，前端要 build），綁在同一個 release id 底下會讓
「只重新部署前端」變成不可能。

```
/srv/pm/
├── shared/                       共用（pm2/ecosystem.config.cjs 等）
├── backend/
│   ├── releases/<release_id>/
│   ├── shared/                   .env、storage/   ← 唯一的祕密所在
│   └── current -> releases/<release_id>
└── frontend/
    ├── releases/<release_id>/
    ├── shared/
    └── current -> releases/<release_id>
```

`release_id` 由**控制端**算一次（`YYYYMMDD-HHMMSS`），不是每台主機各算各的 ——
`ansible_date_time` 是每台主機自己的時間，秒針一跨過去 backend 與 frontend
就會落在不同的 release 目錄，rollback 也沒有共同的 id 可以指。

> ⚠ 不要把 `app_root` 設成 `/srv` 或 `/var/www`。preflight 會斷言它是絕對路徑、
> **深度 ≥ 2**、不在系統目錄黑名單內，而且 releases / current 每一條路徑都必須位於
> 它底下 —— prune 與 rollback 都以這些路徑為根做檔案操作。

### 6.2 換版是原子的

`ln -sfn new current` **不是**原子的：coreutils 對已存在的目標會先 unlink 再
symlink，中間有一個 `current` 不存在的視窗，落在那一瞬間的請求會拿到 404/500。
正確做法是先建一個臨時 symlink，再用 `mv -T` 覆蓋過去（`rename(2)`，同檔案系統上原子）。
`ansible.builtin.file: state=link force=yes` 同樣是兩步，也有那個視窗。

換版排在 composer、migration、快取**全部成功之後** ——
任何一步失敗時 `current` 都還指著上一個能跑的版本。

`current` 若存在但**不是** symlink（是真的目錄），role 會停下來要人工處理，
不會自動刪掉：那可能是別人手動放的線上程式碼。

### 6.3 release 是不可變產物

`releases/<release_id>` 一旦**材料化**（後端是 `.git` 與 `artisan` 都在，
前端是 `.git` 與 `package.json`），就**不再重新 clone**，改為讀出既有的 commit。

為什麼：clone 之後還有 `composer install`（寫 `vendor/`）、`.env` 與 storage 的
symlink，於是那個工作目錄對 git 而言必然是 dirty。用**同一個 release_id** 再跑一次，
`ansible.builtin.git` 會直接失敗：

```
Local modifications exist in the destination: /srv/pm/backend/releases/<id> (force=no)
```

平常 `release_id` 是每次新的時間戳，所以沒有人踩到。但「用同一個 id 重跑」正是
**部署失敗後想重試**時最自然的動作 —— 而那個情境原本是壞的（2026-09-05 實測，
記為 W-2）。

> 用 `force: true` 修是錯的：那會默默丟掉這個 release 已經做過的工作。

要強制重新 clone，就刪掉那個 release 目錄，或換一個 `release_id`：

```bash
cx deploy app staging -e release_id=20260905-120000
```

### 6.4 prune：為什麼不是 `ls | tail | rm -rf`

`deploy_backend/tasks/prune.yml`（前端同構）。這條規則叫 A1，
擋的是兩個具體的災難：

| 天真的寫法 | 會發生什麼 |
|---|---|
| `ls -1dt releases/*/ \| tail -n +N \| xargs rm -rf` | 按 **mtime** 排序又不排除 `current`。回滾之後 `current` 指的是「比較舊」的那一個，下一次部署它就掉到清單尾巴 —— **正在服務的版本被刪掉** |
| 同上，但變數渲染成空字串 | 作用範圍塌成 `rm -rf /*/` |

實際做法是七道關卡：

1. `stat`（`follow: false`）解析 `current` 的實體路徑，連同本次 release 一起放進保護名單；
2. `ansible.builtin.find` 只掃 releases 底下深度 1 的目錄，不用 shell glob；
3. 依 ctime 由新到舊排序，保留 `keep_releases - 1` 個（`current` 佔掉一個額度）；
4. 單次刪除數量有上界（`backend_prune_max_delete`，預設 20）；
5. 每一項刪除都有 `when` 逐條把關：必須在 releases 底下、父目錄**剛好**是 releases、
   basename 符合 release_id 的正則、且不在保護名單內；
6. 用 `ansible.builtin.file: state=absent`，不是 shell 的 `rm`；
7. releases 清單為空時 loop 是空的，什麼都不會發生。

`assert` 另外確保 `keep_releases >= 2`，所以切片起點至少是 1
（`[0:]` 等於把所有非 current 的 release 全刪）。

| 旋鈕 | 預設 | 說明 |
|---|---|---|
| `releases_keep` / `keep_releases` | 5（`staging.yml.example` 是 3） | 保留幾個。preflight 要求 ≥ 2 —— rollback 至少需要上一版 |
| `releases_prune` | `true` | 總開關；role 內是 `backend_prune_enabled` / `frontend_prune_enabled` |
| `backend_prune_max_delete` | 20 | 單次上界；超過的下次再清（會印出來） |

關掉 prune 時 role 會提醒還有幾個舊 release 佔著磁碟 ——
preflight 要求至少 5 GB 可用空間，長期不清會撐爆。

---

## 7. 回滾程序

### 7.1 兩個模式，兩道閘門

`cx deploy rollback` 跑的是 `playbooks/rollback.yml`，它有兩層閘門，
而 `cx --yes` **只能穿過第一層**（cx 自己的確認），第二層在 playbook 內：

| 沒帶什麼 | 會發生什麼 |
|---|---|
| 沒帶 `-e rollback_to=<id>` | **只列出可用的 release 就結束**（rc=0，什麼都不改）。這是「先看看有哪些」模式 |
| 沒帶 `-e rollback_confirm=true` | playbook 內的 `pause` 會要求打字輸入 `yes`；非互動環境沒有輸入 → 中止且不改任何東西 |

```bash
# 1) 先看有哪些可以回（不改任何東西）
cx deploy rollback staging

# 2) 互動式回滾（會停下來要你打 yes）
cx deploy rollback staging -e rollback_to=20260903-181200

# 3) 非互動 / CI 的完整寫法
cx --yes deploy rollback staging -e rollback_to=20260903-181200 -e rollback_confirm=true
```

> ⚠ `rollback` 的**第一個位置參數一律被當成 `--limit`**，而且不像 `check` / `apply`
> 會擋旗標。所以 `cx deploy rollback -e rollback_to=X` 會變成
> `--limit -e`，行為不是你要的。**`-e` 之前一定要先給一個限制。**
> 不指定限制時 playbook 自己的 `hosts` 預設是 `web` 群組。

### 7.2 其他參數

| 參數 | 預設 | 作用 |
|---|---|---|
| `-e rollback_component=backend\|frontend\|both` | `both` | 只回其中一邊 |
| `-e rollback_hosts=<樣式>` | `web` | playbook 的 `hosts`（與 `--limit` 不同層） |
| `-e rollback_restart_services=false` | `true` | 只換 symlink，不碰服務（極少用；換完要自己 reload） |
| `-e rollback_healthcheck=false` | `true` | 跳過回滾後的健康檢查 |

### 7.3 它會做什麼、不會做什麼

**會做**：換 symlink（同樣的 `ln` + `mv -T` 原子換位，以 `deploy` 身分執行）→
reload php-fpm → 重啟 queue worker → `pm2 startOrReload` + `pm2 save`（ssr/spa）→
`nginx -t` + reload → 就地驗證（symlink 指向、`public/index.php` 存在、
直連 Nitro 的埠）→ 重跑 `healthcheck` role。

php-fpm 一定要 reload：FPM worker 有 realpath cache（`realpath_cache_ttl` 預設 600 秒），
不 reload 的話最長 10 分鐘內還會解析到舊的 release 路徑；OPcache 的 key 也是 realpath。
queue worker 是長駐的，會把程式碼載在記憶體裡，換版後不重啟會繼續跑舊的 Job 類別，
而且錯誤訊息完全看不出原因。

**不會做**：

* **不刪任何東西。** 舊 release 原封不動，所以「回滾之後再回滾回去」永遠可行。
  清理是 deploy role 的 prune 負責。
* **不回滾資料庫。** `artisan migrate` 是單向的。如果被回滾掉的那一版帶了 migration，
  舊程式碼會對著新 schema 跑。多數情況（新增欄位、新增資料表）沒事，
  但**改欄位型別 / 刪欄位 / 改欄位名**就會壞。
  回滾前先看 `backend/database/migrations` 的差異，必要時手動處理。
  確認提示會再提醒一次。

它在動手之前有四道 gate：`rollback_to` 的格式（會被拼成目錄名）、目標 release
必須真的存在且是目錄、目前的 `current` 必須是指向 releases 底下的 symlink、
目標與現況相同時直接告訴你沒有東西需要回滾。

### 7.4 遇到「migration 已經跑了、程式碼要退回去」

沒有自動路徑。可用的素材是 migrate **之前**自動做的那份 mysqldump：
`deploy_backend` 在 `db_primary` 上、`backend_migrate` 與
`backend_backup_before_migrate` 都開著時，會先備份到
`/var/backups/{{ app_slug }}-premigrate/`（`0700`，認證走 `--defaults-file`，
命令列上沒有機密；先寫 `.part` 再 `mv`，中途失敗不會留下半截備份）。
還原是人工動作，請自行評估資料是否已經被新版寫過。

---

## 8. TLS

### 8.1 A5：snakeoil bootstrap 與第一次部署的正常中間狀態

`nginx_myguard` 排在 `certbot` **之前**（certbot 用 webroot 模式，需要 nginx 已經
在服務 :80）。於是 vhost 一定會在「正式憑證還不存在」的情況下被寫出來。

如果 vhost 直接引用 `/etc/letsencrypt/live/<domain>/fullchain.pem`，`nginx -t` 會
emerg，而 `any_errors_fatal: true` 會讓 certbot **永遠跑不到** —— 憑證永遠不會出現。
**死結。**

解法不是關掉 `any_errors_fatal`，而是讓 nginx role 用 `ssl-cert` 套件的 snakeoil
憑證開機（`/etc/ssl/certs/ssl-cert-snakeoil.pem`），再用 `stat` 判斷正式憑證是否
出現、出現了才引用它。

**所以第一次部署結束時，「憑證已經簽好、但 nginx 還指著 snakeoil」是正常的中間狀態。**
`site.yml` 的 post_tasks 會用 `nginx -T`（dump 實際載入的設定，不是讀檔）偵測並提醒。
修法是再跑一次 nginx 那一段：

```bash
cd ansible && ansible-playbook site.yml --tags nginx
```

（或 `cx deploy apply staging --tags nginx`。）

### 8.2 先用 Let's Encrypt staging 端點

`certbot_staging: true` 會用 staging 端點：憑證不被瀏覽器信任，但**不吃正式的
速率限制**。`staging.yml.example` 預設就是 `true`，流程跑通之後再改 `false` 重跑
`--tags certbot`。

`healthcheck_validate_certs` 會自己推導成
`tls_enable and not certbot_staging`，不需要手動關。

### 8.3 必填與常見失敗

`tls_enable: true` 時 `certbot_email` **必填**，而且 `site.yml` 的 preflight play
會在 5 秒內擋下 —— 不擋的話要跑到最後的 certbot role 才失敗，
那時 PHP / MySQL / Node / nginx 都已經裝完了。
Let's Encrypt 用這個 email 寄「憑證即將到期 / 續期失敗」通知；沒有它，
自動續期一旦壞掉不會有人知道，直到憑證過期。

簽發失敗時 role 會列出三種最常見的原因，並用 `★` 標出從輸出判斷命中的那一個：
DNS 沒有指過來（LE 是從它自己的伺服器解析、不是從你這台機器）、
80 埠不通或 webroot 對不上（HTTP-01 只走 80 埠）、撞到速率限制。

> 純內網、沒有公開網域的環境請設 `tls_enable: false`，
> nginx 會維持 snakeoil 憑證或純 HTTP。

### 8.4 HSTS 預設關閉

`tls_hsts_enabled: false`。一旦送出，瀏覽器端在 `max-age` 內就再也不能用 http
存取這個網域，也會拒絕憑證有問題的 https，而且**沒有辦法從伺服器端撤銷**。
確認「自動續期已經成功跑過至少一輪」之後再打開。

---

## 9. WAF：`DetectionOnly` → `On`

nginx + ModSecurity + OWASP CRS 由 `nginx_myguard` role 負責。
規則載入順序、排除規則怎麼寫、怎麼量它有沒有在做事，寫在
[`nginx-reference.md` §3](nginx-reference.md)。這裡只講**上線的順序**。

### 9.1 兩個獨立的開關

| 變數 | `all/main.yml` 的值 | 意思 |
|---|---|---|
| `waf_enabled` | `true` | 是否安裝並載入整套 WAF。`false` 時 `waf.yml` 整段跳過 |
| `waf_rule_engine` | `DetectionOnly` | `On` 才會真的擋；`DetectionOnly` 只寫 audit log |

### 9.2 建議的進程

1. **staging 用 `DetectionOnly` 跑一段時間**（`staging.yml.example` 就是這個設定）。
   staging 就是拿來收誤判的地方。
2. 從 `{{ waf_audit_log }}`（預設 `/var/log/nginx/modsec_audit.log`）撈出被命中的
   rule id。**一定要從這台機器的 audit log 撈，不要抄別人的** ——
   憑空猜 id 只會關掉不該關的規則。
3. 把排除規則寫進去（見 §9.3 的陷阱）。
4. 確認乾淨之後，才在 production 設 `waf_rule_engine: "On"`。

直接上 `On` 的典型後果：Filament 的表單送出（大量 JSON + base64）被 CRS 的
941xxx / 942xxx 判成攻擊，**後台整個不能用**，而且沒有任何線索指向 WAF。

### 9.3 ⚠ 不要在 `group_vars` 寫 `waf_exclusions_before: []`

inventory 的 `group_vars` 優先權**高於** role defaults。
`roles/nginx_myguard/defaults/main.yml` 裡有 5 條針對 Livewire / Filament
研究過的排除規則（id 10010–10014）。一旦在 `group_vars` 寫
`waf_exclusions_before: []`，那 5 條會被整組清掉 —— 而且通常正好發生在你把
`waf_rule_engine` 切成 `On` 的同一刻。

所以 `all/main.yml` 與 `production.yml.example` 都**刻意不定義**這個變數。

要**新增**自己的排除規則，正確做法是直接編輯
`roles/nginx_myguard/defaults/main.yml` 的 `waf_exclusions_before`，
把你的規則附加到既有的 5 條後面 —— Ansible 對 list 沒有合併機制，
這是唯一不會弄丟既有規則的做法。
要**關掉**內建排除規則才在 `group_vars` 寫 `[]`（並想清楚為什麼）。

`waf_exclusions_after` 預設空也是刻意的：`SecRuleUpdateTargetById` 引用不存在的
規則 ID 會在**載入期**就讓 nginx 起不來，一定要先用 `DetectionOnly` 收 audit log
確認 ID 之後再填。

### 9.4 `On` 之後才會跑的那個驗證

`nginx_myguard` 的 `verify.yml` 有一項「WAF 阻擋測試」：帶一個攻擊特徵
User-Agent 打自己，斷言回 **403**（CRS 913100）。
這一項的 `when` 條件包含 `waf_rule_engine == 'On'` ——
**`DetectionOnly` 之下它不會執行**（DetectionOnly 本來就不回 403）。
也就是說，切到 `On` 的那一次部署，才是這個檢查第一次真的跑。

要暫時停用 WAF：`waf_enabled: false`，或 `waf_rule_engine: DetectionOnly`。

---

## 10. 冪等性：`changed=0` 不是這裡的目標

2026-09-05 對目標機釘死 `release_id` 連跑同一份 playbook 量測冪等性
（不釘死的話 `release_id` 每次都是新的時間戳，deploy role 本來就會 changed）：

| 輪次 | changed | 說明 |
|---|---|---|
| 全新機第一次 | 127 | `failed=0`、533 個 task |
| 修 W-1..W-9 之前的第二次 | 16 + **failed=1** | 失敗的就是 W-2（同一個 release_id 重跑） |
| 修完之後 | **9**，連兩次相同 | 已收斂 |

剩下的 9 項**全部是「每次部署本來就要做事」**，不是缺陷：

| 項目 | 為什麼每次都會 changed |
|---|---|
| migrate 前的 `mysqldump` | 每次部署都要有一份可還原的備份 |
| `config:cache` / `view:cache` / `event:cache` / `filament:optimize` | 快取是對「這一個 release 路徑」建的，換版就要重建 |
| `npm ci` | 前端的相依安裝 |
| Nuxt 建置 | 產物在新的 release 目錄裡 |
| `pm2 startOrReload` | 讓 PM2 跑到新的 `current` |
| `pm2 save` | 讓開機 resurrect 的內容與現況一致 |

判斷原則：**基礎設施收斂的部分要冪等，重新部署的部分不該冪等。**
所以看到 `changed≈9` 是正常的；看到 `changed=16` 或更多，
就值得去看是哪一個系統層 task 在每次部署都謊報。

那 9 個缺陷（W-1..W-9）的完整清單與成因在
[`progress.md`](progress.md) —— 幾乎每一個都是「`changed_when` 的判斷式恆真」，
例如 `'CHANGED' in stdout` 而實際輸出是 `UNCHANGED`（子字串包含恆真），
或 `find … -delete` 不論有沒有刪到都回 0。

### 一個副作用：資料庫密碼預設不再每次重設

`mysql_root_password_update` 與 `mysql_app_password_update` 的預設值是 **`on_create`**
（不是 `always`）。原因是 `mysql_user` 在使用 `plugin_auth_string` 時，
MySQL 存的是加鹽雜湊，模組**沒有辦法**比對明文與雜湊 ——
`always` 的實際效果是「每次部署都重設一次密碼」，永遠不會冪等。

代價是**改了 vault 裡的密碼不會自動套用到既有帳號**。要輪替時明確覆寫：

```bash
cx deploy apply production -e mysql_app_password_update=always
```

這是刻意的取捨：讓輪替變成一個明說的動作，而不是每次部署的副作用。

---

## 11. 上線前檢查清單

### 11.1 控制端

```bash
cx deploy hosts check --ansible      # 群組模型 + A15 + 讓 ansible 自己剖析一次
cx deploy syntax                     # 三個 playbook
cx deploy lint                       # ansible-lint（production profile）+ yamllint
```

- [ ] `cx deploy galaxy` 跑過（全新 clone 必要）
- [ ] `env/ansible/inventory/hosts.yml` 只有**一個**環境群組
- [ ] `db_primary` 剛好一台，而且也在 `web` 裡
- [ ] `group_vars/all/vault.yml` 存在，且路徑是 `all/` 底下（§4.1）
- [ ] `vault_mysql_root_password` / `vault_mysql_app_password` ≥ 12 字元，
      不含反斜線、雙引號、換行
- [ ] `group_vars/production.yml`（或 `staging.yml`）已從 `.example` 複製並填過，
      含祕密的話整檔加密
- [ ] `ssh-keyscan` 過，`cx deploy ping <限制>` 通

### 11.2 目標主機（preflight 會擋的硬條件）

| 條件 | 門檻 | 來源 |
|---|---|---|
| 作業系統 | Ubuntu 24.04 / 26.04，或 Debian 12 / 13 | `preflight_supported_ubuntu_versions` / `preflight_supported_debian_versions` |
| CPU 架構 | **amd64（x86_64）** —— MyGuard 的 apt 來源行寫死 `arch=amd64` | 要放寬設 `preflight_allow_non_amd64: true` |
| 可用磁碟 | ≥ 5120 MB | `preflight_min_free_disk_mb` |
| RAM + swap | ≥ 1800 MB（Nuxt 4 的 build 尖峰約 1.5 GB） | `preflight_min_total_mem_mb` |
| 控制端 ansible-core | ≥ 2.17.0 | `preflight_min_ansible_version` |
| MySQL 來源 | `mysql_repo_source: oracle` —— 發行版的 `mysql-server` 是 8.0.x，Debian 的 `default-mysql-server` 根本是 MariaDB | A4 |
| PM2 模式 | 只能 `fork`；`pm2_instances` 必須等於 `frontend_instances` | A10 |

### 11.3 網域與 TLS

- [ ] `app_domain` 的 A / AAAA 記錄已經指到這台機器（HTTP-01 需要）
- [ ] 從**外部** `curl -I http://<網域>/` 通得了（80 埠、雲端安全群組、ufw）
- [ ] `certbot_email` 是有效 email
- [ ] 先用 `certbot_staging: true` 成功跑過一次，再改 `false`
- [ ] 第一次部署後看到「還在用 snakeoil」的提醒時，補跑 `--tags nginx`（§8.1）
- [ ] HSTS 先不要開（§8.4）

### 11.4 部署當下

- [ ] `cx deploy check <限制>` 乾跑過，並且**知道**它證明不了什麼（§5.3）
- [ ] `cx deploy apply <限制>` 的確認畫面上，目標主機清單跟你想的一樣
- [ ] `PLAY RECAP` 的 `failed=0`
- [ ] `healthcheck` role 三層都過：origin（直連 PM2 埠）、
      edge（`127.0.0.1` + Host 標頭）、app（公開網址的 `/up`、`/`、`/admin`）
- [ ] systemd unit 都 active：`nginx`、`php<版本>-fpm`、`mysql`、
      `<slug>-queue@N`、`<slug>-schedule.timer`、`pm2-deploy`

三層健康檢查是刻意分開的：直接打 Nitro 的埠可以區分「前端本身掛了」和
「nginx / 憑證設定有問題」。

### 11.5 硬化（`hardening` role）

**全部旋鈕預設關閉**，而且 role 排在最後 —— ufw / fail2ban / sshd 任何一項設錯
都可能把控制端擋在門外，放最後至少保證前面的部署已經完成。

打開的順序（`production.yml.example` 的建議）：
`sshd`（先確認公鑰能登入）→ `ufw`（確認 22 在放行清單）→
`fail2ban`（先放行控制端 IP）→ `sysctl`。
**一項一項來，每打開一項就先 `check`，套用後立刻另開一個 ssh 連線確認還進得去。**

`ansible.cfg` 的 `force_handlers = False` 是刻意的，服務於同一件事：
`hardening/sshd` 的流程是「寫入片段 → 立刻 `sshd -t` 驗證 → 失敗就 rescue 移除並中止」。
中止時 handler **不可以**執行，否則會拿著壞掉的設定去 restart sshd。

---

## 12. 已驗證與未驗證

本專案的規則是**沒跑過的就寫沒跑過**。以下是這條路徑目前的真實狀態。

### 跑過的

`site.yml` 在 `docker/ansible-target` 容器上**完整實跑**過
（不是 `--check`）。那個容器跑真的 systemd、sshd、sudo，
`systemd_service` 模組、handler、服務啟動順序全部是真的。

| 目標 | PHP 來源 | 結果 |
|---|---|---|
| Ubuntu 24.04 (noble) | `ondrej` → 8.5.10 | ok=498 changed=119 **failed=0** |
| Ubuntu 26.04 (resolute) | `distro` → 8.5.4 | ok=491 changed=116 **failed=0** |

兩邊都驗到 `php8.5-fpm` / `nginx` / `mysql` active、`/up` 與 `/admin/login` 回 200、
PM2 的前端 online、ACL 雙向交叉寫入可行。
打開 `waf_enabled` 之後又跑通一輪（533 個 task、`failed=0`）。

另外實測過的：冪等性（§10）、release prune 不刪 `current`
（完整走過「部署三次 → rollback 到**最舊**的那個 → 再部署一次」，
`/up` 全程 200、沒有懸空 symlink）、CRS 排除規則的載入順序、安全標頭的繼承。

### 沒跑過的

| 項目 | 為什麼還不算數 |
|---|---|
| **certbot 真的簽發一張憑證** | 驗證容器沒有公開網域，`tls_enable` 是關的。A5 的 snakeoil → 正式憑證切換**只在程式碼層面驗過**，沒有在全新機上實際觀察過 |
| **多主機 `serial` 滾動部署** | 需要兩台以上的目標機。`deploy_serial` 的行為只有單機路徑驗過 |
| **真實雲端主機**（非容器）上的 MySQL 8.4 Oracle repo / PHP 8.5 PPA 安裝 | 容器與雲端映像的套件基底不同（例如 `universe` 是否開啟） |
| **`web` 多台的拓撲**（§3.4 那張表） | 從來沒有部署過 |
| **Sanctum 完整登入流程、Filament 後台的實際操作** | 端點回應驗過，但沒有真的走完一次登入 |

最新狀態一律以 [`progress.md`](progress.md) 為準 ——
那份是「還沒驗證什麼」的正本，本節只是摘要。

---

## 13. 出事的時候

| 症狀 | 先看哪裡 |
|---|---|
| `apply` 回報成功但什麼都沒做 | [`troubleshooting.md`](troubleshooting.md) §Ansible。多半是旗標放錯位置（§5.1） |
| MySQL 執行期設定與預期不符 / TCP 登入失敗 / 第二次部署才出現的 `dict has no attribute` | [`ansible-reference.md` §7](ansible-reference.md) 的五個坑 |
| `cx deploy check` 報「APT 找不到 php8.5-fpm」但機器上明明有 | [`ansible-reference.md` §6.4](ansible-reference.md)：唯讀探測缺 `check_mode: false` |
| Docker 上好好的、上線就壞了 | [`nginx-reference.md` §2](nginx-reference.md) 的逐項對照 |
| WAF 擋掉了不該擋的 | [`nginx-reference.md` §3](nginx-reference.md)，並先切回 `DetectionOnly` |
| 某個變數到底生效沒有 | `cx deploy vars <限制>` |
| 某個 task 為什麼被略過 | `ansible.cfg` 的 `display_skipped_hosts` 改成 True |
| 只想重跑某一段 | `cx deploy apply <限制> --tags <mysql\|php\|nginx\|certbot\|deploy\|hardening\|preflight>` |

`cx deploy` 的完整動詞表在 [`cx-reference.md`](cx-reference.md)；
play 結構、12 個 role 的順序與理由在 [`ansible-reference.md`](ansible-reference.md)；
目標主機端的原生部署細節（nginx 路由、PM2 為什麼是 fork、MyGuard 套件名歧異）
在 [`../env/ansible/README.md`](../env/ansible/README.md)。
