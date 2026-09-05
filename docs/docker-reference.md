# Docker 參考

> 改 `docker-compose.yml`、`docker/compose/*.yml` 或任何 Dockerfile 之前先讀這份。
> 這裡的每一條「不要這樣做」都對應一次實際踩過的坑。

---

## 1. 合併鏈

每一次 compose 呼叫都是這個形狀：

```bash
docker compose \
  --project-directory /path/to/pm \
  -p pm_<mode> \
  -f docker-compose.yml \
  -f docker/compose/<mode>.yml \
  --env-file .env \
  --env-file docker/env/<mode>.env \
  <動作>
```

由 `bin/lib/common.sh` 的 `cx_compose_init()` 組出來，所有動詞都必須走這條路。
四個參數各自對應一個陷阱：

### `--project-directory`

compose 檔裡的相對路徑（build context、bind mount 來源）**以第一個 `-f` 的目錄為基準**，
不是你的 cwd。沒有這個參數，從 `backend/` 執行時 `./backend` 會被解析成
`pm/backend/backend`，錯誤訊息是 `no such file or directory`，
而你正站在那個確實存在的目錄裡。

### `-p pm_<mode>`

隔離容器名、網路、volume。**但它不隔離 host 埠。**
只做 `-p` 不分埠段的話，第二個模式會直接
```
Error response from daemon: Bind for 0.0.0.0:8080 failed: port is already allocated
```

### `--env-file`

**顯式的 `--env-file` 指到不存在的檔案是硬錯誤**（隱式的 `./.env` 才會靜默略過）：
```
env file /path/docker/env/dev.env not found: stat ...: no such file or directory
```
所以 `cx_compose_init` 只把**存在的**檔案加進去。

順序也有意義 —— **後面的優先**。`docker/env/<mode>.env` 在 `.env` 之後，
模式專屬的值（埠、build target）才蓋得掉根 `.env` 的通用值。

### 網路名

compose 預設把網路命名成 `<project>_<key>`，於是 `pm_dev` + `net` = `pm_dev_net`。
如果別的地方（Ansible、腳本、文件）寫死 `pm_net`，那個名字不存在。
所以 compose 裡明寫 `name:`。

---

## 2. `ports:` 是 append，不是 override

這是 Compose v2 合併語意裡最容易致命的一條：

```yaml
# docker-compose.yml (base)
services:
  edge:
    ports: ["8080:80"]

# docker/compose/prod.yml (overlay)
services:
  edge:
    ports: ["80:80"]
```

結果**不是** `80:80`，是 `["8080:80", "80:80"]` —— **兩個都發布**。
正式環境會意外多開一個 8080，而且 `docker compose config` 之外看不出來。

`ports:` / `volumes:` / `expose:` / `dns:` 這類序列全部是 append-merge。
標量（`image:`、`command:`）才是覆寫。

**因此 base `docker-compose.yml` 完全不寫 `ports:`。**
每個模式的 overlay 各自宣告自己的埠，沒有東西可以被 append 到。

同理，base 也不寫：

| 不寫在 base | 為什麼 |
|---|---|
| `ports:` | append 語意 |
| `container_name:` | 固定名字會讓三個模式撞名，`-p` 也救不了 |
| 原始碼 bind mount | prod 要的是不可變映像，被 append 一個 host mount 就前功盡棄 |

驗證方法只有一個：
```bash
cx prod config | grep -A5 'edge:' | grep -A3 ports
```

---

## 3. 三個模式的差異

| | dev | test | prod |
|---|---|---|---|
| PHP build target | `dev` | `test` | `prod` |
| Nuxt build target | `dev` | `prod` / `static` | `prod` / `static` |
| 原始碼 | bind mount | **烘進映像** | **烘進映像** |
| vendor / node_modules | 具名 volume | 映像內 | 映像內 |
| opcache | 關（`validate_timestamps=1`） | 開 | 開 + `preload` |
| xdebug | 開 | 關 | 關 |
| WAF | 無 | ModSecurity + CRS | 無（正式環境前面是別的） |
| phpMyAdmin | 有（8891） | **有（18891）** | 無 |
| MySQL 發布埠 | 127.0.0.1:3306 | 127.0.0.1:13306 | **不發布** |
| `APP_DEBUG` | true | false | false |

### dev 的 vendor 為什麼是具名 volume

dev 把 `./backend` bind mount 進 `/var/www/html`。host 的 `backend/vendor`
如果存在，會直接蓋掉映像裡由 `composer install` 產生的那一份 ——
而那一份才是照容器內的 PHP 版本與擴充解析出來的。

所以 `vendor/` 掛一個具名 volume 疊在 bind mount 上面，
讓映像內的 vendor 贏過 host 的。`node_modules` 同理。

代價：改了 `composer.json` 之後要 `cx dev build --no-cache`
或 `cx composer install`（會寫進 volume），單純 `cx dev restart` 不會更新 vendor。

---

## 4. Dockerfile

### `docker/php/Dockerfile`

```
base ──┬─ vendor-dev ──┐
       ├─ vendor-prod ─┤
       └─ backend-assets ─┐
                          ├─ dev
                          ├─ test
                          └─ prod
```

| stage | 內容 |
|---|---|
| `base` | php:8.5-fpm-alpine + 擴充 + nginx + supervisor |
| `vendor-dev` | `composer install`（含 dev 相依） |
| `vendor-prod` | `composer install --no-dev --optimize-autoloader` |
| `backend-assets` | **有 node** 的階段，`npm ci && npm run build` → `public/build/` |
| `dev` | base + vendor-dev + xdebug + opcache 關閉 |
| `test` | base + vendor-dev + assets + opcache 開 |
| `prod` | base + vendor-prod + assets + opcache preload |

擴充一律用 `mlocati/php-extension-installer`，不用 `pecl install`：
pecl 對 PHP 8.5 的很多擴充還沒有相容版本，會在 `phpize` 階段失敗，
而且失敗訊息在 build log 中段，很容易被當成暫時性錯誤重試三次。

`backend-assets` 是獨立階段而不是在 `dev` 裡跑 npm，因為執行期的映像
不需要 node —— 留著它會讓正式映像多 ~150MB，也多一整套 npm 的攻擊面。

### `docker/nuxt/Dockerfile`

```
deps ──┬─ dev
       └─ build ──┬─ prod
                  └─ static
```

| stage | 內容 |
|---|---|
| `deps` | `npm ci` |
| `dev` | `nuxt dev`，HMR，bind mount 原始碼 |
| `build` | `nuxt build` 或 `nuxt generate`（看 `FRONTEND_MODE`） |
| `prod` | 只帶 `.output/`，`node .output/server/index.mjs` |
| `static` | nginx + `.output/public` |

---

## 5. `app` 容器裡有什麼

PID 1 是 **supervisord**，底下四種行程：

| program | 數量 | 說明 |
|---|---|---|
| `php-fpm` | 1 | |
| `nginx` | 1 | 聽 8080，只服務 PHP 與 Laravel 靜態資產 |
| `laravel-queue` | 2 | `queue:work --tries=3 --max-time=3600` |
| `laravel-schedule` | 1 | `schedule:work` |

**不用 `command:` 直接跑 php-fpm**，因為那樣 queue worker 與排程就沒地方放；
用 host cron 又會讓「容器就是完整的執行單元」這件事不成立。

supervisord 的設定要有 `nodaemon=true`，否則它會 fork 到背景、PID 1 立刻退出、
容器被判定為結束。

`stopsignal` 對 php-fpm 是 `QUIT`（優雅收工），對 queue worker 是 `TERM`
（Laravel 的 worker 收到 TERM 會做完當前 job 再退出）。

### 要多加一個 worker：`/etc/supervisor/conf.d/`

`docker/php/supervisord.conf` 有一段 `[include]`：

```ini
[include]
files = /etc/supervisor/conf.d/*.conf
```

所以額外的 program 不必改那個烤進映像的主設定檔 —— 丟一個 `.conf` 進
`/etc/supervisor/conf.d/`（bind mount 或衍生映像）就會被載入。目錄由
`docker/php/Dockerfile` 建立，空的也不影響（glob 不匹配不會出錯）。

> 這個 drop-in 目錄一度消失過：舊映像本來就是靠它把 `laravel-queue.conf`
> 掛進來的，新映像把 program 直接寫進主設定檔之後就沒人補回目錄，
> 於是「加一個 worker」變成必須改映像再重建。2026-09-04 補回。

### entrypoint 以 root 執行，但不留 root 檔案

`docker/entrypoint/app.sh` 的 PID 1 需要 root（supervisord 的要求），
所以它跑的 `artisan` 也是 root。`backend/` 在 dev 是 bind mount，
因此凡是 entrypoint **新建**的檔案都要立刻 `chown` 回 `www-data`
（uid 已在 build 時對齊成 `APP_UID`）：

| 檔案 | 由誰產生 |
|---|---|
| `bootstrap/cache/packages.php` | `artisan package:discover` |
| `public/storage` | `artisan storage:link` —— 是 symlink，要用 `chown -h` |

少了這一步，host 端會出現 `root:root` 的檔案，而你 `chmod` / `setfacl` 它們
會得到 `Operation not permitted`（那兩個動作需要**擁有者或 root**，同群組不算）。
清掉既有殘骸用 `cx acl fix-owner`。

---

## 6. edge 的路由

見 [`manual.md` §5](manual.md)。這裡只補三個實作細節。

### `add_header` 的繼承

nginx 的 `add_header` **不是累加的**：任何一個 `location` 只要有自己的
`add_header`，它就會**丟掉所有從 `server` / `http` 繼承來的**。

所以安全標頭（CSP、X-Frame-Options…）不能只寫在 `server` 層 ——
只要有一個 location 加了 `add_header X-Something`，那個 location 的
安全標頭就全部消失，而且測其他路徑完全看不出來。

專案的做法是把安全標頭放進一個 `.inc`，每個需要的 location 各自 `include` 一次。

### `X-Forwarded-Port`

三層 `map`，越後面越優先：

```nginx
map $scheme $pm_scheme_port { default 80; https 443; }
map $http_host $pm_host_port {
    default                     $pm_scheme_port;
    "~^[^:]+:(?<pm_hp>[0-9]+)$" $pm_hp;
}
map $http_x_forwarded_port $pm_forwarded_port {
    default        $pm_host_port;
    "~^[0-9]{1,5}$" $http_x_forwarded_port;
}
```

- 沒有任何線索 → 用 scheme 推（80/443）
- `Host: localhost:8080` → 用 8080
- 上游已經給了合法的 `X-Forwarded-Port` → 沿用

沒有這一段的話，dev 的 `url()` 產生的絕對網址會少掉 `:8080`，
於是 Filament 的重導向、密碼重設信、`asset()` 全部指到不存在的 80 埠。
正則限制 1–5 位數字是為了不把上游塞進來的垃圾原樣往後傳。

### WAF 的設定要當 template 掛

ModSecurity CRS 映像用 envsubst 處理 `/etc/nginx/templates/` 底下的檔案，
產生結果放到 `/etc/nginx/`。

把自訂設定直接掛進 `/etc/nginx/includes/` 會**跳過 envsubst**，
於是 `${PROXY_PASS}` 之類的變數原樣留在設定檔裡，nginx 啟動失敗；
更糟的情況是它被 include 在一個容錯的位置，nginx 起得來但規則沒生效。

正確位置：
```yaml
volumes:
  - ./docker/waf/proxy_backend.conf:/etc/nginx/templates/includes/proxy_backend.conf:ro
  - ./docker/waf/pm-forwarded-port.conf:/etc/nginx/templates/includes/pm-forwarded-port.conf:ro
```

CRS 的排除規則走官方的擴充點：
`/opt/owasp-crs/plugins/*-before.conf` 與 `*-after.conf`。
直接改 CRS 自己的檔案會在下次拉映像時被覆蓋。

---

## 7. bind mount 來源必須先存在

Docker 對「bind mount 來源不存在」的處理是**靜默建立一個 `root:root 0755` 的空目錄**，
然後掛上去。不會警告，不會失敗。

後果：CRS 排除規則從未載入 → WAF 悄悄失效；
或是 `reports/sast` 被建成 root 所有 → 以 uid 1000 執行的 Semgrep 全程 EACCES。

所以 `cx <模式> up` 之前會做兩件事：

1. `cx_ensure_host_dirs` —— 以呼叫者身分建立 `reports/` 與 `.cx/` 的葉目錄
2. `cx_assert_mount_sources` —— 從 `docker compose config --format json`
   （**合併後**的結果，不是 grep yaml）撈出所有相對路徑的 bind mount 來源，
   逐一確認存在，缺一個就中止

---

## 8. `.dockerignore`

build context 送進 daemon 的東西越少越好，但真正的理由是**祕密**：
`.env`、`.cx/sonar-token`、`~/.ssh` 的任何複本、`ansible/inventory/group_vars/all/vault.yml`
只要進了 context，就算 Dockerfile 沒有 `COPY` 它，它也已經傳給 daemon 了；
而任何一個 `COPY . .` 都會把它烘進映像層，之後 `docker history` 挖得出來。

（`example/` 曾經也在這份清單裡 —— 那是舊專案 PSYOP_DutyManager 的參考副本。
2026-09-04 確認所有 docker-compose 元件都已移植到本專案之後移除，
`.dockerignore` 與 `.gitignore` 的對應規則也一併拿掉。）

---

## 9. 除錯

| 想知道 | 指令 |
|---|---|
| 合併後到底長什麼樣 | `cx <模式> config` |
| 為什麼埠沒開 | `cx <模式> config \| grep -A5 ports` |
| 容器內的環境變數 | `cx <模式> dc exec app env \| sort` |
| supervisord 的狀態 | `cx <模式> dc exec app supervisorctl status` |
| nginx 實際載入的設定 | `cx <模式> dc exec edge nginx -T` |
| 為什麼 build 很慢 | `cx <模式> build --progress=plain` |
| 映像多大 | `docker images 'pm/*'` |

`cx <模式> dc <任何原生參數>` 是逃生門 —— 參數原樣交給 `docker compose`，
但前面的 `--project-directory` / `-p` / `-f` / `--env-file` 都已經組好，
所以不會踩到第 1 節的四個陷阱。
