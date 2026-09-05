# 疑難排解

> 症狀 → 原因 → 解法。全部是這個專案實際踩過的坑，不是通用建議。
> 找不到你的症狀時，先跑 `cx doctor`。

---

## 環境

### `./cx: Permission denied`

git index 把 `cx` 的模式記成 `100644`，磁碟上卻是 755。
內容零差異，`git diff` 看不出來，但任何人 clone 下來都跑不了。

```bash
git update-index --chmod=+x cx
git commit -m "fix: restore cx exec bit"
```

`cx doctor` 會同時檢查磁碟與 git index 的執行位元。

---

### `Docker daemon 不可用`，但 `systemctl is-active docker` 是 active

`usermod -aG docker $USER` **只影響之後才建立的登入 session**。

WSL 上必須從 Windows 端執行 `wsl --shutdown` 再重開終端機。
`newgrp docker` 只影響那一個 shell，`cx` 開的子行程拿不到。

---

### `cx` 卡住不動，沒有任何輸出

多半是卡在一個確認提示上，而你所在的環境沒有真的終端機。

「`/dev/tty` 開得起來」不等於「有人在那一端」：WSL 底下即使整個 session
完全非互動（例如 `wsl.exe -- bash -s < script`），`/dev/tty` 一樣開得起來，
於是 `read </dev/tty` 會**永遠卡住**而不是失敗 —— 沒有輸出、沒有錯誤。

現在所有確認提示的 `read` 都有逾時（預設 120 秒，`CX_ASK_TIMEOUT` 可調），
逾時往**取消**的方向倒，不會有「等太久就自動同意」這種事。

非互動環境要跑需要確認的動作，請明確加 `--yes`：

```bash
cx --yes git push --force
```

（`--yes` 是全域旗標，要放在動詞之前。）

---

### `cx: 找不到 .cxroot（不在 pm 專案內？）`

你不在專案樹底下。`cx` 會先從 cwd 往上找 `.cxroot`，找不到才退回
`cx` 自身所在目錄往上找。

```bash
cx --root /path/to/pm doctor
```

---

### `cx doctor` 在子目錄回報 28 個「磁碟未設執行位元」，在專案根目錄卻全綠

檢查清單是「相對 `CX_ROOT`」的路徑，而產生清單的 `cd "$CX_ROOT"`
只發生在 process substitution 的子 shell 裡 —— 迴圈本體的 cwd 還是你所在的目錄。
於是 `[[ -x bin/cmd/art.sh ]]` 在 `backend/` 底下永遠是 false。

已修正（測試點自己補上 `$CX_ROOT/`）。同一類錯誤值得注意：
**`< <(cd X && ...)` 不會改變迴圈本體的 cwd。**

---

### `cx setup deps` 說「沒有 composer」，但 `which composer` 明明找得到

`~/.local/bin` 不在**這個 shell** 的 PATH 上。

`~/.profile` 裡確實有把它加進 PATH 的那段，但 `~/.profile` **只在 login shell 生效**。
從 Windows Terminal、VS Code 的終端機、或某些 `wsl.exe` 呼叫進來的 bash 是
非 login shell，它讀 `~/.bashrc` 而不是 `~/.profile`。

於是同一台機器上：

```
$ bash -lc 'command -v composer'      # login shell
/home/user/.local/bin/composer
$ bash -c  'command -v composer'      # 非 login shell
（沒有輸出）
```

```bash
# 這次先生效
export PATH="$HOME/.local/bin:$PATH"

# 永久生效（非 login shell 也吃得到）
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc

# 確認
echo $PATH | tr : '\n' | grep '\.local/bin'
```

`cx doctor` 現在會直接點名這種情況：

```
✘ PATH    composer npm 已裝在 /home/user/.local/bin，但不在 PATH 上
```

它跟「真的沒裝」是不同的處置 —— 照著「請跑 cx setup tools」重裝一百次也不會好，
因為東西從來就是裝好的。

---

### WSL：`npm ci` 成功了，但 `vite build` 說 `CMD.EXE 不支援 UNC 路徑`

```
'\\wsl.localhost\Ubuntu-26.04\home\sixtou\pm\backend'
CMD.EXE 不支援 UNC 路徑作為目前工作目錄
✗ Build failed in 111ms
```

**你跑到的是 Windows 的 npm。** WSL 預設把 Windows 的 PATH 併進來，所以
`/mnt/c/Program Files/nodejs/npm` 一直都在 PATH 上。只要 Linux 版的
`~/.local/bin/npm` 不在（見上一則），`npm` 就會靜默解析到 Windows 那支。

它不是「比較舊的 npm」，是根本不能用在 WSL 的專案目錄上 ——
Windows 的 CMD.EXE 沒辦法把 UNC 路徑當工作目錄。

最惡劣的地方是 **`npm ci` 會「成功」**：它留下一棵殘缺的 `node_modules`
（2026-09-04 實測是 24 KB，裡面根本沒有 `nuxt`），錯誤要到後面
`vite build` 或 `nuxt` 啟動時才炸 —— 看起來像前端壞了，跟 npm 毫無關聯。

```bash
# 確認你跑的是哪一支
command -v npm            # 出現 /mnt/c/... 就是中了
npm --version             # Windows 那支的版號會跟 node --version 對不起來

# 修
export PATH="$HOME/.local/bin:$PATH"
rm -rf src/frontend/node_modules src/backend/node_modules
cx setup deps
```

`cx` 現在會擋下來，不會讓它跑：

```
✘ PATH 上的 npm 是 Windows 的：/mnt/c/Program Files/nodejs/npm
    它不能用來建置 WSL 裡的專案：CMD.EXE 不支援 UNC 路徑當工作目錄，
    症狀是 npm ci 留下一棵殘缺的 node_modules、然後 vite build 失敗。
```

判斷邏輯是 `cx_have_native`（`bin/lib/common.sh`）：解析到 `/mnt/<磁碟>/` 或
`.exe` 結尾的一律不算數。`cx pma` 要開瀏覽器時反而**需要** `explorer.exe`，
所以那裡用的仍然是 `cx_have`。

`cx doctor` 也會單獨列出來：

```
✘ PATH 上有 Windows 的工具    npm=/mnt/c/Program Files/nodejs/npm
✘ native src/frontend/node_modules  目錄在但沒有 nuxt —— 殘缺的安裝，重跑 cx setup deps
```

---

### Windows 上 python3 沒反應

Git Bash 看到的 `python3` 是 Microsoft Store 的 stub，
會安靜地退出 0 而什麼都不做 —— 於是「腳本跑了、檔案沒變」。

Python 一律在 WSL 裡跑，而且用 stdin 送檔案（WSL 看不到 Windows 的暫存目錄）：

```bash
wsl.exe -d Ubuntu-26.04 -- python3 - < script.py
```

---

### `✘ cx 的選單需要終端機（TTY）`

裸執行 `cx`（不給動詞）預設會開互動選單，而選單需要 tty。
在腳本、pipe、CI、或 `cx < /dev/null` 之下會**硬失敗**回傳 3，不會退回文字模式 ——
那是刻意的：互動介面在非互動環境「安靜地做一半」比直接停下更糟。

```bash
cx doctor          # 非互動環境一律明確給動詞
cx help            # 看有哪些動詞
```

`--ui plain` 也會讓選單不可用，即使你在真的終端機上 ——
判斷條件是「fd 8 是 tty」**且**「`CX_UI != plain`」兩者同時成立。

## Docker

### `Bind for 0.0.0.0:8080 failed: port is already allocated`

`-p pm_<mode>` 隔離容器、網路、volume，**但不隔離 host 埠**。
兩個模式必須用不同的埠段（`env/docker/compose/<mode>.env`）。

先看誰佔著：`docker ps --format '{{.Names}} {{.Ports}}' | grep 8080`

---

### 正式環境意外多開了一個 8080

`ports:` 在 Compose v2 是 **append-merge**，不是覆寫。
base 寫了 `8080:80`、prod overlay 寫了 `80:80`，結果是**兩個都發布**。

修法：base `docker-compose.yml` 完全不寫 `ports:`。

驗證：`cx prod config | grep -A5 edge: | grep -A3 ports`

---

### `env file ... not found: stat ...: no such file or directory`

顯式的 `--env-file` 指到不存在的檔案是**硬錯誤**（隱式的根 `.env` 才會靜默略過）。
`cx_compose_init` 只把存在的檔案加進去，所以你看到這個表示你在繞過 `cx`。

---

### build context 找不到明明存在的目錄

compose 檔裡的相對路徑**以第一個 `-f` 的目錄為基準**，不是你的 cwd。
少了 `--project-directory` 時，從 `backend/` 執行會把 `./src/backend`
解析成 `pm/backend/backend`。

`cx` 一律帶 `--project-directory` 指向專案根目錄。

---

### WAF 規則沒生效，但容器起來了、掛載也「成功」

bind mount 來源不存在時，Docker **靜默建立一個 root 所有的空目錄**再掛上去。
不警告，不失敗。

`cx <模式> up` 之前會用 `cx_assert_mount_sources` 逐一確認。
自己下 `docker compose` 就沒有這個保護。

---

### Trivy / Semgrep / PHPStan / ZAP 全部 EACCES

掛在「image 中不存在的路徑」上的具名 volume 一律被 Docker 建成 root 所有 0755，
而這些工具以 uid 1000 執行。

`cx setup dirs` 會以你的身分先把 `reports/` 與 `.cx/` 的葉目錄建好。

---

### `ERROR 2026 (HY000): TLS/SSL error: self-signed certificate in certificate chain`

你在 `app` 容器裡跑 mysql client。`app` 是 Alpine，
`apk add mysql-client` 裝到的其實是 **MariaDB client**，它預設驗證伺服器憑證，
對上 MySQL 8.4 的自簽憑證每次都爆。

訊息看起來像 TLS 壞了，其實只是用錯 client。用 `cx db shell`
—— 它一律在 mysql 容器裡執行。

---

### 改了 composer.json，`cx dev restart` 之後還是舊的 vendor

dev 的 `vendor/` 是**具名 volume**（疊在 bind mount 上面，
讓映像裡照容器 PHP 版本解出來的那一份贏過 host 的）。restart 不會更新它。

```bash
cx composer install               # 寫進 volume
cx dev build --no-cache && cx dev up -d
```

---

## 應用

### `/admin` 回 200 但沒有樣式、按鈕沒反應

兩件事同時發生：

1. **Filament 資產 404** —— `artisan filament:assets` 發布到 `/js/`、`/css/`、
   `/fonts/`。edge 沒有把這些前綴路由給 PHP 的話會落到 Nuxt。
2. **Livewire 404** —— Livewire v4（Filament v5 的底層）把端點放在
   **帶 hash 的前綴**底下（`/livewire-<hash>/`），hash 由應用的 key 推導、
   每個部署不同。寫死 `/livewire/` 一條都比對不到。

HTML 殼還是回 200，所以表面上看起來「有在跑」。

edge 的修法：

```nginx
location ~ ^/livewire(-[0-9a-zA-Z]+)?/ {
    include /etc/nginx/conf.d/pm-php.inc;
}
```

加上 `/js/` `/css/` `/fonts/` `/vendor/` `/build/` `/favicon.ico` `/robots.txt`
的 location。

---

### 登入卡在第一步，症狀看起來像 CORS

SPA 認證的第一步是 `GET /sanctum/csrf-cookie`。
edge 沒把 `/sanctum/` 路由給 PHP 的話它會落到 Nuxt → 404 →
瀏覽器 console 顯示的是 CORS 錯誤，因為 Nuxt 沒有回對應的標頭。

---

### 密碼重設信 / Filament 重導向少了 `:8080`

`X-Forwarded-Port` 沒有正確傳遞，Laravel 用 scheme 推出 80。

edge 的 `nginx.conf` 有三層 map：沒線索用 scheme 推 →
`Host:` 有埠就用它 → 上游給了合法的 `X-Forwarded-Port` 就沿用。

同時 `src/backend/bootstrap/app.php` 要有 `trustProxies` 並限制在私有網段 ——
不設定的話 Laravel 不信任任何 `X-Forwarded-*`，設成全部信任則是另一個極端
（任何人都能用 `X-Forwarded-Host` 偽造密碼重設信裡的網址）。

---

### 某個路徑的安全標頭全部消失

nginx 的 `add_header` **不是累加的**。任何一個 `location` 只要有自己的
`add_header`，它就會丟掉所有從 `server` / `http` 繼承來的。

而且測其他路徑完全看不出來。

修法：安全標頭放進一個 `.inc`，每個需要的 location 各自 include 一次。

---

### 刪掉 node_modules 之後，dev 的 `/` 變 500 但 `/admin` 正常

```
[nitro] ERROR RollupError: Could not resolve entry module
        "node_modules/nitropack/dist/presets/_nitro/runtime/nitro-dev"
```

在 dev 容器**正在跑**的時候刪掉 host 的 `src/frontend/node_modules` 造成的。
`/admin` 走 PHP 所以不受影響，很容易誤判成「前端的程式碼壞了」。

```bash
cx setup deps          # 先把 node_modules 裝回來
cx dev restart nuxt    # 再讓 dev server 重新解析模組
```

---

### `ViteManifestNotFoundException`

`welcome.blade.php` 有 Vite 指令，但 `src/backend/public/build/manifest.json`
不存在 —— 後端資產從來沒被建置過。

```bash
cx npm --backend ci
cx npm --backend run build
```

（舊專案的 `init.sh` 呼叫一個叫 `npm-php` 的 compose service，
但那個 service 從來沒有存在過。）

---

### `Cannot find module '@rolldown/binding-linux-x64-musl'`

`src/backend/node_modules` 的原生模組是照安裝當下的 libc 編的。
host 是 Ubuntu（glibc），掛進 Alpine（musl）容器就爆。

訊息指向 npm 的 optional dependencies bug，其實只是 libc 不匹配。

`cx npm --backend` 優先用 host 的 npm，沒有的話用
`node:24.20-bookworm-slim`（glibc），兩條路產生的 `node_modules` 可以互通。
**不要**改用 Alpine 的 node 映像 —— 那會產生一份只有 Alpine 能用的
`node_modules`，之後在 host 上 `npm run build` 又會壞，錯誤訊息一模一樣。

---

### 測試打到了真的資料庫

`phpunit.xml` 的 env 項目沒有 `force="true"` 時，只在該變數**尚未存在**時才生效。
CI 或 shell 裡有同名變數就會被沿用，而且測試會通過 ——
直到某一次它清空了正式資料。

14 個 env 項目全部要有 `force="true"`。
`cx test back` 另外再傳 `-e DB_CONNECTION=sqlite -e DB_DATABASE=:memory:`。

---

### test 模式打到了 prod 的 API

`spa` / `static` 模式的 API base URL 是 **build 時烘進 bundle** 的。
映像 tag 沒有含模式（例如 `pm/nuxt:latest`）時，`cx test up`（沒加 `--build`）
會直接拿到 prod 建好的那一份。

`-p` 隔離容器與網路，**不隔離映像 tag**。tag 要寫成 `pm/nuxt:test-prod-ssr`。

---

## Ansible

### `apply` 回報成功但什麼都沒做

`--yes` 是全域旗標，放在動詞後面會被當成 `--limit` 的值，
而 ansible 對「比對不到任何主機」只印 warning、退出碼 0。

```bash
cx deploy apply --yes     # ✘
cx --yes deploy apply     # ✔
```

現在 `cx` 會直接擋下 `-` 開頭的限制參數。

---

### `MySQL 執行期設定與預期不符`，但 zz-app.cnf 明明是對的

handler 通知**不會跨 play 保留**：

1. 部署寫入 `zz-app.cnf` → notify restart
2. 後面某個任務失敗 → play 中止 → handler 從未執行
3. 下一次部署：檔案已經一樣 → 回報 ok 而不是 changed → **永遠不再 notify**

而錯誤訊息把人導向去查 includedir（那是對的）。

現在 `verify.yml` 依執行期的實際值判斷：不一致就重啟再讀一次，
對了就什麼都不做（冪等）。

手動確認：

```bash
ps -eo pid,lstart,cmd | grep mysqld        # 行程啟動時間
stat -c %y /etc/mysql/conf.d/zz-app.cnf    # 設定檔寫入時間
```

設定檔比行程新 = 還沒重啟。

---

### `object of type 'dict' has no attribute 'query_result'`，只在第二次部署出現

被 `when` 略過的任務**照樣會寫入 register 變數**，寫進去的是
一個帶 `skipped: true` 的 dict。

於是「重啟後重讀」那個任務在不需要重啟時被略過，
卻把先前那次成功查詢的結果覆蓋掉。

修法：register 到另一個變數，block 內再 `set_fact` 覆寫。

---

### `'cryptography' package is required for sha256_password or caching_sha2_password auth methods`

MySQL 8.4 的 `caching_sha2_password` 在**非 unix socket** 的連線上要走 RSA 交換，
PyMySQL 把那一段委託給 cryptography。

缺了它，走 socket 的任務全部正常，**只有 TCP 127.0.0.1 會失敗** ——
看起來像授權沒建好。

目標機要裝 `python3-cryptography`（`common` 與 `mysql` role 都已經加了）。

---

### `regex_search` 丟 `'NoneType' object has no attribute 'group'`

`ansible.builtin.regex_search` **一旦帶了捕獲組參數**，在沒比對到的時候
不是回傳 None，而是直接丟例外。後面接的 `| default(...)` 根本沒有機會執行。

```yaml
# ✘ 第一次部署（檔案還不存在、內容是空字串）必定炸
{{ text | regex_search('APP_KEY=(.*)', '\\1') | default([''], true) | first }}
```

**加 `when: text is search(...)` 擋不住它。** `set_fact` 的參數是在
「finalization」階段求值的，比 `when` 更早 —— 實測加了 `when` 之後同一行照樣炸。

可靠的修法是**完全不用捕獲組**，改成純字串管線：

```yaml
- name: 取出所有 APP_KEY= 的值
  ansible.builtin.set_fact:
    lines: >-
      {{ text.splitlines()
         | map('trim')
         | select('match', '^APP_KEY[ ]*=')
         | map('regex_replace', '^APP_KEY[ ]*=[ ]*', '')
         | map('trim')
         | map('trim', '"')
         | list }}

- name: 取最後一個（dotenv 語意：同鍵重複時後面的贏）
  ansible.builtin.set_fact:
    result: "{{ (lines | last) if (lines | length) > 0 else '' }}"
```

`regex_replace` 沒有這個問題（它永遠回傳字串），`select('match', ...)` 也沒有。

順帶一提反斜線：正則放在 **YAML 的單引號**裡不會被轉義（`\t` 原樣送給 re），
但反向參照要寫成 `\\1` —— 那個字串還要再經過 Jinja（Python 字面值規則），
單寫 `\1` 會變成 `chr(1)`。這也是為什麼能不用捕獲組就不要用。

---

### `Failed to find required executable "debconf-get-selections"`

在 `debconf-utils` 裡，Ubuntu 的 minimal 映像預設不裝，
而錯誤訊息完全不提套件名。

---

### `mv: missing destination file operand after '...'`（Ansible 的 shell 任務）

YAML 的折疊純量（`>-`）規則是「**比區塊縮排更深的行保留換行**」。
所以把續行縮得比第一行深，指令會被切成兩行：

```yaml
cmd: >-
  ... && /usr/bin/mv -f A
     B          # ✘ 縮得更深 → 這裡會保留換行
```

shell 收到的是 `mv -f A` 加上另一行 `B`。

續行一律與第一行**同縮排**。反過來說，如果你**要**換行
（例如 awk 程式、if/else 分支），刻意縮深一格就是正確做法。

---

### `could not create work tree dir: Permission denied`

`releases/` `shared/` `current` 的骨架要先建好且 owner 是 deploy，
否則 `deploy_frontend` 以 deploy 身分 clone 時父目錄是 root 所有。

這就是 `common` role 必須第一個跑的理由之一。

---

### `FPM initialization failed`（`Unable to create or open slowlog`）

`/var/log/php` 要在 php-fpm 啟動之前存在。同樣由 `common` role 負責。

---

### nginx 一直 emerg，但設定看起來沒問題

兩種可能：

1. vhost 片段用了 `validate` 搭配 `nginx -t -c %s` —— `-c` 把片段當成完整主設定，
   沒有 events 區塊就 emerg。片段不要驗證，最後跑一次不加 `-c` 的 `nginx -t`。
2. 第一次部署時 vhost 引用了還不存在的 ACME 憑證。
   nginx role 必須用 `ssl-cert` 的 snakeoil 憑證開機。
   否則 `any_errors_fatal` 會讓 certbot 永遠跑不到 —— **死結**。

---

### `[emerg] "client_max_body_size" directive is duplicate`

發行版打包的 `/etc/nginx/nginx.conf` 在 `http{}` 裡已經宣告過同一個指令，
而我們的片段是被 include 進**同一個** `http{}`。nginx 對同層重複是 emerg，
不是 warning。

而且 `nginx -t` **只回報第一個錯誤** —— 修掉 `client_max_body_size`
還有 `gzip`、`gzip_vary`、`client_body_timeout`… 一個一個來。

修法不是寫死清單（哪個打包宣告了什麼不可預測），而是 `facts.yml`
讀一次 `nginx.conf` 把已宣告的指令名撈出來（`nginx_existing_directives`），
模板再逐一跳過。

跳過是安全的：這些值 vhost 的 `server{}` 都會再寫一次（server 覆蓋 http）。
真正只能待在 http context 的東西（`upstream` / `map` / `limit_req_zone` /
`log_format`）不在跳過清單裡，永遠照常輸出。

---

### 憑證簽發成功了，瀏覽器還是說憑證錯誤

第一次部署的正常中間狀態：nginx（snakeoil）跑在 certbot（簽發）之前。

```bash
cd ansible && ansible-playbook site.yml --tags nginx
```

`site.yml` 的 post_tasks 會用 `nginx -T` 偵測這個狀態並提醒你。

---

### healthcheck 說 queue worker 掛了，`systemctl list-units` 卻是 active

unit 名稱被組成字面的 `pm-queue@\1.service`（反向參照沒展開）。
`systemctl is-active` 對一個不存在的 unit 回非 0 → 報「掛了」。

成因是用 `regex_replace` 的反向參照去組名稱，而前綴本身是巢狀 template：

```yaml
# ✘
{{ range(1, n+1) | map("string")
   | map("regex_replace", "^(.*)$", backend_queue_unit_prefix ~ "\\1.service") }}
```

改成純字串串接就沒有任何轉義問題：

```yaml
# ✔
- ansible.builtin.set_fact:
    units: "{{ units | default([]) + [prefix ~ item ~ '.service'] }}"
  loop: "{{ range(1, n+1) | list }}"
```

**能不用捕獲組就不要用。**

---

### `pm2-<user>.service`：`Can't open PID file ... pm2.pid (yet?) after start`

`pm2 startup systemd` 產生的單元是 `Type=forking` + `PIDFile=$PM2_HOME/pm2.pid`，
但 **PM2 v7 的 God Daemon 不寫那個檔**（實測 v7.0.4：daemon 明明在跑，
`$PM2_HOME` 底下只有 `pids/` 目錄）。

於是 systemd 判定：

```
pm2-deploy.service: Failed with result 'protocol'
pm2-deploy.service: Start request repeated too quickly
```

**兩種情境都會踩到**：

1. `dump.pm2` 是空的（第一次部署，前端還沒 build）→ `resurrect` 什麼都沒接管
2. `dump.pm2` 有內容，但 daemon 已經被 `pm2 startOrReload` 先起來了

修法是一個 drop-in（不改 unit 本體，下次 `pm2 startup` 重跑不會被蓋掉）：

```ini
# /etc/systemd/system/pm2-deploy.service.d/10-pm.conf
[Service]
Type=oneshot
RemainAfterExit=yes
PIDFile=
Restart=no
```

`ExecStart` 只負責把 dump resurrect 回來，跑完就結束；daemon 的存活由 PM2 自己負責，
healthcheck 另外驗 process 清單。開機自動起來的能力（`enabled`）完全不受影響。

另外，部署流程要在「process 已經 online、`pm2 save` 也跑完」之後才
`state: started` —— 那時 dump 才是這一版的內容。

---

### healthcheck 的 app 層重試 12 次才失敗，訊息指向 PHP / nginx

```
Status code was -1 and not [200]: Request failed:
<urlopen error [Errno -2] Name or service not known>
```

`-1` 不是 HTTP 狀態碼，是「連都連不上」。這裡是**目標機自己**解析不到 `app_domain`。
DNS 不存在再重試幾次都一樣，白花一分多鐘，而錯誤提示會把人導向 PHP 與 nginx。

現在 `prepare.yml` 會先 `getent hosts` 問一次，解析不到就跳過 app 層並說明原因。
edge 層（`127.0.0.1` + `Host` 標頭）本來就涵蓋「nginx 到應用」，
跳過的只有「DNS 與對外路徑」。

要讓 app 層真的跑：把網域指到那台機器（公開 DNS，或目標機的 `/etc/hosts`）。

---

### 間歇性 502

`pm2_instances` 與 `frontend_instances` 用 YAML anchor 綁在一起。
環境別的檔案只覆寫其中一個時，PM2 起 N 個 process 但 nginx upstream 只有 M 個。

preflight 會斷言兩者相等。

---

### `ERR_REQUIRE_ESM`

PM2 的 cluster 模式走 CJS require，載不動 Nuxt 的 ESM `.mjs`。
只能用 fork。preflight 會斷言。

---

### migration 一次都沒跑，網站停在 `Base table or view not found`

`db_primary` 那台不在 `web` 群組裡。
migration 用群組 gate（`inventory_hostname in groups['db_primary']`），
而 `deploy_backend` 只在 `web` 執行 —— 兩者沒有交集就等於沒人跑 migration，
**而且不會有任何錯誤訊息**。

preflight 會斷言。

（不用 `run_once` 的理由：`serial` 不是 100% 時 `run_once` 的作用域
變成「當前 batch」，等同 no-op，而且每個 batch 都宣稱自己是 run_once。）

---

### ansible-lint 回報 800 多個 finding

它掃到了 `collections/` 底下的上游 collection 原始碼。

`bin/lib/ansible_lint.py` 已排除 `collections`、`.cache`、`.ansible`、
`.git`、`__pycache__`。

---

## 測試

### 在容器裡直接跑 `php artisan test`，結果打到真的開發資料庫

`src/backend/phpunit.xml` 裡每一個 `<env>` 都寫了 `force="true"`，看起來已經把
`DB_CONNECTION` 釘死成 `sqlite`。**在容器裡它是無效的。**

PHPUnit 的 `force` 只寫 `putenv()` 與 `$_ENV`，不寫 `$_SERVER`；
Laravel 的 `Env` 讀取順序是 `ServerConstAdapter($_SERVER)` 先於
`EnvConstAdapter($_ENV)`。compose 的 `environment:` 讓 `$_SERVER` 一定有值，
所以 `$_SERVER` 的 `mysql` / `database` 永遠贏過 phpunit.xml 的 `sqlite` / `array`。

怎麼確認你中了這一招：

```bash
cx dc exec -T app php -r 'echo $_SERVER["DB_CONNECTION"], " / ", $_ENV["DB_CONNECTION"], "\n";'
```

兩邊都印 `mysql` 就是了。真正擋住這件事的是 `bin/cmd/test.sh` 的
`_test_env_pairs` —— `cx test` 會把同一份設定用 `-e` 傳進去蓋掉 `$_SERVER`。

**所以：跑測試一律用 `cx test back`，不要在容器裡裸跑 `php artisan test`。**
目前的測試都沒有用 `RefreshDatabase`，所以還沒有造成損失；
一旦有人加了一個，裸跑就會清空開發資料庫。

### `cx test coverage` 明明有測試失敗卻回傳 0

2026-09-04 修掉。原因是函式最後一個指令是 `docker cp` / `cx_ok`，
測試的退出碼被覆蓋掉 —— 在 CI 上就是一個永遠綠的步驟。

現在會印 `✘ 後端測試失敗（rc=N）—— 覆蓋率報告仍已產生` 並回傳該碼。
報告仍然會搬出來，因為**測試失敗的時候 junit 報告才是最有用的**。

自己驗一次（放一個故意失敗的測試，看 rc）：

```bash
printf '<?php\nnamespace Tests\\Unit;\nuse PHPUnit\\Framework\\TestCase;\nclass TmpFailTest extends TestCase { public function test_x(): void { $this->assertTrue(false); } }\n' > src/backend/tests/Unit/TmpFailTest.php && cx test coverage; echo "rc=$?"; rm src/backend/tests/Unit/TmpFailTest.php
```

### `cx test coverage` 噴 `fopen(/tmp/junit-backend.xml): Permission denied`，rc=255

舊版把報告寫到容器裡固定的 `/tmp/<檔名>`。`/tmp` 是 `1777`，
之前以 root 跑過留下的同名檔，uid 1000 既不能覆蓋也不能刪。
更糟的是後面的 `docker cp` 仍然會成功，把**上一次的舊報告**複製出來並印 ✔。

現在每次執行用獨立目錄 `/tmp/cx-cov-$$`，跑完刪掉。
如果你還留著舊的殘骸：

```bash
docker exec -u 0 $(cx dc ps -q app) rm -f /tmp/coverage-backend.xml /tmp/junit-backend.xml
```

### `--runner native` 跑測試噴 `.phpunit.result.cache: Permission denied`

容器路徑以 root 在 bind mount 的 `backend/` 裡留下 `root:root` 的檔案，
原生 runner 以 uid 1000 執行就寫不進去。同樣的原因也會讓
`src/backend/storage/` 多出 root 擁有的 `coverage-backend.xml` / `junit-backend.xml`，
在 submodule 裡變成刪不掉的未提交變更（`cx fresh` 的 preflight 會抓到）。

現在容器路徑用 `-u $(id -u):$(id -g)` 執行 —— `src/backend/storage` 與
`bootstrap/cache` 本來就屬於 uid 1000，所以是安全的。清掉舊殘骸：

```bash
docker exec -u 0 $(cx dc ps -q app) sh -c 'rm -f /var/www/html/.phpunit.result.cache /var/www/html/storage/*-backend.xml'
```

## 權限（ACL）

### `cx acl apply` 噴 `Operation not permitted`

```
setfacl: src/backend/bootstrap/cache/packages.php: Operation not permitted
```

`setfacl` 需要**檔案的擁有者或 root** —— 同群組、甚至有寫入權都不夠。
樹裡只要有一個別人的檔案，`setfacl -R` 就會停在那裡，
前面設好的留著、後面的沒設到（半套狀態最難查）。

來源幾乎都是同一個：容器的 entrypoint 以 root 執行，
`artisan package:discover` 與 `storage:link` 在 bind mount 裡留下 `root:root`。

```bash
find backend frontend -not -user "$(id -u)" -printf '%u:%g %p\n'
cx acl fix-owner          # 列出、確認、才 sudo chown
```

entrypoint 已經修好（生成後立刻 chown 回 `www-data`，symlink 用 `-h`），
所以新環境不會再產生。上面那個指令是清既有殘骸用的。

以 root 執行（`sudo cx acl apply`）時不做這個檢查 —— root 本來就設得動任何檔案。

### `cx acl apply` 成功，但 `cx acl check` 說沒生效

2026-09-05 修掉。`getfacl` 預設印**名稱**（`user:sixtou:rwx`），
而 web 身分來自 `.env` 的 `APP_UID` 是**數字** ——
拿 `1000` 去 grep 名稱永遠不會中。現在比對一律正規化成 uid（`getfacl -n`）。

如果你還看到這個症狀，先確認 `cx` 是最新的。

### `getfacl /srv/pm/backend` 回 `Permission denied`

**這不是故障，是設計要的效果。** `others` 被設成 `0`，
而你用的帳號既不是 `deploy` 也不是 `www-data`。用 `sudo` 或 `-b` 再看：

```bash
ansible <host> -b -m shell -a 'getfacl -p /srv/pm/backend/shared/storage'
```

`/srv/pm` 的 `drwxr-s---+` 結尾那個 `+` 就是「有 ACL」的標記。

### 設了 ACL 但 web 還是寫不進去

兩個可能，`ansible` 的 `ACL | 驗證 www-data 真的能寫 storage` 那個 task
的失敗訊息就會指出來：

```bash
findmnt -no SOURCE,FSTYPE,OPTIONS -T /srv/pm     # 掛載選項有 noacl？
namei -l /srv/pm/backend/shared/storage          # 哪一層少了 x？
```

`cx acl` 在本機也會先探測檔案系統支不支援 ACL —— 少了那個檢查，
`setfacl` 只會回 `Operation not supported`，看不出是掛載問題。

## 掃描

### Semgrep 掃描很慢、finding 很多

`.semgrepignore` **必須在專案根目錄**。Semgrep 只在掃描目標的根目錄找它，
放在別處**不會有任何警告**。

---

### `cx scan sast` 每次都紅

不要用 `semgrep --error`（任何 finding 都回傳非零，INFO 等級的風格建議
跟 SQL injection 同等對待）。

現在是 SARIF + `bin/lib/sarif_gate.py` 分級，只有 error 等級會擋。

---

### ZAP 掃出零個 alert，而且很快

目標可能根本沒起來。**cx 目前沒有前置可達性檢查**（`_scan_dast_probe` 是兩輪掃描之後才跑的 WAF 攔截率探針，不是這件事），所以這個症狀是真的會發生的。確認方法：`cx --mode test ps` 看 waf 在不在，再看 `reports/dast/detect/report.json` 有沒有掃到任何 URL。

也檢查退出碼：3 以上是工具本身出錯，不是「沒有漏洞」。

---

### SonarQube 沒設定，整個 `cx scan code` 直接消失

早期版本用 `${SONAR_TOKEN:?}` —— 在 `set -u` 之下 `:?` 直接讓整個 shell 結束，
連錯誤訊息都印不出來。

現在從 `.cx/sonar-token` 讀，沒有就跳過 Sonar 那一段，Larastan 照跑。

---

## Git

### push 被拒絕

唯一合法的遠端是 `github.com/Information-Study/` 底下的三個 repo。
舊的組織永久禁止，**沒有任何旗標可以覆寫**。

`cx git status` 會列出三個 repo 的遠端與上游。

---

### 祕密掃描說「未發現問題」但你知道有問題

早期版本的內容層沒有先 `cd` 進 repo，於是兩個子模組實際上掃了零個檔案，
輸出卻完全正常。已修正，並用植入的假憑證驗證過。

---

### `cx git sync` 之後剛剛的提交不見了

早期版本用 `git checkout -q "$b"`。本地分支落後 gitlink 時，
它會靜默把工作區切到舊的 commit —— 看起來成功。

現在是 `git checkout -q -B "$b" "$head"`。

---

### 別人 clone 下來 `submodule update` 失敗

主庫的 gitlink 指向遠端不存在的 commit —— 推送順序反了。

必須**子模組先推、主庫後推**。`cx git push` 會強制這個順序，
任何子模組推失敗就中止，推完還會用 `git ls-remote` 驗證每個 gitlink
在對應的遠端真的存在。

---

## 備份與清理

### `cx fresh` 的備份「驗證通過」但還原不出來

`git bundle verify` **只讀 header**，一個被截斷的 bundle 它照樣說 OK。

現在的驗證會真的解一次（`git init --bare` 之後 fetch），
每個 tar 也都 `tar -tzf` 過一遍，而且從 MANIFEST 推導出**預期產物清單**逐一比對
—— 不是「檔案存在就算數」。

---

### `cx install --dry-run` 把 `~/.bashrc` 清空了

附加重導向在指令執行**之前**就先建立。
`cx_run` 印出 dry-run 訊息而不執行時，重導向已經生效了。

已修正：`--dry-run` 完全不碰 `~/.bashrc`，真實路徑也是先寫暫存檔再複製。

---

## 還是查不出來

```bash
cx doctor
cx <模式> config
cx <模式> logs -f <服務>
cx <模式> dc exec app supervisorctl status
cx <模式> dc exec edge nginx -T
cx verify all --report /tmp/v.md
cd ansible && ansible-playbook site.yml --check --diff --limit <主機> -vvv
```

`claude.md` §12 有「已知未驗證項目」的清單。
