# roles/mysql

MySQL **8.4 LTS**（Oracle `repo.mysql.com` APT 來源）、應用資料庫與**雙 host 授權**、
`mysqldump` 備份與過期清理。

適用對象：`db_primary` group 的主機。
（site.yml 若用 `serial:`，migration 這類「只做一次」的動作要用
`groups['db_primary']` 明確 gate，不能靠 `run_once` —— `run_once` 的作用域是當前
serial batch。這個角色本身對每台主機都是冪等的。）

## 為什麼不用發行版套件

| 目標平台 | 發行版套件 | 實際內容 |
|---|---|---|
| Ubuntu 24.04 noble | `mysql-server` | MySQL **8.0.x**，不是 8.4 LTS |
| Debian bookworm / trixie | `default-mysql-server` | **MariaDB**，根本不是 MySQL |

所以 `mysql_repo_source` 預設 `oracle`：加入 `repo.mysql.com` 的 deb822 來源、
驗證 GPG 指紋、用 APT pinning 蓋過發行版套件，component 鎖在
`mysql-8.4-lts`（9.x 在 `mysql-innovation`，屬 Innovation track，每版只有 8 個月
支援，**不可使用**）。

`mysql_repo_source=distro` 會被 `tasks/assert.yml` 擋下，除非明確設定
`mysql_allow_distro_version=true`。

## 執行順序（tasks/main.yml）

```
assert → repo → install → config → secure → databases → backup → verify
```

順序中有三個地方是刻意的：

1. **`/root/.my.cnf` 寫在 `apt install` 之前**（`tasks/install.yml` 第一個任務）。
   Oracle 套件在安裝當下就用 debconf 的值初始化 root 密碼；先寫檔，
   任何中途失敗（網路斷、Ctrl-C、assert 失敗）之後重跑都還有憑證可用，
   不必停機用 `--skip-grant-tables` 救。
2. **root 密碼只設 `root@localhost`**，不用 `host_all`。
   `host_all` 只能搭配 `state: absent`（模組限制），而且對 root 用它會把
   `root@localhost` 一起改掉。
3. **`verify` 在最後真的用應用帳號連兩次**（TCP `127.0.0.1` + unix socket），
   而不是「檔案寫出去就當成功」。

## skip-name-resolve 與雙 host 授權

`zz-app.cnf` 設了 `skip-name-resolve`（不做 DNS 反解，省掉解析延遲與
DNS 故障造成的連線卡死）。代價是**授權比對的是字面 host**：

* 後端 `.env` 寫 `DB_HOST=127.0.0.1` → 比對 `'pm'@'127.0.0.1'`
* 後端 `.env` 寫 `DB_HOST=localhost` → 走 unix socket，比對 `'pm'@'localhost'`

兩者不會互相 fallback。只建其中一個，另一個會直接
`ERROR 1045 (28000): Access denied`。因此 `mysql_app_user_hosts` 預設同時包含
兩者，`tasks/assert.yml` 也會在 `skip_name_resolve=true` 時強制檢查這件事。

## 刪除類動作與它們的 gate

| 動作 | gate |
|---|---|
| `DROP DATABASE test` | `mysql_drop_test_db`（預設 **false**）＋ schema 必須存在 ＋ 該 schema 的 table 數必須為 **0**，否則 fail 並要求人工確認 |
| 移除匿名帳號 | `mysql_remove_anonymous_users`（`host_all` 只搭配 `state: absent`） |
| 移除非 localhost 的 root | `mysql_remove_remote_root`，且先 `SELECT host` 查出實際存在的才逐一刪 |
| 設定無效時移除 `zz-app.cnf` | `mysql_config_rollback_on_invalid`（預設 **false**，預設只 fail 並印出 `mysqld --validate-config` 的錯誤） |
| 清理過期備份 | `find <備份目錄> -maxdepth 1 -type f -name '<prefix>-*.sql*' -mtime +N -delete`，外加腳本執行期檢查目錄是絕對路徑、不是系統要害目錄、保留天數落在 1..3650 |

## 密碼

`mysql_root_password` / `mysql_app_db_password` 一律來自 vault
（`vault_mysql_root_password`、`vault_mysql_app_password`），未設定或長度不足
`mysql_password_min_length`（預設 12）會在 assert 階段失敗。

**不可含反斜線、雙引號、換行**：MySQL 選項檔對「反斜線 + 非 `\b\t\n\r\\\s`」
的處理是保留反斜線，沒有可靠方式表達字面的 `"` 與 `\`；同一組密碼還要寫進
Laravel 的 `.env`，那邊同樣麻煩。建議：

```bash
openssl rand -base64 36 | tr -d '/+=\n'
```

`mysql_root_password_update` / `mysql_app_password_update` 預設 `always`
（每次執行都把密碼收斂到 vault 的值）。MySQL 8 的 `caching_sha2_password`
雜湊有 salt，模組無法比對，所以**這兩個任務每次都會報 changed，那是正常的**；
不想要噪音可以改成 `on_create`，但輪替密碼時要記得改回 `always`。

## 與其他角色的連動

* `app_max_upload_mb` → `mysql_max_allowed_packet_mb`（預設 `+32MB`）。
  這四個值（PHP `upload_max_filesize`/`post_max_size`、nginx
  `client_max_body_size`、MySQL `max_allowed_packet`）必須從同一個變數推導，
  且越往後端越寬鬆，assert 會檢查。
* `app_db_name` / `app_db_user` / `app_slug` 若未定義，本角色分別退回
  `pm` / `pm` / `pm`。
* 需要 collection `community.mysql`（目標機需 `python3-pymysql`，本角色會裝）。
  `deb822_repository` 需要 `python3-debian`（`tasks/repo.yml` 會先裝，
  common 角色也應該有）。

## 常用指令

```bash
# 只跑資料庫層
ansible-playbook -i inventory/hosts.yml site.yml --tags mysql

# 只重寫設定並驗證
ansible-playbook -i inventory/hosts.yml site.yml --tags mysql-config,mysql-verify

# 手動跑一次備份
sudo /usr/local/sbin/pm-mysql-backup

# 還原
gunzip -c /var/backups/pm-mysql/pm-pm-20260903-031500.sql.gz | mysql --defaults-file=/root/.my.cnf
```

## 已知限制 / 尚未驗證的部分

* `mysql_repo_key_fingerprints_allowed` 預設值是 MySQL 2023 release
  engineering key 的指紋。**Oracle 若輪替金鑰，這裡要更新**；更新前請自行從
  官方文件（`checking-gpg-signature`）核對，不要因為 assert 擋路就把它拿掉。
* Ubuntu 26.04（resolute）在 `repo.mysql.com` 是否已有對應目錄，執行前會用
  HTTP 探測（`mysql_repo_check_suite`）；沒有的話會給出「改用
  `mysql_repo_suite=noble`」的指示，而不是默默裝錯東西。
* 這個角色**不做**主從複製、不做就地大版本升級。偵測到已安裝
  `mysql-server-8.0` 會直接中止並要求人工處理。
