# `docs/cx/` — 給改 `cx` 的人看的

`docs/` 是「**怎麼用**」，根目錄的 [`claude.md`](../../claude.md) 是「**為什麼這樣設計**」。
這個子目錄是第三類：「**怎麼改 cx 自己**」。

| 文件 | 內容 |
|---|---|
| [`cx-reference.md`](cx-reference.md) | 每一個動詞的語法、參數、行為、退出碼、陷阱。**使用者也看這一份** |
| [`layout.md`](layout.md) | 目錄版面契約（v2 → v3）、`CX_LAYOUT_VERSION` 的語意、子模組搬移的完整程序 |
| [`adding-a-verb.md`](adding-a-verb.md) | 新增一個動詞要改哪七個地方，以及**每個地方的 regex 契約** |
| [`verify-checks.md`](verify-checks.md) | 全部檢查 ID → 盯什麼 → 原始碼位置 → 壞掉時的症狀 |
| [`testing.md`](testing.md) | bats 版面、三種 fixture、「綠」的定義 |
| [`onboarding.md`](onboarding.md) | **人員接續專案**：clone 到能跑起來的完整流程 |

## 這裡的東西為什麼不放在 `claude.md`

`claude.md` 回答的是「為什麼當初這樣決定」。這裡回答的是「**現在要動它，
規則是什麼**」—— 後者有很多是機器檢查的契約（縮排、regex、字面形式），
寫在設計文件裡會被當成背景說明而略過。

實際發生過：`claude.md` §7 的「新增一個動詞時，七個地方要一起改」是對的，
但它沒有寫出每個地方的**形式要求**（`help.sh` 的縮排、`cmd_git_main` 的 case
臂要恰好 8 空白、`_tui_run <verb>` 必須是字面而不能是變數）。那些散在
`bin/lib/verify_meta.py` 的註解裡，而寫新動詞的人不會去讀那個檔。
[`adding-a-verb.md`](adding-a-verb.md) 就是把它們收在一起。
