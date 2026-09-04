# Ansible 參考

> 原生部署（不用 Docker）：Ubuntu 24.04 / 26.04 + nginx + PHP-FPM + MySQL 8.4 + PM2。
> 上真機之前先讀這份，尤其是 §2 的執行位置與 §3 的 vault。

---

## 1. 入口一律是 `cx deploy`

```bash
cx deploy galaxy            # 裝 collections
cx deploy syntax            # --syntax-check（三個 playbook）
cx deploy lint              # ansible-lint（production profile）+ yamllint
cx deploy ping staging      # 確認 SSH 與 become
cx deploy check staging     # --check --diff 乾跑
cx deploy apply staging     # ⚠ 真的部署
```

`[限制]` 是 `--limit` 的值。**全域旗標要放在動詞之前**：

```bash
cx --yes deploy apply staging      # ✔
cx deploy apply --yes              # ✘ 會被當成主機樣式
```

寫錯的話 cx 直接擋下來。不擋的話 ansible 對「比對不到任何主機」只印 warning、
退出碼 0 —— `apply` 會安靜地什麼都不做卻回報成功。

---

## 2. 執行位置與 `ansible.cfg`

**一律在 `ansible/` 目錄底下執行。** `cx deploy` 已經幫你 cd 好了。

`ansible.cfg` 裡三個值得記住的設定：

### collections_path 要把預設路徑列回來

```ini
collections_path = ./collections:~/.ansible/collections:/usr/share/ansible/collections
```

`collections_path` 是**取代**而不是附加。只寫 `./collections` 會讓
`ansible-galaxy collection install -r requirements.yml`（預設裝到
`~/.ansible/collections`）安裝的東西全部變成找不到。

### force_handlers = False（不要改）

`hardening/sshd` 的流程是「寫入片段 → 立刻 `sshd -t` 驗證 → 失敗就 rescue 移除並中止」。
中止時 handler **不可以**執行，否則會拿著壞掉的設定去 restart sshd，
把自己鎖在門外。

### host_key_checking = True（不要改）

第一次連線請先 `ssh-keyscan -H <host> >> ~/.ssh/known_hosts`。

---

## 3. 變數與 vault

```
ansible/inventory/
├── hosts.yml                    ⚠ 不進版控
├── hosts.yml.example
└── group_vars/
    ├── all/                     ← 目錄形式，不是 all.yml
    │   ├── main.yml             通用預設（進版控）
    │   └── vault.yml            ⚠ 祕密，ansible-vault 加密
    ├── staging.yml              ⚠ 不進版控
    ├── staging.yml.example
    └── production.yml.example
```

### 為什麼 group_vars/all/ 一定要是目錄

`group_vars/<名稱>.yml` 對應的是一個**群組**。要同時有明文與加密兩個檔，
就必須用目錄形式 `group_vars/all/{main.yml,vault.yml}` ——
Ansible 會把目錄裡所有檔案都讀進來。

寫成 `group_vars/all.yml` + `group_vars/vault.yml` 的話，
後者對應的是一個叫 `vault` 的群組（不存在），於是**整個檔案不會被讀取**，
所有 `vault_*` 變數都是 undefined，而預設值 filter 會讓它變成空字串 ——
MySQL 用空密碼建帳號，不報錯。

### vault 裡有什麼

| 變數 | 用途 |
|---|---|
| `vault_mysql_root_password` | MySQL root 密碼（≥ 12 字元） |
| `vault_mysql_app_password` | 應用帳號 `pm` 的密碼（≥ 12 字元） |
| `vault_app_key` | Laravel `APP_KEY`（`base64:...`）；留空則首次部署自動產生一次 |

```bash
cd ansible
ansible-vault create inventory/group_vars/all/vault.yml
ansible-vault edit   inventory/group_vars/all/vault.yml
```

密碼**不可以**含井字號、換行、或前後空白 —— `/root/.my.cnf` 與 Laravel `.env`
都沒有可靠的表達方式。`assert.yml` 會擋下來。

### ansible_managed

寫成一般變數而不是 `ansible.cfg` 的 `[defaults] ansible_managed`，
因為後者的值會被塞進每個 template 的第一行，只要它含 Jinja 標記就會遞迴求值失敗。

---

## 4. Play 結構

```
Play 0  localhost      算出本次的 release_id（控制端算一次）
Play 1  pm_servers     preflight（any_errors_fatal，不分批）
Play 2  pm_servers     系統層 + 應用層（可 serial）
```

### Play 0 為什麼要獨立

`ansible_date_time` 是**每台主機自己的時間**。各算各的話，秒針一跨過去
backend 與 frontend 就會落在不同的 release 目錄，rollback 也沒有共同的 id 可以指。

刻意不用 pipe lookup 去跑 `date`：pipe 是每個 host 各求值一次，
而且在 `--check` 底下也照樣執行外部指令（行為與實跑不一致）。

### Play 1 為什麼要獨立

Play 2 允許 `serial`。serial 之下 batch 1 會**整個部署完**才輪到 batch 2 ——
於是 batch 2 的 preflight 會在 batch 1 已經改完機器之後才跑。
把 preflight 拉成一個不分批的 play，才能保證「所有主機都通過檢查」才動任何一台。

### serial 與 run_once 的陷阱

`serial` 一旦不是 100%，**`run_once` 的作用域就變成「當前 batch」**，
等同 no-op：batch 1 跑一次、batch 2 再跑一次，而且兩次都宣稱自己是 run_once。

所以本專案的 migration **絕不用 `run_once`**，一律用群組 gate：

```yaml
when: inventory_hostname in groups['db_primary']
```

preflight 會斷言 `db_primary` 必須也是 `web` 的成員 —— 否則
`deploy_backend`（只在 web 執行）永遠不會跑，migration 一次都不會執行，
而且**沒有任何錯誤訊息**，網站會停在 `Base table or view not found`。

### serial / any_errors_fatal 要用 extra-vars 覆寫

它們是 play 層關鍵字，Ansible 在建立 play 時就要決定，那時還沒有 host context，
`group_vars` 不保證讀得到。

```bash
ansible-playbook site.yml -e deploy_serial=1
ansible-playbook site.yml -e deploy_any_errors_fatal=false
```

---

## 5. 十二個 role

順序不可任意調換。

| # | role | 何時跑 | 做什麼 |
|---|---|---|---|
| 1 | `preflight` | 全部主機 | 只斷言，不改狀態 |
| 2 | `common` | 全部 | 套件、目錄骨架、使用者、locale、日誌、swap、自動更新 |
| 3 | `php` | web | 決定來源（distro／ondrej／sury）→ PHP + 擴充 → FPM pool → 驗證 |
| 4 | `composer` | web | 裝 composer，先驗 CLI 有沒有 `proc_open` |
| 5 | `mysql` | db_primary | Oracle APT repo → MySQL 8.4 → 設定 → 帳號 → 備份 → 驗證 |
| 6 | `nodejs_pm2` | web | NodeSource → Node → PM2 → ecosystem |
| 7 | `nginx_myguard` | web | nginx + ModSecurity + CRS → vhost |
| 8 | `certbot` | web（tls_enable） | 簽發 / 續期 → 重新渲染 vhost |
| 9 | `deploy_backend` | web | clone → composer → .env → migration → optimize → 換 symlink |
| 10 | `deploy_frontend` | web | clone → npm ci → build → 換 symlink → pm2 / nginx |
| 11 | `healthcheck` | web | 真的打端點 |
| 12 | `hardening` | 全部 | ufw / fail2ban / sshd / sysctl（**全部預設關閉**） |

### 順序的理由

**common 必須第一個**

- `deb822_repository` 需要目標端有 `python3-debian`，`apt` 模組需要 `python3-apt`
  —— 兩個都要在**任何 repo 任務之前**裝好
- `releases/ shared/ current` 的骨架要先建好且 owner 是 deploy，
  否則 `deploy_frontend` 以 deploy 身分 clone 時父目錄是 root 所有，
  會得到 `could not create work tree dir: Permission denied`
- `/var/log/php` 要在 php-fpm 啟動前存在，否則 FPM 會
  `Unable to create or open slowlog(...)` → `FPM initialization failed`

**php 在 composer 之前** —— composer role 會先驗 CLI 有沒有 `proc_open`。

**nginx 在 certbot 之前** —— 所以 vhost 一定會在「憑證還不存在」時被寫出來。
nginx role 必須用 `ssl-cert` 的 snakeoil 憑證開機，用 `stat` 判斷正式憑證是否存在
來決定引用哪一組。否則 `nginx -t` 會 emerg，而 `any_errors_fatal`
會讓 certbot 永遠跑不到 —— 憑證永遠不會出現，**死結**。

**hardening 放最後** —— ufw / fail2ban / sshd 任何一項設錯都可能把控制端擋在門外。

### 第一次部署的正常中間狀態

`nginx`（snakeoil）→ `certbot`（簽發成功）之後，vhost 還指著 snakeoil。
`site.yml` 的 post_tasks 會用 `nginx -T`（dump 實際載入的設定，不是讀檔）偵測並提醒：

```bash
cd ansible && ansible-playbook site.yml --tags nginx
```

---

## 6. release / symlink 佈局

```
/var/www/pm/
├── releases/
│   ├── 20260904-084600/
│   │   ├── backend/
│   │   └── frontend/
│   └── 20260904-091200/
├── shared/
│   ├── backend/.env          ← 唯一的祕密所在
│   └── backend/storage/
└── current -> releases/20260904-091200
```

`current` 是原子換位。`releases_keep` 決定保留幾個，`releases_prune` 是刪除的 gate。

回滾：

```bash
cd ansible
ansible-playbook playbooks/rollback.yml                      # 先列出可用的 release
ansible-playbook playbooks/rollback.yml -e rollback_to=<id>
```

或 `cx deploy rollback`（互動式）。

---

## 6.5 PHP 的套件來源：`php_repo_source`

`php` role 用哪裡的套件是**依 codename 決定**的，不是寫死。

| 目標 | `auto` 解析成 | 理由 |
|---|---|---|
| Debian | `sury` | packages.sury.org |
| Ubuntu 22.04 (jammy) | `ondrej` | PPA 有發佈 |
| Ubuntu 24.04 (noble) | `ondrej` | PPA 有發佈 |
| **Ubuntu 26.04 (resolute)** | **`distro`** | **PPA 沒有發佈**，但官方倉庫自帶 php8.5 |
| 其他 Ubuntu | `distro` | 白名單之外一律走發行版 |

### 為什麼 26.04 不能套 ondrej

2026-09-04 實測 `HEAD https://ppa.launchpadcontent.net/ondrej/php/ubuntu/dists/<codename>/Release`：

```
jammy     200
noble     200
resolute  404      ← Ubuntu 26.04
```

而 Ubuntu 26.04 官方倉庫**自己就有** `php8.5-fpm 8.5.4-0ubuntu1.2`，
與 `php_version: "8.5"` 同一個 major.minor。硬套一個沒有該 codename 的 PPA
只會讓部署停在「找不到套件」，而錯誤訊息會指向 APT 來源、不會指向 codename。

`php_ondrej_supported_suites` 是**白名單**：新的 Ubuntu 版本出來時預設走 `distro`，
確認 PPA 真的支援之後再加進去。寫成黑名單的話每個新版本都會先炸一次。

### `distro` 來源要注意 universe

Ubuntu 26.04 的這些在 **universe**：

```
php8.5-fpm  php8.5-intl  php8.5-zip  php8.5-bcmath  php8.5-soap
```

其餘（`-common -cli -mbstring -xml -curl -gd -mysql -readline`）在 main。
Ubuntu Server 預設有開 universe，但雲端／最小化映像不一定 ——
role 會先 `apt-cache policy` 檢查，沒有就 `add-apt-repository universe`。

少了 universe 的症狀很難聯想：`php8.5-cli` 裝得起來，`php8.5-fpm` 卻說找不到。

### 只有 PHP 有這個問題

同一天把每個外部來源都探測過 resolute：

| 來源 | resolute |
|---|---|
| ondrej/php | **404** |
| MySQL apt (`repo.mysql.com/apt/ubuntu`) | 200 |
| MyGuard (`deb.myguard.nl`) | 200 |
| NodeSource | 用 `nodistro`，不分 codename |

所以升到 26.04 只需要處理 php role，其餘不動。

### 強制指定

```bash
cx deploy apply staging -e php_repo_source=distro    # 或 ondrej / sury
```

`php` role 開頭會印出實際採用的來源，不必用猜的：

```
Ubuntu 24.04 (noble) → 來源 ondrej （auto）
```

---

## 7. MySQL role 的五個坑

全部是 2026-09-04 在真實 Ubuntu 24.04 目標上實測踩到的。

### 7.1 8.4 沒有 mysql_native_password

MySQL 8.4 把 `mysql_native_password` 從預設建置移除了。
`ansible.mysql.mysql_user` 的 `password:` 參數在 8.4 上會失敗，
必須改用外掛加密文：

```yaml
plugin: caching_sha2_password
plugin_auth_string: "..."
```

### 7.2 TCP 連線需要 python3-cryptography

`caching_sha2_password` 在**非 unix socket** 的連線上要走 RSA 交換，
PyMySQL 把那一段委託給 cryptography。缺了它，走 socket 的任務全部正常，
**只有 TCP 127.0.0.1 會失敗**：

```
'cryptography' package is required for sha256_password or caching_sha2_password auth methods
```

看起來像授權沒建好（`pm@127.0.0.1` 不存在），其實是目標機少一個 python 套件。
現在 `common` 與 `mysql` 兩個 role 都會裝。

### 7.3 skip-name-resolve 需要雙 host 授權

`skip-name-resolve` 之下 MySQL 不做 DNS 反解，授權比對的是**字面 host**。
所以應用帳號必須同時有 `@localhost`（socket）與 `@127.0.0.1`（TCP）兩筆授權。

### 7.4 handler 通知不會跨 play 保留

這是最難查的一個：

1. 部署寫入 `zz-app.cnf` → notify restart mysql
2. 後面某個任務失敗 → play 中止 → **handler 從未執行**
3. 下一次部署：檔案內容已經一樣 → template 回報 ok 而不是 changed
   → **永遠不再 notify** → mysqld 一直跑著舊設定

而錯誤訊息（「includedir 沒載入」）把人導向完全錯誤的方向 ——
includedir 明明是對的，檔案也明明寫好了。

**修法不是加 `flush_handlers`**（沒有 handler 可以 flush），
而是讓 `verify.yml` 依「執行期的實際值」判斷：讀 `SHOW VARIABLES` 的結果，
跟期望值比對，不一致就重啟再讀一次。對了就什麼都不做（冪等）。

### 7.5 被 when 略過的任務照樣會寫入 register

承上，「重啟後重讀」那個任務不能直接 `register: mysql_runtime`。
被 `when` 略過的任務**照樣會寫入 register 變數**，寫進去的是

```json
{"changed": false, "skipped": true, "skip_reason": "..."}
```

於是已經收斂的主機（不需要重啟、整個 block 略過）會把先前那次成功查詢的結果
覆蓋掉，下一個 assert 求值 `fail_msg` 時變成

```
object of type 'dict' has no attribute 'query_result'
```

訊息完全不會提到 register，而且**只在第二次以後的部署才出現**
（第一次部署 block 有跑，變數是好的）。
修法：register 到另一個變數，block 內再用 `set_fact` 覆寫。

---

## 8. 其他實測踩過的坑

| 症狀 | 原因 | 修法 |
|---|---|---|
| `Failed to find required executable "debconf-get-selections"` | `debconf-utils` 在 minimal 映像預設不裝，而訊息完全不提套件名 | `common_base_packages` 加 `debconf-utils` |
| `nginx -t` emerg，設定明明沒問題 | vhost 片段用了 `validate` 搭配 `nginx -t -c %s`，`-c` 把片段當完整主設定，沒有 events 區塊就 emerg | 片段不驗證，最後跑一次不加 `-c` 的 `nginx -t` |
| 間歇性 502 | `pm2_instances` 與 `frontend_instances` 用 YAML anchor 綁在一起，環境別檔案只覆寫其中一個 | preflight 斷言兩者相等 |
| `ERR_REQUIRE_ESM` | PM2 cluster 模式走 CJS require，載不動 Nuxt 的 ESM `.mjs` | 只能用 fork，preflight 會斷言 |
| GPG key 過期 | key URL 寫死年份 | 改成當前年份、加 `force: true`、加到期斷言，key 變更也要觸發 apt-update |
| ansible-lint 回報 803 個 finding | 掃到了 `collections/` 底下的上游原始碼 | `bin/lib/ansible_lint.py` 排除 `collections`、`.cache`、`.ansible`、`.git`、`__pycache__` |

---

## 9. 本機驗證用的目標

`ansible/inventory/hosts.yml`（不進版控）指向一個
`pm/ansible-target:24.04` 容器：Ubuntu 24.04 + systemd + sshd + sudo NOPASSWD，
SSH 在 `127.0.0.1:2222`。

這不是玩具 —— 它跑 systemd，`systemd_service` 模組、handler、
服務啟動順序全部是真的。

---

## 10. 除錯

| 想知道 | 指令 |
|---|---|
| 合併後的變數 | `cx deploy vars <主機>` |
| 目標的 facts | `cx deploy facts <主機>` |
| 會改什麼 | `cx deploy check <限制>` |
| 只跑某一段 | `cd ansible && ansible-playbook site.yml --tags mysql` |
| 只跑斷言 | `--tags preflight` |
| 只換程式碼 | `cx deploy app <限制>` |
| 為什麼某個任務被略過 | `ansible.cfg` 的 `display_skipped_hosts` 改成 True |

---

## 11. 實跑紀錄（2026-09-04）

`site.yml` 在 `pm/ansible-target:24.04`（真 systemd）上**完整跑通**：
**475 個 task、`failed=0`**，第二次執行同樣 `failed=0`。

驗證結果：

| 端點 | 回應 |
|---|---|
| `/up` | 200 |
| `/` | 200 |
| `/admin` | 302（導向登入，正確） |

| unit | 狀態 |
|---|---|
| `pm-queue@1` / `pm-queue@2` | active |
| `pm2-deploy` | active |
| `pm-schedule.timer` | active |
| `nginx` / `php8.5-fpm` / `mysql` | active |

把它從「連 `--syntax-check` 都沒跑過」推到全綠，中間修掉八個
**只有真的裝起來才會現形**的缺陷：

| 卡在第幾個 task | 症狀 | 根因 |
|---|---|---|
| 178 | MySQL 執行期設定與預期不符 | handler 通知不跨 play 保留（§7.4） |
| 185 | 應用帳號 TCP 登入失敗 | 缺 `python3-cryptography`（§7.2） |
| 179 | `assert` 的 `fail_msg` 求值失敗 | 被 `when` 略過的任務照樣寫入 register（§7.5） |
| 235 | `pm2-deploy.service` 起不來 | PM2 v7 不寫 `pm2.pid`，unit 卻是 `Type=forking` |
| 278 | `nginx -t` emerg | 發行版 `nginx.conf` 已宣告同名指令 |
| 308 | `regex_search` 丟例外 | 帶捕獲組時沒比對到會直接丟，`when` 擋不住 |
| 335 | `mv: missing destination file operand` | 折疊純量的續行縮太深，YAML 保留了換行 |
| 473 | healthcheck 4 項失敗 | queue unit 名稱沒展開 + PM2 沒交給 systemd + DNS 解析不到 |

每一項的完整說明與修法見 [`troubleshooting.md`](troubleshooting.md)。

### 這份紀錄的意義

`--syntax-check` 與 `ansible-lint`（production profile）從一開始就是全綠的。
上面八個缺陷**沒有任何一個**會被那兩者抓到 —— 它們全部要等到
「真的在一台會啟動服務的機器上跑」才會現形，而且平均要等 200 個 task 才碰到。

所以 `cx deploy lint` 通過不代表可以上線；`cx deploy check`（`--check --diff`）
也不行（`command` / `shell` 在 check 模式會被跳過）。
唯一能證明的方式是對一台真的機器跑 `cx deploy apply`。
