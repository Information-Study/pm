# `cx verify` 的檢查目錄

每一列：**ID → 盯什麼 → 壞掉時的症狀**。
「症狀」那一欄是這份文件的重點 —— 檢查存在的理由是「這件事壞掉的時候
看起來不像壞掉」，而不是「這件事很重要」。

```bash
cx verify                        # 預設：cli docs tui static app ansible
cx verify cli docs tui           # 秒級，什麼都不用裝
cx verify all                    # 以上再加 runtime waf acl
```

**判準是 FAIL = 0 且 SKIP 沒有增加** —— 退出碼只看 FAIL，
所以「檔案讀不到 → PASS 變 SKIP」是一種不會變紅的失敗。

---

## `cli` — 命令列的自我一致（`bin/lib/verify_meta.py`）

| ID | 盯什麼 | 壞掉的症狀 |
|---|---|---|
| `CLI-verbs` | 補全宣告的動詞都有實作檔 | dispatcher 指向一個不存在的檔 → `cx up` 回「未知的指令」（實際發生過：8 個動詞指到從未寫出來的 `compose.sh`） |
| `CLI-orphan` | 每個實作檔都有動詞叫得到 | 寫了但沒人叫得到的死碼 |
| `CLI-help` | `help` 有寫到每個動詞 | 動詞存在但沒人知道 |
| `CLI-flags` | usage 宣傳的旗標 parser 都接受 | 文件說有、打了卻報錯 |
| `CLI-setup` / `CLI-setup-comp` | `setup` 的工具清單三處一致 | 補全補得出來、實際跑會說「未知的工具」 |
| `CLI-bats` | bats 檔真的接在 `cx test cli` 上 | 測試寫了但從來沒被執行 |
| `GIT-subs` | `cx git` 子指令**四方**一致（dispatch / usage / 補全 / help） | 少一方就會有「usage 宣傳了不存在的子指令」或反過來 |
| `GIT-branch-model` | `.cxroot` 的 `CX_GIT_*` 有人讀、且讀取端沒有寫死預設 | 那兩個值退化成裝飾（`git.sh` 原本有六處寫死 `main`） |
| `GRD-wire` / `GRD-files` / `GRD-layer2` / `GRD-cxtest` | 測試資料庫防護的四個零件都還接著 | **裸跑 `php artisan test` 會打到真的 dev MySQL**（`phpunit.xml` 的 `<env force>` 在容器裡是無效的） |
| `LNT-eslint-*` | ESLint 真的接上了 | `cx lint js` 什麼都沒檢查卻回 0 |
| `TPL-name` / `TPL-env` / `TPL-sonar` / `TPL-ansible` | 專案識別四處與 `.cxroot` 一致 | 改名之後某一處還是舊名字 |
| `TPL-group` | 作用群組名**三方**一致（`site.yml` / `deploy.sh` / `inventory.py`） | 改名後 `cx deploy ping` 比對到 0 台主機，**而 ansible 對此只印 warning 並回 0** |
| `A13-parity` | Docker 與原生把**同一組前綴**交給 PHP | 某路徑在一邊正常、另一邊 404，而且看起來像「應用壞了」 |
| `SEC-pma-auth` | phpMyAdmin 保留登入認證 | 未認證的請求拿到以 root 登入的頁面（2026-09-05 實際發生） |
| `SEC-logdir-mode` | 日誌目錄不對 web 群組開放寫入 | 提權面 |
| `LAY-legacy` | 全樹沒有殘留的舊版面路徑（**三類**，見下） | 漏改一處不會有人告訴你 |
| `LAY-ignore` | `src/` 不可被 ignore、祕密檔必須被 ignore | **SSH 公鑰進 PUBLIC 歷史**（gitleaks 抓不到這一類） |
| `LAY-version` | `.cxroot` 與 `common.sh` 的版號雙向一致 | 版號退回裝飾 |

### `LAY-legacy` 抓的三類，以及為什麼要三類

2026-09-06 的雲端複審在 v3 遷移完成、`LAY-legacy` 全綠之後，
還抓到**八處**它完全看不到的漏網。三類的分工是那次的結果：

| 類 | 形式 | 例 |
|---|---|---|
| ① 帶子路徑的字面 | `docker` 接 `/compose/`、`ansible` 接 `/site.yml` | 掃**含 `.md`**（文件裡的舊路徑會讓人 cd 到不存在的目錄） |
| ② 裸名字組出來的路徑 | `Path(root, "docker")`、`os.path.join(root, "backend")`、`=("backend" "frontend")`、ignore 檔的行首 `ansible/` | 只掃**非註解的程式碼行** |
| ③ 混雜與迴圈變數 | `for p in backend src/backend/storage frontend`、`for c in backend frontend` 的迴圈體裡 `$CX_ROOT/$c` | **有狀態掃描**（`_legacy_shell_loop_hits`） |

為什麼第三類不能用單行 regex：

* `for c in backend frontend` 是**名字**的清單，本身完全正當 ——
  `git.sh` / `archive.sh` / `guard.sh` 的迴圈體都是 `$(cx_sub_path "$c")`。
  第一版把它列進 regex，44 處命中裡有 36 處是誤判。
  要抓的是「名字**被拿去組路徑**」那一行，不是宣告名字那一行。
* `$CX_ROOT/$p` 的 `$p` 可能是子模組名（`acl.sh`）也可能是完整相對路徑
  （`doctor.sh` 的檔案清單、`common.sh` 的 bind mount 來源）。
  單行看不出差別，要記住迴圈宣告了什麼變數。
* 混雜清單（`for p in backend src/backend/storage … frontend`）**不能**套用
  「同一行有 `src/` 就跳過」的豁免 —— 混雜正是它要抓的東西。
  判準是「清單裡同時有帶斜線的元素與裸的 backend/frontend」。

> ② 與 ③ 刻意不掃 `.md` 與註解：它們偵測的是**程式碼裡的路徑用法**，
> 而描述這個問題本身的文字（`docs/cx/layout.md`、`verify_meta.py` 上方的
> 註解、這一節）必須寫得出舊形式。①（會誤導讀者的字面）才需要掃文件。

## `docs` — 文件與實作一致

| ID | 盯什麼 | 壞掉的症狀 |
|---|---|---|
| `DOC-cx-verbs` | `cx-reference` 涵蓋每個動詞 | 動詞沒有文件 |
| `DOC-index` | `claude.md` / `docs/README.md` / `README.md` 三份索引涵蓋 `docs/**` | 文件存在但沒有人找得到 |
| `DOC-filemap` | `claude.md` 的檔案地圖對得上 `bin/cmd` 與 `bin/lib` | 新人理解專案的第一張圖過期，而且看起來完全正常 |
| `DOC-testcount` | 文件寫的 bats 案例數與實際相符 | 寫死的數字必然過期 |
| `DOC-verify-scopes` | `help` 宣傳的 verify 範圍涵蓋實作 | |
| `DOC-ansible-run` / `DOC-claude-run` | 文件的「還沒在真機跑過」與實測紀錄不矛盾 | 三份文件不可能都對 |
| `DOC-ansible-vars` | README 教的變數真的被 role 讀取 | 教了一個沒有作用的旋鈕 |
| `DOC-groupvars` / `DOC-livewire` | 文件指向的路徑與前綴形狀正確 | |
| `ANS-split` | A15 斷言與 `deploy_backend` 的 gate **同一個群組** | **migration 一次都不跑，而且 ansible 全綠**，網站停在 `Base table or view not found` |

> **`read_required()` 與「整列消失」。**
> 必填文件讀不到時，這些檢查會印 **FAIL 那一列**而不是靜默略過。
> 區分兩種缺席：全樹找得到同名檔 = 搬過家 = FAIL 並指出新位置；
> 全樹都沒有 = 這棵樹本來就沒這份文件 = SKIP。
> 原本的寫法（`if ref and comp:`）會讓 `DOC-cx-verbs` **整列從報告消失** ——
> 而退出碼只看 FAIL，於是報告全綠而那件事已經沒有人在驗。
> **少一列比多一列紅難發現得多。**

## `tui` — 選單可達性

| ID | 盯什麼 | 壞掉的症狀 |
|---|---|---|
| `TUI-resolve` | 選單項目指得到實際存在的指令與子指令 | 選了之後跳出「未知的指令」 |
| `TUI-coverage` | **三個模式的聯集**涵蓋每個非豁免動詞 | 見下 |

> `check_tui` 是**靜態 regex 剖析**，看不到 `$_TUI_MODE`。
> 主選單開始依模式隱藏項目之後，舊的算法會**照樣 PASS 但不再證明任何事**。
> 現在它對三個模式各走訪一次選單圖，並把每個模式各能到幾個印在備註裡。
> 模式門檻用 `tui.sh` 的 `# @tui-mode:` 標記表示；**標記整個消失時會 FAIL**。

## `smoke` — 唯讀動詞真的跑得起來（`bin/cmd/verify.sh`）

其餘每一個範圍驗的都是「設定對不對」與「跨檔一致不一致」，
**沒有一個真的把動詞叫起來**。`00_dispatch.bats` 有「每個動詞的 `--help`
都跑得起來」，但 `--help` 只證明檔案 source 得進來、函式定義得出來 ——
它走不到任何一條實際的程式路徑。

| ID | 盯什麼 | 壞掉的症狀 |
|---|---|---|
| `smoke-verbs` | 15 個唯讀動詞 rc=0 **且 stderr 沒有 bash 錯誤** | 見下 |
| `smoke-open-pma` | `cx open pma` 與 `cx pma` 給出**完全相同**的網址 | 埠推導被複製了一份，兩邊各自演化然後給出不同的答案 |

> ⚠ **只看退出碼是不夠的。**
> command substitution 的失敗**不會**傳播到呼叫端，而 `cx status` 到處都是
> `printf '%s' "$(某個函式)"` 這種形式，加上它的契約是「從不失敗」
>（最後一律 `return 0`）。兩者相加的結果是：內部函式炸了
>（unbound variable、指令不存在），錯誤訊息吐到 stderr，而**動詞仍然 rc=0**。
>
> 2026-09-06 的 `cx status` 第一版就是這樣：
> `local c=$1 d="$CX_ROOT/$c"` 在 `set -u` 之下 unbound
>（bash 的 `local` 先宣告全部名字再依序賦值），
> 畫面上少了兩行，退出碼完全正常。
> 所以這個範圍同時 grep stderr 的 `unbound variable` / `command not found` /
> `syntax error` / `No such file or directory`。

**只跑唯讀的動詞。** 會改東西的（`up` / `down` / `commit` / `push` /
`apply` / `fresh`）不在這裡 —— 驗收不該有副作用。

## `static` — 合併後的 compose（`bin/lib/verify_checks.py`）

`cfg` / `cfg-<模式>`、`2.1`–`2.5`、`3.1`–`3.8`、`4` / `4b`、
`D1` `D7` `D9`–`D15`、`A16`、`sec-appkey`、`sec-ignore`、`hard-caps`、`hard-stop`。
ID 對應 [`../docker-verification.md`](../docker-verification.md) 的缺陷編號。

代表性的幾條：

| ID | 盯什麼 | 壞掉的症狀 |
|---|---|---|
| `2.2b` | base 檔沒有 `ports:` | compose 的 ports 是**附加**不是覆寫 → 第二個模式 `port is already allocated` |
| `3.1` | 映像 tag 含模式 | test 與 prod 共用 tag → 測試環境打到正式 API（spa/static 的 API base URL 是 build 時烘進去的） |
| `D13` | prod 不發布 DB 與管理工具 | 攻擊面 |
| `sec-ignore` | `.dockerignore` 擋得住子專案的 `.env` | 開發者的 `.env` 進映像 |
| `A16` | 上傳大小的限制鏈 nginx ≤ WAF | 大檔在一層被切、另一層才報錯 |

## `runtime` / `app` / `waf` / `acl` / `ansible`

需要對應的環境，缺了就 SKIP。

`rt-<模式>`、`D5-<模式>`（supervisord）、`D6-<模式>`（vendor）、
`D2-<模式>`（APP_KEY —— dev 查 `.env`，test/prod 查環境變數**且**容器內無 `.env`）、
`D12rt`（prod 執行期無 xdebug）、`db-<模式>`（migration 跑過）、
`ep-<模式>`（六個端點）、`waf-up` / `waf-engine` / `waf-block` / `waf-livewire`、
`acl-tools` / `acl-fs` / `acl-model`、`ans-syntax` / `ans-lint`。

---

## 新增一條檢查

1. 寫在 `verify_meta.py`（跨檔一致性）或 `verify_checks.py`（compose 設定）
2. 用 `row(狀態, ID, 標題, 備註)` —— **`_vf` / `row` 是唯一的產生者**
   （`80_verify.bats` 有案例盯這件事）
3. 註冊到 `main()` 對應的家族
4. **寫雙向 bats**：故意製造缺陷 → 必須 FAIL；修好 → 必須 PASS
5. 把它加進這份文件

第 4 項不是形式。這個專案已經有過「檢查存在但證明不了任何事」的實例
（`TUI-coverage` 在模式門檻之下、`DOC-cx-verbs` 在檔案搬走之後），
兩個都是全綠的。
