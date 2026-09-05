# 測試者指南

> **這份文件給誰看**：負責品質的人 —— 要跑測試、讀報告、決定一個分支能不能合併的人。
> 它不重述每個動詞的語法（那在 [`cx-reference.md`](cx-reference.md)），也不重述報告的
> 逐檔案讀法（那在 [`reports.md`](reports.md)）。這裡回答的是四件事：
> **該跑什麼、跑之前環境要滿足什麼、結果怎麼判讀、什麼條件才算放行。**
>
> 全文遵守本專案的紀律：**沒跑過的就寫沒跑過**。凡是標了「實測」的都指得到
> [`progress.md`](progress.md) 或 [`acceptance.md`](acceptance.md) 裡的日期與數字；
> 沒有證據的一律明說未驗證。

---

## 0. 三個動詞各自回答哪一個問題

這三個動詞常被混為一談，但它們的提問完全不同，混用會讓你以為驗過了其實沒有。

| 動詞 | 回答的問題 | 失敗代表什麼 |
|---|---|---|
| `cx test` | **這支程式的行為對嗎** | 應用或 `cx` 自己寫錯了 |
| `cx verify` | **這棵樹／這個環境組裝對嗎** | 兩個檔案對同一件事說法不一致，或環境與版控不符 |
| `cx scan` | **有沒有品質與資安問題** | 有 finding，或工具根本沒跑起來（兩者退出碼不同） |

`cx test cli` 的結果**刻意不餵進** `cx verify`：混在一起會讓預設的 `cx verify`
依賴 bats，於是在沒裝 bats 的機器上長出一條永久的黃線 —— 而 `cli` / `docs` / `tui`
三個範圍存在的理由正是「在什麼都沒裝的樹上也跑得完」。

### 退出碼（`bin/lib/common.sh`，`bin/test/10_exitcodes.bats` 釘住數值）

| 碼 | 常數 | 意義 |
|---|---|---|
| 0 | `EX_OK` | 通過 |
| 1 | `EX_FAIL` | 真的失敗（測試沒過、`cx verify` 有 FAIL） |
| 2 | `EX_USAGE` | 參數用錯 |
| 3 | `EX_PRECOND` | **前置條件不足 —— 環境問題，不是結果** |
| 4 | `EX_ABORT` | 使用者在確認閘門取消 |
| 20 | `EX_SCAN_QUALITY` | ① Quality 有 finding |
| 21 | `EX_SCAN_SAST` | ② SAST 有 **ERROR 等級** finding |
| 22 | `EX_SCAN_SCA` | ③ SCA 有 finding（**gitleaks 的祕密 finding 也用這個碼**） |
| 23 | `EX_SCAN_DAST` | ④ DAST 有 High risk alert |

> **CI 判斷式一定要把 3 單獨拉出來。** 把 `!= 0` 當失敗，「Semgrep 根本沒跑起來」
> 與「找到 SQL injection」在 CI 上會長得一模一樣；把 3 當通過，則是把「沒驗」記成
> 「驗過了」。這兩種誤讀是本專案最貴的兩種。

---

## 1. `cx test` — 測試套件

`test` 這個動詞身兼兩職：第一個參數落在 compose 動作白名單
（`up down restart ps logs sh build dc config`）就是 **test 模式的容器操作**，
否則才是**跑測試**。兩組沒有交集，所以不會有歧義。

```bash
cx test up -d --build      # 起 test 模式（含 ModSecurity WAF）—— 這是容器操作
cx test back               # 跑後端測試 —— 這是測試
```

### 1.1 子指令

| 子指令 | 別名 | 做什麼 | 需要容器嗎 | 需要什麼 |
|---|---|---|---|---|
| `back` | `backend` | `php artisan test` | 視 runner 而定 | **不需要 MySQL**（sqlite `:memory:`） |
| `front` | `frontend` | `nuxt typecheck` | 視 runner 而定 | 原生路徑需 `src/frontend/node_modules` |
| `all` | —（**預設**） | `back` + `front` | 同上 | 不含 `cli`，也不含 `coverage` |
| `coverage` | `cov` | 後端覆蓋率 | **一定要容器** | test 映像裡的 xdebug |
| `larastan` | `code` | 轉呼叫 `cx scan code` | 否 | host 的 `src/backend/vendor/bin/phpstan` |
| `cli` | `self` | `cx` 自己的 bats 行為測試 | 否 | `bats`（`cx setup tools bats`） |

不帶子指令的 `cx test` 等於 `cx test all`。

`cx test back --filter=User` 這類參數會原樣傳給 `php artisan test`。

#### 兩個容易踩的預設值

* **`cx test back` 預設打的是 dev 堆疊，不是 test 堆疊。** `CX_MODE` 預設 `dev`，
  而 `cx test <子指令>` 只有走 compose 那一支才會把模式固定成 test。要在 test 模式的
  容器裡跑後端測試，寫 `cx --mode test test back`。
* **`cx test larastan` 不只是 Larastan。** 它 source `bin/cmd/scan.sh` 之後直接呼叫
  `cmd_scan_main code`，也就是整條 ① Quality lane（Larastan **加上** SonarQube scanner，
  如果 sonar 網路在且拿得到 token）。因此它的失敗退出碼是 **20**，不是 1。
  另外 Larastan 走的是 **host 的 PHP**（`src/backend/vendor/bin/phpstan`），
  不進容器 —— 容器路徑沒有裝它。

### 1.2 測試資料庫的硬性防護（必讀）

這是本專案唯一一個「跑錯指令會刪掉開發資料」的地方，所以防護做了三層。

#### 為什麼需要它

`src/backend/phpunit.xml` 用 `<env force="true">` 把 `DB_CONNECTION` 釘成 `sqlite`、
`DB_DATABASE` 釘成 `:memory:`。**在容器裡那是無效的**，2026-09-04 實測確認：

```
PHPUnit 的 force  →  只寫 putenv() 與 $_ENV，不寫 $_SERVER
Laravel 的 Env    →  ServerConstAdapter($_SERVER) 排在 EnvConstAdapter($_ENV) 之前
compose 的 environment:  →  讓 $_SERVER['DB_CONNECTION'] 一定有值（mysql）
                          ⇒ $_SERVER 的 mysql 永遠贏
```

也就是說，在容器裡裸跑 `php artisan test`、`composer test` 或 `vendor/bin/phpunit`，
**測試會打到真正的開發資料庫**。目前沒有測試使用 `RefreshDatabase`，所以還沒造成損失；
一旦有人加了，裸跑就會清空開發資料庫（claude.md §0 紅線 5）。

#### 三個零件

| 零件 | 檔案 | 攔在哪裡 |
|---|---|---|
| 接線 | `src/backend/phpunit.xml` 的 `bootstrap="tests/bootstrap.php"` | 讓下面兩層有機會執行 |
| Layer A | `src/backend/tests/bootstrap.php` → `DatabaseSafetyGuard::assertProcessEnv()` | **每一個進入點**都會經過（`vendor/bin/phpunit`、`php artisan test`、`composer test`、`cx test back` 的兩條 runner） |
| Layer B | `src/backend/tests/TestCase.php` → `assertResolvedConfig($app)`，掛在 `createApplication()` | app boot 完之後的最終解析結果 |

Layer B **必須掛在 `createApplication()`，不能掛在 `setUp()`**。
`setUpTheTestEnvironment()` 的順序是 `refreshApplication()` → `createApplication()`，
然後才是 `setUpTraits()` —— 而 `RefreshDatabase` 是在 `setUpTraits()` 清庫的。
掛在 `parent::setUp()` 之後的檢查會在資料庫**已經被清掉之後**才跑，
那不是防護，是驗屍。

Layer B 看得到 Layer A 看不到的東西：`bootstrap/cache/config.php`
（`config:cache` 的產物）會把 `database.default` 釘死並完全繞過 `env()`。
所以錯誤訊息在這一層會建議你跑 `php artisan config:clear`。

#### 它擋什麼、放行什麼

判準不是「`DB_CONNECTION` 必須是 sqlite」，而是**「這次會真的連上的那個資料庫，
是不是宣告過的測試目標」**—— 白名單，不是黑名單。解析時會依序考慮
`DB_URL`（非空時優先，因為 `config/database.php` 每個連線都有 `'url' => env('DB_URL')`，
`ConfigurationUrlParser` 會用它覆寫 driver/host/database）、
`DB_CONNECTION`/`DB_HOST`/`DB_DATABASE`，以及 `DB_SOCKET`（非空且非 sqlite 時
`DB_HOST` 失去意義，會被記成 `unix:<socket>`）。

| 情況 | 結果 |
|---|---|
| `sqlite` + `:memory:` | 放行 |
| `sqlite` + 路徑含 `database/` 且副檔名 `.sqlite` | 放行（留給「需要保留資料的除錯」，不必關掉整個防護） |
| `APP_ENV` 不是 `testing` | **拒絕，且不可被放行清單覆寫** |
| 其他任何目標 | 拒絕，除非在 `PM_TEST_DB_ALLOW` 裡被**指名** |
| `DB_URL` 解析不出來 | 拒絕（未知的目標一律當成不安全） |

拒絕時的退出碼是 **3**（`DatabaseSafetyGuard::EXIT_CODE`），
與 `bin/lib/common.sh` 的 `EX_PRECOND` 同號 —— 讓 shell 與 PHP 兩邊詞彙一致：
**這是環境設錯了，不是測試失敗。** CI 上要能區分「測試紅了」與「根本沒跑對地方」。

拒絕訊息會並列印出 `$_SERVER` / `$_ENV` / `getenv()` 三個來源的值，
讓你「看見」`force="true"` 為什麼輸了 —— 而不是靠猜。

#### `PM_TEST_DB_ALLOW` 吃的是值，不是布林

```bash
# ✅ 正確：指名資料庫，逗號分隔多個
PM_TEST_DB_ALLOW=mysql://mysql-test/pm_test cx test back

# ✘ 無效：這不是開關。'1' 會被當成一個 URL 去解析，解析失敗就直接拒絕
PM_TEST_DB_ALLOW=1 cx test back
```

格式是 `driver://host/database`，逐項比對 driver、host、database 三者全等才放行。
理由寫在原始碼裡：`PM_TEST_DB_ALLOW=1` 會被某人寫進 `~/.bashrc` 然後永遠忘記；
要求指名資料庫，代表「放行開發庫」得真的寫出 `mysql://mysql/pm` ——
那是 greppable、reviewable，而且 code review 看得見的。

> 這個變數名是 `DatabaseSafetyGuard` 裡的常數字面值，**不會**隨 `cx rename` 改變。
> 範本化成新專案之後它仍然叫 `PM_TEST_DB_ALLOW`。

#### 已知的涵蓋範圍破洞

`phpunit --no-configuration` 或 `-c 別的.xml` **不會**載入 `tests/bootstrap.php`，
那兩種用法繞得過 Layer A，只剩 TestCase 的 Layer B。不 boot Laravel 的純 Unit 測試
在那種情況下完全不受保護。這一點寫在 `tests/bootstrap.php` 的註解裡，不是推測。

#### 防護本身由誰盯著

`cx verify cli` 的 `GRD-*` 四項：

| 檢查 ID | 盯什麼 |
|---|---|
| `GRD-wire` | `phpunit.xml` 真的 `bootstrap="tests/bootstrap.php"` |
| `GRD-files` | 兩個檔案都在，且 bootstrap 真的呼叫 `assertProcessEnv()` |
| `GRD-layer2` | Layer B 掛在 `createApplication()`，不是 `setUp()` |
| `GRD-cxtest` | `bin/cmd/test.sh` 的 env 清單仍導向 sqlite |

`GRD-wire` 是其中最重要的一項，因為它擋的是**最惡劣的一種失效**：
`cx fresh` 的疊回清單（`bin/cmd/fresh.sh` 的 `_fresh_keep_dirs`）帶 `tests`
但**不帶 `phpunit.xml`** —— 後者是骨架檔，重建時由 composer create-project
重新產生成 `bootstrap="vendor/autoload.php"`。於是 `tests/bootstrap.php` 與
`DatabaseSafetyGuard.php` 都疊回來了，檔案都在，但已經沒有任何人呼叫它們。

`fresh.sh` 現在在 carryover 疊回之後會自己把 `bootstrap=` 改回
`tests/bootstrap.php`，並在重建驗證階段用同一條斷言當後盾（`--mode scaffold`
只會警告，不自動改，因為那條路徑本來就是「全新骨架」）。`GRD-wire` 是這兩層之外
的最後一道：任何時候有人手改了 `phpunit.xml`，它下一次 `cx verify cli` 就會發現。

### 1.3 `cx test cli` — `cx` 自己的行為測試（bats）

```bash
cx test cli              # 跑完並把跳過數印出來
cx test cli --strict     # 有任何跳過就算失敗
CX_TEST_STRICT=1 cx test cli   # 同上，給 CI 用
```

`cx` 有 8000+ 行 bash，而 `cx lint sh`（shellcheck）與 `cx verify cli/docs/tui`
（跨檔靜態一致性）**都不執行任何 cx 程式路徑**。
`_setup_system_have` 少一個 `case` 分支是**完全合法的 bash** —— 靜態檢查抓不到，
只有真的跑一次才會現形。這就是這套 bats 存在的理由。

數量請自行核對：`grep -c '^@test' bin/test/*.bats`。
（寫死在文件裡的數字每加一個案例就過期一次，而且過期得毫無徵兆 —— 這一行本身
曾經長期停在 66，而實際早就不同了。`cx verify docs` 的 `DOC-testcount` 現在會盯著它。）
各檔涵蓋什麼見 [`cx-reference.md` 的 `cx test cli` 一節](cx-reference.md)，這裡不重複。

#### bats 把 skip 算成成功 —— 這與本專案的教條直接衝突

bats 的 TAP 輸出把 `# skip` 記成 `ok`，於是退出碼是 0。
本專案的原則是 **SKIP ≠ PASS**，兩者不能調和成同一個數字。

`_test_cli` 的處理方式是**不改 bats 的行為**（改了輸出就不再是標準 TAP，
下游任何吃 TAP 的工具都會壞），而是把數字講出來：

1. 捕捉整份輸出，`grep -c '# skip'` 數出跳過幾項；
2. 有跳過就 `cx_warn "N 個測試被跳過 —— 跳過不等於通過"`，並把每一行跳過的原因列出來；
3. `--strict` 或 `CX_TEST_STRICT=1` 之下，**有跳過就回傳 `EX_FAIL`**，即使 bats 自己回 0。

所以：**互動式跑不加 `--strict`（你要看得到跳過的原因），CI 一律加。**

#### bats 沒裝時的退出碼是 3，不是 1

```
⚠ bats 未安裝 —— 略過
  安裝： cx setup tools bats
```

回傳 `EX_PRECOND`（3）。CI 上這代表「這一關沒跑」，不是「這一關過了」，
也不是「這一關失敗了」。判斷式要照 §0 的規則把 3 單獨處理。

#### ⚠ `CX_TEST_NETWORK` 是同名不同義的兩個變數

| 用在哪 | 意義 |
|---|---|
| `bin/test/60_fresh.bats` | `=1` 才跑「重建需要網路」那一項，否則 `skip` |
| `bin/cmd/scan.sh` 的 `_scan_dast` | **ZAP 要加入的 docker 網路名**，預設 `<專案>_test_net` |

也就是說，為了讓 bats 那一項不被跳過而 `export CX_TEST_NETWORK=1`，
會讓同一個 shell 裡的 `cx scan dast` 去找一個叫做 `1` 的 docker 網路並以
`EX_PRECOND` 中止。要開就只開在那一次呼叫的前綴上：

```bash
CX_TEST_NETWORK=1 cx test cli     # 只影響這一次
```

### 1.4 `cx test coverage`

只有容器路徑（`--runner native` 會以 `EX_PRECOND` 硬失敗）——
test 映像裝了 xdebug 而原生 PHP 不一定有，而且用哪一版 xdebug 會影響覆蓋率數字的可比性。

流程上有三件事值得測試者知道：

* **`XDEBUG_MODE=coverage` 只對這一個行程臨時打開。** 常開會讓 ZAP 的時間量測失真。
* **報告先搬再回傳退出碼。** 測試失敗的時候 junit 報告才是最有用的，
  不能因為 rc 非 0 就跳過搬運。產物是
  `reports/quality/coverage-backend.xml`（Clover）與 `junit-backend.xml`。
* **它回傳的是測試的退出碼。** 2026-09-04 之前函式最後一個指令是 `docker cp` / `cx_ok`，
  於是「1 failed 1 passed」也回傳 0 —— 在 CI 上是一個永遠綠的步驟。
  現在會先 `cx_error` 再 `return $rc`。

前端**目前沒有測試框架**：`cx test front` 跑的是 `nuxt typecheck`，是型別檢查不是單元測試，
也不產生報告檔。`sonar-project.properties` 裡的 `coverage-frontend/lcov.info`
目前沒有任何東西會產生它 —— 這是已知的缺口，不是壞掉。

---

## 2. `cx verify` — 驗收

```
cx verify [範圍...] [--report <檔案>] [--quiet]
```

### 2.1 每個範圍需要什麼

| 範圍 | 需要 Docker daemon | 需要 `.env` | 需要容器在跑 | 其他 |
|---|---|---|---|---|
| `cli` | ✘ | ✘ | ✘ | 只讀檔案，秒級 |
| `docs` | ✘ | ✘ | ✘ | 同上 |
| `tui` | ✘ | ✘ | ✘ | 同上 |
| `static` | **✔** | ✔（沒有的話 compose 合併會少值） | ✘ | 吃 `docker compose config --format json` |
| `runtime` | ✔ | ✔ | **✔ 三個模式各自檢查，沒起來就 SKIP** | |
| `app` | ✔ | ✔ | ✔（edge 要回應 `/healthz`，否則 SKIP） | 用 host 的 `curl` |
| `waf` | ✔ | ✔ | **✔ test 模式** | 只有引擎是 `On` 時攔截項才有意義 |
| `acl` | ✘ | ✘ | ✘ | 需要 `setfacl` / `getfacl` |
| `ansible` | ✘ | ✘ | ✘ | 需要 `ansible-playbook`（`ansible-lint` 另計） |
| `all` | ✔ | ✔ | ✔ | = `cli docs tui static runtime app waf acl ansible` |

**省略範圍 = `cli docs tui static app ansible`。**

> ⚠ **`cx verify`（不帶範圍）需要 Docker daemon。** `static` 與 `app` 兩個範圍都會呼叫
> `cx_docker_need`，而它是 `exit "$EX_PRECOND"`（直接結束行程），不是 return ——
> 所以在沒有 Docker 的機器上，`cx verify` 會跑完 `cli docs tui` 之後於 `static` 這一步
> 以 rc=3 中止，**而且不會寫出報告**。在那種機器上要明寫範圍：
> ```bash
> cx verify cli docs tui        # 全新 clone、什麼都沒裝也跑得完
> ```

### 2.2 PASS / FAIL / SKIP 的三值契約

| 結果 | 報告符號 | 意義 | 影響退出碼嗎 |
|---|---|---|---|
| PASS | ✅ | **真的驗過了** | — |
| FAIL | ❌ | **真的壞了** | 是，任何一項 FAIL → `EX_FAIL`(1) |
| SKIP | ⬜ | **這次沒辦法驗** | **否** |

`cx verify` 的退出碼只看 FAIL 的數量（`(( _VF_FAIL == 0 )) || return "$EX_FAIL"`）。
**SKIP 不會讓它變紅，但也絕不等於通過。**

SKIP 只出現在誠實的情境，而且每一次都附理由：

| 典型的 SKIP | 備註會告訴你 |
|---|---|
| `rt-<模式>` | `app 容器沒在跑（cx <模式> up -d）` |
| `ep-<模式>` | `edge 沒有回應` |
| `waf-up` | `cx test up -d` |
| `waf-block` / `waf-livewire` | `引擎是 DetectionOnly，不是 On` |
| `ans-syntax` / `ans-lint` | `沒有 ansible` / `未安裝` |
| `acl-model` | `尚未套用（cx acl apply）—— ACL 是選用的` |
| `TPL-env` | `沒有 .env（跑 cx setup env）` |

**讀報告的正確方式是「通過 N ・失敗 0 ・未驗 M」三個數字一起看。**
只看「失敗 0」就簽字，是驗收報告最常見的誤讀 —— 一份 `通過 3 ・失敗 0 ・未驗 49`
的報告在退出碼上是綠的。

報告是一份帶時間戳的 Markdown：`reports/verify/<UTC 時間戳>.md`，
表頭會記下主機、Docker 與 Compose 版本，表尾重述「⬜（未驗）不等於通過」。
`--report <檔案>` 可以改路徑（相對路徑會被 `cx_resolve` 正規化）。

> **`--quiet` 已經實作**（2026-09-05）：PASS 與 SKIP 只累加不逐行印，
> **FAIL 一律照印**。安靜模式的用途是少看雜訊，不是把壞消息藏起來。
> 實測 20 行明細 → 1 行。
>
> 這一段原本寫的是「`--quiet` 只被解析、沒有被任何地方讀取」—— 那在當時是對的，
> 而且正是因為文件照實寫出來，那個缺陷才被發現並修掉。

### 2.3 各範圍實際在盯什麼

不逐項列（項目會長，以 `cx verify` 的實際輸出為準），只講**分類**，
因為那決定你什麼時候該跑它。

* **`cli`**（`bin/lib/verify_meta.py`）—— `cx` 自己的四方同步：
  補全宣告的動詞都有實作、每個實作檔都有動詞叫得到、
  `CX_SETUP_SYSTEM_TOOLS` 的每一項都有 `_setup_pkgs_for` 與 `_setup_system_have`、
  usage heredoc 宣傳的長旗標 parser 真的接受（轉發型動詞會被正確排除，
  否則會製造假警報，而**假警報比沒有檢查更糟**）、`help.sh` 提到每個動詞。
  另外還有 `GRD-*`（測試資料庫防護接線）、`CLI-bats`（`cx test cli` 的接線）、
  `LNT-eslint-*`、`TPL-*`（專案身分的四個第二事實來源與 `.cxroot` 一致）、
  `A13-parity`（Docker 的 edge 與原生的 nginx 把同一組前綴交給 PHP）。

  > `CLI-bats` **只驗接線，不代表測試通過** —— 「測試有沒有過」這個宣稱
  > 只屬於 `cx test cli`，不屬於任何別的地方。

* **`docs`** —— 文件與實作一致：`env/ansible/README.md` 的執行狀態不能與實測衝突、
  README 教的 `waf_*` 變數真的被某個 role 讀取、文件指向的 `group_vars` 路徑正確
  （是目錄 `all/main.yml`，不是 `all.yml`）、Livewire 排除規則的前綴形狀、
  `cx-reference.md` 涵蓋每個動詞。

* **`tui`** —— 選單每一項都指得到真的存在的指令，且每個動詞都到得了。

* **`static`**（`bin/lib/verify_checks.py`）—— 對**合併後**的 compose 設定做斷言，
  不是 grep yaml。三個模式的埠段不重疊、base 檔沒有 `ports:`、網路明寫 `name:`、
  映像 tag 含模式、prod 不發布 DB 與管理工具、bind mount 來源都存在、
  版本鎖定、**外部映像一律釘版本**（`4b`：拒絕 `latest`／`stable`／只有 major 的 tag）、
  Dockerfile 的五項斷言。

* **`runtime`** —— supervisord 管著 ≥4 個程序、`vendor/autoload.php` 沒被 bind mount 蓋掉、
  `APP_KEY` 就緒（dev 與 test/prod 判準不同：test/prod 要求金鑰**由環境注入**
  且容器內**不可以有 `.env`**）、prod 執行期無 xdebug、migration 真的跑過。

* **`app`** —— `/up`、`/`、`/healthz`、`/admin/login` 期望 200，
  `/sanctum/csrf-cookie` 期望 204，`/api/user` 未認證期望 **401 而不是 500**
  （500 通常代表 `bootstrap/app.php` 沒設 `redirectGuestsTo`）。

* **`waf`** —— 見 §5。

* **`acl`** —— `setfacl`/`getfacl` 可用、檔案系統支援 ACL（先實際探測一次，
  因為 noacl 掛載的錯誤是 `Operation not supported`，看起來完全不像掛載問題）、
  `cx acl check` 通過（沒套用是 SKIP，因為 ACL 是選用的）。

* **`ansible`** —— 轉呼叫 `cx deploy syntax` 與 `cx deploy lint`。

每次執行開頭都會 `rm -f .cx/verify-config-*.json`，確保讀到的是**現在**的 compose 檔，
不是上一次的快取。

---

## 3. `cx scan` — 四道防線

```
cx scan <code|sast|sca|dast|secrets|all> [--runner docker|native|auto]
```

四道防線的**原理與閘門定義**在 [`devsecops.md`](devsecops.md)，
**報告的逐檔案讀法**在 [`reports.md`](reports.md)。這裡只講測試者要做的判斷。

### 3.1 每一道實際跑什麼、需要什麼

| lane | 實際執行 | 需要容器在跑嗎 | 失敗碼 |
|---|---|---|---|
| `code` ① | host 的 `src/backend/vendor/bin/phpstan analyse`；另外在 docker runner 且 sonar 網路存在且拿得到 token 時跑 `sonar-scanner` 容器 | ✘（Sonar scanner 需要常駐的 SonarQube，`cx sonar up`） | 20 |
| `sast` ② | Semgrep（容器或原生），規則集來自 `env/docker/security/semgrep/rulesets.txt`；產出 SARIF 後由 `bin/lib/sarif_gate.py` 判級 | ✘ | 21 |
| `sca` ③ | `trivy fs`（vuln+secret+misconfig）、**`trivy image` 掃已建好的映像**、`composer audit`、`npm audit`、CycloneDX SBOM、掃描器映像 digest | ✘，但映像那一段需要**已經 build 過** | 22 |
| `dast` ④ | ZAP baseline 跑兩輪（`DetectionOnly` 與 `On`，每輪真的重建 waf 容器切引擎）＋ **主動攻擊探測**＋被動 alert 對照 | **✔ 需要 `cx test up -d`**（否則找不到 `<專案>_test_net`，以 `EX_PRECOND` 中止） | 23 |
| `secrets` | gitleaks 對 backend / frontend / 主庫各掃一次**全歷史** | ✘ | 22（與 ③ 共用） |
| `all` | ①②③④ 再加 secrets | 各道的聯集 —— **因為含 ④，所以仍然要先 `cx test up -d`** | 五道之中**最嚴重**的那個 |

> **`cx scan all` 不會遇到第一個問題就停。** 每一道都跑完，最後回傳最嚴重的退出碼。
> 停在第一道會讓後面幾道永遠沒機會跑，而掃描的價值正是「一次看到全部」。

`--runner`：`auto`（預設）有 Docker daemon 就走容器。
`cx scan` 自己的 `--runner` 位置較近者優先。ZAP 只有 docker 一條路（要 Java runtime）。
原生的 Trivy 路徑會載入**同一份** `trivy.yaml`（只用 CLI 旗標覆寫容器內絕對路徑的兩個設定），
所以兩條 runner 的閘門是同一套，不是兩套。

### 3.2 「掃到東西」與「工具當掉」是不同的事

這是本節最重要的一件事，而且它在程式碼裡是**逐處實作**的，不是一句口號。
在 `set -Eeuo pipefail` + ERR trap 之下，Trivy 找到一個 HIGH CVE 就會噴 stack dump 並
`exit 1` —— 所以 `cx` 一律顯式捕捉退出碼並映射。

| 工具 | exit 1 的兩種意思 | `cx` 怎麼分辨 |
|---|---|---|
| `npm audit` | 找到漏洞 / **連不到 registry** | 檢查輸出 JSON 有沒有 `auditReportVersion`、`metadata`、`vulnerabilities` 其一；沒有就把 `message` 挖出來當原因，回 3 |
| `trivy image` | 找到問題 / **FATAL 沒跑成** | 成功一定會寫出含 `"SchemaVersion"` 的 JSON；輸出檔是空的就回 3 |
| `gitleaks` | 找到祕密 / **報告路徑寫不出來** | 跑成功一定會留下一份 JSON（乾淨時是 `[]`）；沒有檔案就回 3 |
| `zap-baseline.py` | 見下表 | 顯式 case 映射 |
| Semgrep | `>=2` 一律是工具異常（最常見是 `exit 7`：規則集在 registry 上不存在） | 回 3，並提示怎麼逐一驗證規則集 |

ZAP 的退出碼慣例不是「0 成功／非 0 失敗」：

| ZAP rc | 意義 | `cx` 的處置 |
|---|---|---|
| 0 | 沒有 alert | 通過 |
| 1 | 至少一個 FAIL（= 有 High risk alert） | `EX_SCAN_DAST`(23) |
| 2 | **只有 WARN** | **通過**（依 §5 的閘門定義） |
| ≥3 | 工具本身出錯 | `EX_PRECOND`，不是掃描結果 |

把 2 當失敗會讓每一次掃描都紅（實測 8 個 warning 就足以觸發舊版的誤判）；
把 ≥3 當成功則會讓「ZAP 根本沒跑起來」被記成「沒有漏洞」。

**沒有前置可達性檢查。** 「ZAP 很快就跑完而且零 alert」仍然可能是目標根本沒起來 ——
判斷方法是打開 `reports/dast/*/report.json` 看有沒有實際掃到 URL。

### 3.3 兩個不是閘門的產物

* **SBOM**（`reports/sca/sbom.cdx.json`）—— 產不出來是環境問題（Trivy 不在），
  不是「這個專案有資安問題」。它的退出碼刻意不進 lane。
* **掃描器映像 digest**（`reports/sca/scanner-image-digests.txt`）——
  掃描器**刻意只釘版本 tag 而不釘 digest**（釘死 digest 會讓它停在舊的規則集與漏洞庫，
  那比漂移更糟）。代價是同一個 tag 兩個月後可能是不同的建置，
  所以把解析出來的 digest 記下來，事後才回答得了「那份報告是哪一版掃出來的」。

### 3.4 `cx scan dast` 會動到你的環境，而且會還原

兩輪掃描之間會 `docker compose up -d --wait --force-recreate waf` 切換
`MODSEC_RULE_ENGINE`。`--force-recreate` 是必要的不是保險：CRS 排除規則是 bind mount 進去的，
而 ModSecurity **只在啟動時**載入規則 —— compose 若判定「設定沒變」而不重建，
跑的還是舊規則（2026-09-05 實際踩到：改了 `ruleRemoveById` 之後探測仍然 403，
`docker exec grep` 得到新規則，但生效的是舊的）。

跑完之後引擎會被還原成 `env/docker/compose/test.env` 宣告的值（預設 `DetectionOnly`），
而且還原做了兩次：探測程式自己的 `finally` 一次，`_scan_dast` 結尾再一次
（為了涵蓋「ZAP 跑完但探測被略過」那條路徑）。

**萬一還原失敗**，`cx verify waf` 的 `waf-engine` 會在下一次驗收時抓到
「宣告 DetectionOnly、實際 On」的漂移。手動修：`cx test up -d waf`。

---

## 4. `reports/` — 測試者需要的額外幾件事

目錄結構、各檔案怎麼讀（含免安裝的 `python3` 一行式）、以及報告可以安全刪除的做法，
全部在 [`reports.md`](reports.md)，這裡不重複。下面只補「決定要不要放行」時才需要的判斷。

### 4.1 先看退出碼，再看報告

報告告訴你**是什麼問題**，退出碼告訴你**這是不是一個問題**。
順序反過來的話，你會花時間去讀一份根本沒生成完的 JSON。

### 4.2 怎麼分辨「掃描沒跑成」與「掃描掃到東西」

`cx scan` 在終端機上已經把兩者分開講了 ——
「有 finding」是 `cx_warn`，「沒跑成，不是掃出問題」是 `cx_error` 並附
「這是環境問題（退出碼 3），不是 …」。但如果你只拿到報告目錄（例如 CI 的 artifact），
用產物本身判斷：

| 報告 | 「跑成了」的樣子 | 「沒跑成」的樣子 |
|---|---|---|
| `sca/trivy-fs.json`、`sca/trivy-image-*.json` | 含 `"SchemaVersion"` | 空檔或缺檔 |
| `sca/npm-audit.json` | 有 `auditReportVersion` / `metadata` / `vulnerabilities` | 只有 `{"message":…,"error":{…}}`（典型是 network timeout） |
| `secrets/gitleaks-*.json` | 檔案存在；`[]` = 乾淨 | **檔案不存在** |
| `sast/semgrep.sarif` | 檔案存在且是合法 SARIF | 缺檔（Semgrep `--output` 會把 stdout 全部吞掉，連錯誤訊息都不會出現在終端機） |
| `dast/*/report.json` | `site[].alerts` 之外還能看到實際掃到的 URL | 秒殺完成、零 alert 而且沒有 URL |
| `quality/larastan.json` | 有 `totals`（或扁平格式的整數 `errors`） | 空檔 |

> `reports/secrets/` 這個目錄曾經漏掉建立，於是 gitleaks 寫不出報告而 `exit 1`，
> 而舊的 `_scan_step` 只看退出碼 —— **「目錄不存在」被顯示成「掃到祕密」，rc=22**。
> 在最不能誤報的這一道上這尤其不可接受，所以現在改成用產物判斷。
> 這也是為什麼 `reports/` 的葉目錄必須由**你的身分**建立（`cx setup dirs`），
> 而不是讓 Docker 用 root 去建。

### 4.3 Larastan 與 Semgrep 的兩個「假的乾淨」

這兩個是實際踩過的坑，讀報告時特別注意：

* **`larastan.json` 是 JSONL 不是單一 JSON 物件**（phpstan 有 note 要說的時候會先吐一行），
  而且頂層的 `"errors"` 在標準格式裡是**通用錯誤的陣列**不是計數 ——
  100 個檔案錯誤時它仍然印 `[]`，看起來永遠乾淨。要的是 `totals.file_errors` 與
  `totals.errors` 相加。
* **SARIF 的 result 沒有 `level` 欄位**（實測 18 個 result 的 `r.get("level")` 全是 `None`），
  等級掛在 `runs[].tool.driver.rules[].defaultConfiguration.level`。
  寫成 `r["level"]=="error"` 會一個都印不出來而且 exit 0。

被 `# nosemgrep` 抑制的項目在 SARIF 裡帶 `suppressions`，
`sarif_gate.py` 一律不計入閘門，但**仍會計數並印出來** ——
因為「抑制了幾條」本身是需要被看見的資訊。抑制一律要求書面理由
（`bin/lib/waf_probe.py` 的那一處就是範例）。

---

## 5. WAF 的主動探測 —— 為什麼被動掃描量不到 WAF

### 5.1 問題

`zap-baseline.py` 是**被動**掃描：它爬站、檢查回應標頭，**不送任何攻擊 payload**。
所以拿 `DetectionOnly` 與 `On` 兩份 baseline 報告去比對，兩邊必然完全一樣，
結論永遠是「WAF 擋下 0 項」。

**那個數字不是「WAF 沒用」，是量錯了東西。**

`reports/dast/compare/waf-effectiveness.json` 就是那個差值。它仍然有意義
（Blocking 模式下多出來的 alert 代表 WAF 自己引入了新的回應標頭問題），
但**絕對不能拿它當攔截率**。畫面上會同時出現「主動探測擋下 100%」與「被動 alert 差 0 項」，
兩個都對，量的是不同東西 —— 所以那段輸出的標題被刻意寫成「非攔截率」。

### 5.2 主動探測（`bin/lib/waf_probe.py`）

真的送請求，並比較兩個引擎模式下的狀態碼：

| 請求種類 | `DetectionOnly` 應該 | `On` 應該 |
|---|---|---|
| 攻擊（6 項：兩種 SQLi、兩種 XSS、路徑穿越、指令注入） | 2xx/3xx（只記錄） | **403** |
| 正常（`/`、`/up`、`/admin/login`、`/sanctum/csrf-cookie`） | 通過 | **通過** |
| 正常的 Livewire POST（元件狀態快照） | 通過 | **通過** |

結果寫進 `reports/dast/compare/waf-probe.json`：
`block_rate_percent`、`blocked_in_blocking_mode`、`not_blocked`、
`normal_requests_falsely_blocked`，以及每一項的原始狀態碼。

探測從一個一次性容器打 `http://waf:8080`，而不是用 host 的 curl ——
這樣走的是 compose 網路內部，與 ZAP 的路徑完全一致（host 那條路要多經過一層發布埠的 NAT）。

**探測本身不決定 lane 的成敗**（`main()` 一律 `return 0`）—— 它是量測，不是閘門。
閘門仍然是 ZAP 的 High risk alert。所以這份 JSON 要人去看，
或由 `cx verify waf` 的 `waf-block` / `waf-livewire` 兩項把它變成 PASS/FAIL。

### 5.3 對照組才是會抓到真實故障的那一半

**正常請求在 Blocking 模式下被擋，比「沒擋到攻擊」更嚴重**，
因為它代表 CRS 排除規則沒生效 —— Livewire / Filament 的表單送出會被 941/942 誤判，
也就是後台整個不能用。而這件事**可以與「攻擊 100% 全擋」同時成立**。

2026-09-05 之前的真實狀態正是如此：攻擊全擋、Filament 後台完全不能用，
而且沒有任何檢查會發現。原因是當時「正常請求」那一組全是不帶 body 的 GET，
而 Livewire 排除規則寫的是 `@beginsWith /livewire/` ——
Livewire v4 的端點前綴由 `APP_KEY` 推導成 `/livewire-<hash>/`，一條都比對不到。

所以探測有兩個設計上的硬性要求：

1. **端點前綴絕不寫死**，現場從 `/admin/login` 的 HTML 撈（那正是瀏覽器會拿到、
   真實流量會打的那一個）。撈不到就誠實地略過該對照項並印警告。
2. **body 的內容必須是「排除規則正是為了放行它才存在」的那一種**
   （`<script>alert(1)</script>` 與 `1 UNION SELECT NULL FROM users`）。
   太溫和的字串在 PL1 之下本來就不會觸發 CRS，那樣的檢查會永遠通過，等於沒驗。
   這兩個字串分別對應「富文字欄位貼上 HTML」與「表格篩選器打了一句話」——
   都是後台的日常操作。

### 5.4 這一套實際抓到過什麼（有證據）

把 Docker 側的 CRS 從浮動的 `:nginx-alpine`（實際是 **3.3.10**）釘到
`4.28.0-nginx-alpine-…` 之後，主動探測立刻紅了：攻擊仍然 100% 擋下，
但**正常的 Livewire POST 被擋成 403**。追下去是連續兩條 CRS 4 才有的規則
（`941390`、`942550`），而原生 Ansible 那條路跑的是 MyGuard 的 **4.30.0** ——
**代表原生部署的 Filament 後台一直有這個誤判，只是沒有人量過。**
細節見 [`progress.md`](progress.md) 的「供應鏈釘版本」一節。

修正後 2026-09-05 的實測（引擎切到 `On`）：

| 請求 | 經 WAF 18081 | 直連 edge 18080 |
|---|---|---|
| 查詢字串的 XSS（真攻擊） | **403** | 200 |
| Livewire POST 含 `<script>` + `UNION SELECT` | **419** | 419 |

419 = CSRF token 不符，代表請求**到得了 Laravel**（也就是過了 WAF）。
修正前是 403 vs 419。`cx verify waf` 的 `waf-livewire` 判準就是這兩個碼相等。

### 5.5 `cx verify waf` 的兩個細節

* **一律明寫 `Host` 標頭。** 用 `http://127.0.0.1:<埠>` 探測時 curl 會把 Host 設成數字 IP，
  而 CRS 的 920350（Host header is a numeric IP address）會因此加分 ——
  那是探測方式造成的，真實瀏覽器不會這樣送。少了這一行，`waf-livewire`
  會因為一條與 Livewire 完全無關的規則而永遠 FAIL。要覆寫用 `CX_WAF_HOST`。
* **引擎不是 `On` 時，攔截兩項誠實地 SKIP。** `env/docker/compose/test.env` 宣告的是
  `DetectionOnly`，所以平常跑 `cx verify all` 這兩項就是 ⬜ —— 那是正確行為，
  不是漏驗。要驗就自己把引擎切成 `On`（或讓 `cx scan dast` 去跑，它每輪都會涵蓋）。

---

## 6. 合併前的驗收清單

分成四層，**由便宜到昂貴、由不需要環境到需要完整環境**。
上一層紅了就不必往下跑 —— 這與四道防線的排序理由是同一個。

### 第 0 層：不需要 Docker、不需要 `.env`、不需要任何容器（秒級）

在剛 clone 下來的樹上就跑得完。**每一次 PR 都必跑。**

```bash
cx verify cli docs tui        # 跨檔一致性
cx lint sh                    # shellcheck 掃 cx 與 bin/**.{sh,bash}
CX_TEST_STRICT=1 cx test cli  # cx 自己的行為測試（bats）
```

| 放行條件 | |
|---|---|
| `cx verify cli docs tui` | 失敗 0，**且未驗數是你看過並接受的**（`TPL-env` 在沒有 `.env` 時會 SKIP，那是正常的） |
| `cx lint sh` | rc=0。閘門看 **error**，warning 會完整顯示但不擋（與 ② SAST 同一套邏輯）—— 唯一的例外是 `bin/cmd/lint.sh` 的 `fatal_warn` 清單（`SC2215 SC2216 SC2217 SC2218 SC2069 SC2064 SC2140 SC2145`），那八條 shellcheck 歸類為 warning 的東西其實是正確性缺陷，命中就視同 error 回 `EX_FAIL`(1)。**rc=3 = shellcheck 沒裝**，補 `cx setup tools shellcheck` |
| `cx test cli` | rc=0。**rc=3 = bats 沒裝**，不是通過 —— 補 `cx setup tools bats` 再跑 |

### 第 1 層：需要工具鏈（容器**或**原生擇一），不需要容器在跑

這一層**有一部分**是雙 runner 的：`cx style`、`cx test back` / `front`、
`cx scan sast`、以及 `cx scan sca` 的 `trivy fs`，`--runner auto` 有 Docker daemon
就走容器，沒有就走原生；走原生時需要 `src/backend/vendor` 與 `src/frontend/node_modules`，
缺了會以 `EX_PRECOND` 硬失敗並告訴你補哪一個。

其餘幾個**不是**雙 runner，`--runner` 對它們沒有作用，一律跑 host 上的工具：
`cx scan code` 的 Larastan（`src/backend/vendor/bin/phpstan`）、`cx scan sca` 的
`composer audit` 與 `npm audit`、`cx scan secrets` 的 gitleaks、
以及 `cx deploy syntax` / `lint` 的 ansible。
反方向也有一個：`cx scan sca` 的 `trivy image` 只在 docker runner 之下才會跑。

```bash
cx style --check              # Pint + Prettier，只檢查不改檔
cx test back                  # 後端 PHPUnit（sqlite :memory:，不需要 MySQL）
cx test front                 # 前端型別檢查
cx scan code                  # ① Larastan（+ Sonar scanner，若 server 與 token 都在）
cx scan sast                  # ② Semgrep
cx scan sca                   # ③ Trivy fs + composer audit + npm audit
cx scan secrets               # gitleaks 全歷史
cx deploy syntax && cx deploy lint   # 動到 ansible/ 才需要
```

| 放行條件 | |
|---|---|
| `cx style --check` | rc=0（非 0 代表格式沒跑過，跑 `cx style` 自動修）。兩邊都跑完才回傳最嚴重的碼 |
| `cx test back` / `front` | rc=0。**rc=3 要當環境問題處理**（缺 `pdo_sqlite`／缺 `node_modules`／資料庫防護拒絕），不要當成「這次沒測到但沒關係」 |
| `cx scan code` | rc=0。rc=20 = Larastan 有 error。⚠ `src/backend/vendor/bin/phpstan` 不存在時只印一行 `cx_warn` 並讓這道回 0 —— 所以要順帶確認終端機上真的出現了 `報告：reports/quality/larastan.json（errors=…）` 那一行，否則這個 0 是「沒跑」不是「乾淨」 |
| `cx scan sast` | rc=0。rc=21 = 有 **ERROR 等級** finding；warning 會列出但不擋 |
| `cx scan sca` | rc=0。rc=22 = 有 finding；例外必須進 `env/docker/security/trivy/.trivyignore.yaml` 且**有 `statement` 與 `expired_at`** |
| `cx scan secrets` | rc=0，且三份 `gitleaks-*.json` 都**存在**且是 `[]`。檔案不存在 = 沒跑成 |

> **`cx scan sca` 一個已建映像都找不到時，只印一行「沒有已建置的映像可掃」的警告，
> 那一段回 0** —— 整條 lane 完全不受影響，也就是一個安靜的綠燈。
> （另外兩種情況才回 `EX_PRECOND`：Docker 不可用，或 `trivy image` 自己沒跑成
> —— 判準是輸出檔裡有沒有 `"SchemaVersion"`。那個碼刻意不進 lane 的判定，
> 因為環境問題不該被記成「這個專案有資安問題」。）
> 所以如果這次 PR 動到 Dockerfile 或 `backend/`，要先 build 再掃，
> 否則映像層的祕密外洩不會被看到 —— 那正是 2026-09-05 抓到 `pm/app:prod-prod`
> 內含真實 `APP_KEY`／`DB_PASSWORD` 的那一類缺陷。

### 第 2 層：需要容器

```bash
cx dev up -d --build
cx test up -d --build         # test 模式才有 ModSecurity WAF
cx prod up -d --build         # 只在動到 prod 相關設定時才需要

cx verify                     # 預設：cli docs tui static app ansible
cx verify runtime acl
cx test coverage              # 覆蓋率（只有容器路徑）
```

| 放行條件 | |
|---|---|
| `cx verify` | rc=0，**且逐項確認每一個 ⬜ 都是你接受的原因** |
| `cx verify runtime` | 對每個你打算宣告「已驗」的模式，`rt-<模式>` 不可以是 SKIP |
| `cx test coverage` | rc=0；`reports/quality/{coverage,junit}-backend.xml` 兩份都在 |

### 第 3 層：完整驗收（最貴，發版前或動到 WAF／compose／Dockerfile 時）

```bash
cx test up -d --build         # DAST 必須有 test 堆疊
cx scan dast                  # ④ ZAP ×2 + 主動探測 + 被動對照
cx verify all                 # cli docs tui static runtime app waf acl ansible
```

| 放行條件 | |
|---|---|
| `cx scan dast` | rc=0（rc=23 = 有 High risk alert）；並打開 `reports/dast/compare/waf-probe.json` 確認 `normal_requests_falsely_blocked` 是**空陣列** |
| `cx verify all` | 失敗 0；未驗只接受 `waf-block` / `waf-livewire`（引擎宣告為 `DetectionOnly` 時），其餘每一項都要有明確理由 |
| WAF 引擎 | 跑完之後 `cx verify waf` 的 `waf-engine` 必須 PASS —— 確認 `cx scan dast` 有把引擎還原 |

### 一次跑完（互動式，看得到每一步）

```bash
cx verify all
cx scan all
cx test all
CX_TEST_STRICT=1 cx test cli
```

### 放行的總條件

一個分支可以合併，當且僅當下面五句話同時成立：

1. **第 0 層與第 1 層全綠**，且沒有任何一項是以 rc=3 結束的。
2. **沒有任何 `cx verify` 的 FAIL**，而且**每一個 SKIP 你都看過原因並接受**。
3. **`cx scan` 的退出碼是 0**；若是 20/21/22/23，例外必須有書面理由與到期日；
   若是 3，那是環境問題，**必須先修好再跑一次**，不能當成通過。
4. 動到 WAF、CRS 排除規則、`env/docker/edge/`、`env/ansible/roles/nginx_myguard/` 任何一個時，
   **第 3 層必跑**，且 `waf-probe.json` 的 `normal_requests_falsely_blocked` 是空的。
5. 動到 `src/backend/phpunit.xml`、`src/backend/tests/`、`bin/cmd/test.sh` 任何一個時，
   `cx verify cli` 的 `GRD-*` 四項**全部 PASS**。

### 一定要記錄下來的東西

`cx verify` 每次都會產生 `reports/verify/<UTC 時間戳>.md`。
**把那個檔案（或它的路徑與三個數字）貼進 PR。**
「我跑過了」不是證據，`通過 N ・失敗 0 ・未驗 M` 才是。

人工項目（自動化驗不到的）集中在 [`acceptance.md` §7](acceptance.md)，
每一列都要求附上指令與實測輸出。目前 M2–M5（phpMyAdmin 真的登入、
Filament 後台實際操作、Sanctum 完整登入流程、真實跨源 CORS）**仍是未驗** ——
`/admin/login` 回 200、`/sanctum/csrf-cookie` 回 204、`/api/user` 未認證回 401
都是自動驗過的，但那不等於「走完一次登入」。

---

## 7. 五個最常見的誤讀

| 誤讀 | 為什麼錯 |
|---|---|
| 「`cx verify` 沒有失敗，所以驗過了」 | 一份 `通過 3 ・失敗 0 ・未驗 49` 的報告退出碼也是 0。**SKIP 不算通過。** |
| 「`cx test cli` 回 0，所以行為測試全過了」 | bats 把 `skip` 算成 `ok`。互動式跑要看警告行，CI 要用 `CX_TEST_STRICT=1`。 |
| 「掃描回非 0，所以有資安問題」 | 3 是環境問題（工具沒裝、目錄寫不進去、registry 連不上）。假的資安報告比沒有報告更糟。 |
| 「兩份 ZAP 報告差 0 項，所以 WAF 沒用」 | 被動掃描不送 payload，差值恆為 0。攔截率看 `waf-probe.json`。 |
| 「攻擊 100% 全擋，所以 WAF 設對了」 | 攻擊全擋與**後台完全不能用**可以同時成立，2026-09-05 之前就是。要看 `normal_requests_falsely_blocked`。 |

---

## 8. 相關文件

| 想知道 | 讀 |
|---|---|
| 某個動詞的完整語法與陷阱 | [`cx-reference.md`](cx-reference.md) |
| 報告的目錄結構與逐檔案讀法 | [`reports.md`](reports.md) |
| 四道防線的原理與閘門定義 | [`devsecops.md`](devsecops.md) |
| 三個模式的差異、合併鏈、edge / WAF 設定 | [`docker-reference.md`](docker-reference.md) |
| 容器與原生兩條 runner 的分工 | [`runners.md`](runners.md) |
| 需求 → 檢查 ID → 實測結果的追溯表 | [`acceptance.md`](acceptance.md) |
| 還有什麼沒驗過 | [`progress.md`](progress.md) |
| 出事了 | [`troubleshooting.md`](troubleshooting.md) |
| 為什麼要這樣設計 | 根目錄的 `claude.md` |

> 衝突時的權威順序（見 [`docs/README.md`](README.md)）：
> ① `cx help` 的輸出 → ② `cx verify` 的報告 → ③ `claude.md`。
