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
`line_sha <repo> <ref> <子模組路徑>`、`tree_digest`。

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

## 寫新案例的兩個慣例

**雙向對照。** 只驗「壞的時候會紅」不夠，也要驗「修好之後會綠」；
反過來也一樣。豁免清單、fallback 分支特別容易變成沒人測的死碼。

**測契約，不測實作。** 例：`cx status` 的案例驗的是「在什麼都沒有的樹上仍然
rc=0」，而不是它印了哪幾行 —— 前者是那個動詞存在的理由，後者會在下次調整
輸出時無謂地紅。
