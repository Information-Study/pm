# docs/ — pm 專案文件

| 文件 | 內容 | 讀者 |
|---|---|---|
| [`manual.md`](manual.md) | **完整操作說明書**。從零開始到三個階段全流程 | 所有人，先讀這份 |
| [`cx-reference.md`](cx-reference.md) | `cx` 每一個動詞的完整參考：語法、參數、行為、退出碼、陷阱 | 日常操作 |
| [`docker-reference.md`](docker-reference.md) | 合併鏈、三模式差異、多階段映像、edge / WAF 設定 | 改 compose / Dockerfile 之前 |
| [`ansible-reference.md`](ansible-reference.md) | play 結構、12 個 role、vault、MySQL 五個坑 | 改 Ansible / 上真機之前 |
| [`devsecops.md`](devsecops.md) | 四道防線的原理、閘門定義、退出碼、報告格式 | 掃描與 CI |
| [`troubleshooting.md`](troubleshooting.md) | 症狀 → 原因 → 解法。全部是實際踩過的坑 | 出事的時候 |
| [`progress.md`](progress.md) | 進度追蹤與「還沒驗證什麼」 | 交接、規劃 |
| [`docker-verification.md`](docker-verification.md) | Phase 2 的驗收需求與實測結果 | 稽核 |

## 該讀哪一份

| 你想做的事 | 讀 |
|---|---|
| 第一次拿到這個專案 | `manual.md` §1–§3 |
| 忘記某個指令怎麼用 | `cx help`，然後 `cx-reference.md` |
| 三個模式為什麼可以同時跑 | `manual.md` §4 |
| 改 `docker-compose.yml` | `docker-reference.md` §1–§2 |
| 加一個 nginx location | `docker-reference.md` §6 |
| 上真的伺服器 | `ansible-reference.md` 全部 |
| CI 要怎麼串 | `devsecops.md` §9 |
| 東西壞了 | `troubleshooting.md` |
| 交接 / 知道還缺什麼 | `progress.md` |

## 這份文件集的原則

**只寫實際驗證過的東西。** 沒跑過的一律標明「未驗證」，不用「應該」「理論上」帶過。
每一個「不要這樣做」的警告後面都附著實際的失敗訊息 —— 因為看得懂錯誤訊息
比記得住規則有用。

## 三份權威來源

當文件彼此衝突時，以這個順序為準：

1. **`cx help` 的輸出** —— 動詞與參數的唯一權威。程式碼改了它就會跟著改。
2. **`cx verify` 的報告**（`reports/verify/`）—— 驗收狀態的唯一權威。
3. **根目錄的 `claude.md`** —— 設計原理與每個坑的來由。

這裡的 `docs/` 是「怎麼用」，`claude.md` 是「為什麼這樣設計」。
