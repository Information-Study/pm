# `cx` 自己的測試

```bash
cx test cli              # 全部
cx test cli --strict     # 有 skip 就當失敗（CI 用）
```

`bin/test/*.bats`，用 [bats-core](https://github.com/bats-core/bats-core)。

## 「綠」的定義

| 項目 | 判準 |
|---|---|
| `cx test cli` | 0 failure。**skip 不等於通過** —— `_test_cli` 會另外把跳過數印出來 |
| `cx verify` | **FAIL = 0 且 SKIP 沒有增加** |

> ⚠ 第二條的後半是硬指標，不是提醒。`cx verify` 的退出碼**只看 FAIL**，
> 而有 7 條檢查是「讀不到檔案就 SKIP」（`GRD-*` 讀 `src/backend/`、
> `LNT-eslint-*` 讀 `src/frontend/`）。所以
> 「路徑改錯 → 檔案讀不到 → PASS 變 SKIP → 退出碼仍 0」
> 是一種**不會變紅的失敗**。改版面、搬檔案、改路徑之後，
> 要比對的是 `通過 N ・ 失敗 0 ・ 未驗 2` 這三個數字，不是只看有沒有紅字。

## 三種 fixture（`bin/test/helpers/fixture.bash`）

| fixture | 蓋到什麼 | 用在 |
|---|---|---|
| `make_root` | 最小樹：`.cxroot` + `bin`/`cx` 的 symlink + `src/{backend,frontend}` 的骨架檔 | dispatch、退出碼、runner、旗標 |
| `make_repo` | 三個**各自獨立**的 plain repo（沒有 submodule 佈局） | fresh、archive 的破壞性測試 |
| `make_submodule_repo` | **真的**指標檔 + `.git/modules/` + `dev` 分支 | gitflow、feature/hotfix/release |

輔助：`add_compose_skeleton`（要測 compose 的案例自己叫）、
`line_sha <repo> <ref> <子模組路徑>`、`tree_digest`、
`tui_screen`（見下）。

## `tui_screen` —— 在真 pty 裡把選單跑起來

`TUI-resolve` 與 `TUI-coverage` 是**靜態 regex 剖析**。它們證明得了
「選單項目指得到真的動詞」與「三個模式的聯集涵蓋每個動詞」，
但證明不了「這個選單**真的畫得出來**」。

2026-09-05 的 commit `16d28ba`（對話框尺寸寫死）就是一個
**所有靜態檢查都全綠、而選單畫不出來**的缺陷。
`bin/test/75_tui_run.bats` 補的就是那一半。

```bash
tui_screen --mode test          # 跑完之後看 $TUI_RC 與 $TUI_TEXT
[[ $TUI_TEXT == *"DevSecOps"* ]]
```

三個實作細節，每一個都是踩過才知道的：

* **whiptail 需要真 tty** → 用 `script -qec` 開 pty（`tui.sh` 自己跑子行程也是這樣）
* **輸入必須延遲餵進去**。一次寫完就 EOF 的話 whiptail 還沒準備好讀，
  於是它會一直等下去 —— 實測：不延遲的 ESC 一律 timeout（rc=124）
* **ESC 要送兩次**才會取消 whiptail 的 `--menu`

畫面是逸出序列包著文字，`tui_screen` 會 strip 過再放進 `$TUI_TEXT`。

> 這個 helper 最有價值的用途是**模式門檻**：`check_tui` 看不到 `$_TUI_MODE`，
> 所以「dev 模式下實際畫出來的選單裡有沒有掃描」只有真的畫一次才知道。
> 反向驗證過兩種缺陷：拿掉模式門檻 → 對應的案例失敗；
> 把對話框尺寸寫死成畫不出來的值 → 「主選單畫得出來」失敗。

### `tui_screen_keys` —— 在選單裡操作

`tui_screen` 只驗「**啟動時**就是這個模式」的畫面。而 2026-09-06 使用者回報的
缺陷正好在另一半：**在選單裡切換模式之後**項目沒有重建
（`items` 陣列建在 `while` 迴圈外，只算一次）。

```bash
tui_screen_keys '\033[B\r
\033[B\r'                    # 下+Enter 進切換模式；下+Enter 選 test
[[ $TUI_TEXT == *"DevSecOps"* ]]
```

⚠ **按鍵必須一段一段送，中間留時間**。一次寫完的話，第二組按鍵會在
whiptail 還沒重畫出下一個對話框時就被丟掉 —— 而測試會「有時候過、有時候不過」。
`tui_screen_keys` 以**換行**分段，每段之間 `sleep 1.5`。

> 這個坑我自己踩了一次：修好之後寫展示腳本驗證，按鍵一次送完，
> 於是三個模式都顯示 dev —— 看起來像修正沒生效，實際上是輸入被丟了。

### `make_root` 刻意保持最小

不要把 `.env` 或 `docker-compose.yml` 併進去。實測 2026-09-06：

* 加了 `.env` → `setup env 的身分只認 .cxroot` 那個案例**靜默變成空輸出**
 （`_setup_env` 在 `.env` 已存在時早退）
* 加了 `docker-compose.yml` → `verify` 的 static 家族開始檢查一份假的 compose 然後 FAIL

要測 compose 的案例叫 `add_compose_skeleton` 就好。

### `make_submodule_repo` 的 `--name`

```bash
git submodule add --force -q --name "$c" -b dev "./src/$c" "src/$c"
```

**`--name` 是必要的。** 不給的話子模組的**名字**會變成路徑（`src/backend`），
而真實專案是用 `git mv` 搬過去的 —— `git mv` 只改 path，名字仍是 `backend`。

兩者的差別看得到的地方：`.git/modules/<名字>` 的目錄名，以及
`git.sh` 的 `_git_sub_target_branch` 用 `basename` 去 `.gitmodules` 查 branch。
fixture 的拓撲與真實專案不一致的話，`50_archive.bats` 會以完全看不懂的方式失敗
（它斷言 `.git/modules/backend` 存在）。

## `_assert_disposable`

每個 fixture 都先跑它。它拒絕任何不在 bats tmpdir 底下的 `CX_TEST_ROOT` ——
因為這些測試會呼叫**真的** `cx fresh`，而那個動詞會刪東西。

## 需要網路的案例

`CX_TEST_NETWORK=1` 才跑（`composer create-project` / `nuxi init`）。
預設 skip，而 `_test_cli` 會把跳過數印出來 —— 因為本專案的教條是 SKIP ≠ PASS。

## pty 案例：`tui_screen_keys` 的兩個坑

TUI 的靜態檢查（`TUI-resolve` / `TUI-coverage`）只證明得了「tag 指得到真的動詞」
與「三個模式的聯集涵蓋每個動詞」。**選單長什麼樣子、走不走得進去，只有真的畫
一次才知道** —— 2026-09-06 使用者回報的「deploy 內選單跟功能皆不正常」就是
所有靜態檢查全綠、而選單裡完全沒有群組入口。

`tui_screen_keys '<按鍵>' [cx 旗標...]` 在真 pty 裡跑選單，把畫面文字放進
`$TUI_TEXT`、退出碼放進 `$TUI_RC`。兩個會讓人查很久的坑：

1. **按鍵要一批一批送，中間留時間。** 一次寫完的話 whiptail 會來不及讀而丟掉，
   畫面停在第一層 —— 看起來就像「功能沒做」。helper 每讀一行 sleep 1.5 秒。
2. **收尾固定只送兩個 ESC**，剛好關掉「一層子選單 + 主選單」。走得更深的案例
   要自己在 keys 最後多加 ESC，一層一個。少一個的話主選單會停在那裡等輸入，
   整個 pty 被 `timeout` 殺掉，而失敗訊息**只有 `status 124`** ——
   完全看不出是測試寫錯還是功能壞了。

> 這幾條案例都反向對照過：把 `bin/cmd/tui.sh` stash 掉跑一次，三條全紅。
> 「檢查全綠」與「檢查有在做事」是兩件事。

## 寫新案例的兩個慣例

**雙向對照。** 只驗「壞的時候會紅」不夠，也要驗「修好之後會綠」；
反過來也一樣。豁免清單、fallback 分支特別容易變成沒人測的死碼。

**測契約，不測實作。** 例：`cx status` 的案例驗的是「在什麼都沒有的樹上仍然
rc=0」，而不是它印了哪幾行 —— 前者是那個動詞存在的理由，後者會在下次調整
輸出時無謂地紅。
