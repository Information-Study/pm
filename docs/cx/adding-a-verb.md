# 新增一個動詞：七個地方，以及每個地方的形式要求

漏掉任何一個都**不是**靜默漂移 —— `cx verify` 會直接 FAIL。那是刻意的。

但「要改哪七個地方」與「改成什麼形式」是兩件事，而後者散在
`bin/lib/verify_meta.py` 的註解裡，寫新動詞的人不會去讀那個檔。
這份文件把形式要求收在一起。

## 七個地方

| # | 地方 | 抓它的檢查 |
|---|---|---|
| 1 | `bin/cmd/<verb>.sh`，定義 `cmd_<verb>_main()` | `CLI-verbs`、`CLI-orphan` |
| 2 | `cx` 的 `CX_CMD_FILE_OF`（**只有**動詞名 ≠ 檔名時） | `CLI-verbs` |
| 3 | `bin/completion/cx.bash` 的 `verbs=` | `CLI-verbs`（它是權威清單之一） |
| 4 | `bin/cmd/help.sh` | `CLI-help` |
| 5 | `bin/cmd/tui.sh` 的選單 | `TUI-coverage`、`TUI-resolve` |
| 6 | `docs/cx/cx-reference.md` | `DOC-cx-verbs` |
| 7 | `claude.md` §10 的檔案地圖 | `DOC-filemap` |

> 第 7 項是 2026-09-06 加上的。`check_doc_filemap` 要求地圖列出**每一個**
> `bin/cmd/*.sh` 與 `bin/lib/*.{py,sh}` 的 stem。
>
> ⚠ 那條檢查用的是 `\b<stem>\b` 的鬆散比對，所以短的通用單字
>（`open`、`code`、`test`、`db`、`art`、`php`、`npm`）可能因為文件別處
> 剛好出現過同一個字而**誤過**。加新檔時還是要手動把它加進地圖。

## 形式要求（機器契約，不是風格建議）

### 3. 補全 `bin/completion/cx.bash`

```bash
local verbs='help doctor setup … open status php
             art composer npm db test sonar deploy
             dev prod up down restart ps logs sh build config dc'
```

這份清單是 `cx` **到底做得到什麼**的權威來源之一 —— `doctor` 與
`verify_meta.py` 都剖析它。子指令補全另外加一個 `case` 分支：

```bash
        open)
            COMPREPLY=($(compgen -W "front back api pma sonar list --url --no-open --help -h" -- "$cur")) ;;
```

⚠ `TUI-resolve` 會拿這個清單去比對 TUI 裡的 `_tui_run <verb> <sub>` ——
選單裡出現的子指令必須在這裡宣告過，否則會被判定成「不是 `<verb>` 的子指令」。

### 4. `bin/cmd/help.sh`

`check_cli_help_sync` 的 regex 要求 **2–4 空白縮排**：

```
  open [目標]       開啟服務網址：front / back / api / pma / sonar / list
                    續行可以更深，但第一行必須是 2–4 空白
```

`cx git` 的子指令另有一條 regex（`^\s*git ([a-z][a-z-]*)`）：

```
  git hotfix start|finish|list --repo backend|frontend
```

### 5. `bin/cmd/tui.sh`

**`_tui_run <verb>` 必須是字面的，不能寫成 `_tui_run <verb> "$kind"` 那種變數展開。**
`check_tui` 是靜態 regex 剖析，看不到變數。實例：`_tui_git_flow` 同時服務
`feature` 與 `hotfix`，但它裡面寫的是

```bash
if [[ $kind == hotfix ]]; then _tui_run git hotfix list
else                           _tui_run git feature list; fi
```

而不是 `_tui_run git "$kind" list` —— 後者會讓 `TUI-resolve` 兩個子指令都抓不到。

主選單的項目（`items+=(...)` 裡）要 **8 空白以上**縮排，
而模式門檻用 `# @tui-mode: <清單>` 標記分段：

```bash
    # @tui-mode: test
    if [[ $_TUI_MODE == test ]]; then
        items+=(
            test   "測試：後端 / 前端 / 覆蓋率"
            scan   "DevSecOps：四道防線"
        )
    fi
```

標記與 `if` 條件必須一致。**標記整個消失時 `TUI-coverage` 會 FAIL** ——
否則它會安靜地退回「整份檔案出現過什麼」的舊語意，而那個語意證明不了可達性。

真的不該進選單的動詞要加進 `verify_meta.py` 的 `CLI_ONLY` 豁免清單並寫明理由。

### 6. `docs/cx/cx-reference.md`

`DOC-cx-verbs` 的 regex 是 `` r"`cx %s[ `]" ``，所以反引號內必須是
`` `cx open` `` 或 `` `cx open --url` `` 這種形式。章節標題慣例：

```markdown
## `cx open` — 開啟服務網址
```

### `cx git` 的子指令：四方一致（`GIT-subs`）

`cmd_git_main` 的 case 臂縮排必須**恰好 8 空白**：

```bash
        hotfix)        _git_hotfix "$@" ;;
```

`_git_usage` 的 heredoc 用 **2 空白**。四個來源（dispatch case、usage、
補全、help）任一少一個都會 FAIL，而且訊息會告訴你少在哪一方。

## 常見的兩個坑

**usage 裡不要提到全域旗標。** `CLI-flags` 會把 usage 文字裡看起來像旗標的
東西拿去比對「parser 接不接受」，而 `--mode` / `--runner` 是 `cx` 這一層處理的。
2026-09-06 實例：`cx open` 的 usage 寫了「網址依目前的 `--mode` 決定」，
`CLI-flags` 就報 `open.sh:--mode`。改成「依目前的模式」即可。

**新增 mode 或 phase 不會被 `TUI-coverage` 抓到。** 那條檢查是**動詞層級**的。
`cx fresh --mode git-only` 加完之後 TUI 那一項漏了，`cx verify` 全綠 ——
所以動詞以外的新選項要自己記得走第 5 項。

## 改完之後

```bash
cx verify cli docs tui      # 七處的機器版本
cx test cli                 # 新動詞至少要有一個 bats 檔
```

並依 `claude.md` §0 紅線 7：**功能改動一旦測過可用，對應文件必須在同一個
commit 內更新。**
