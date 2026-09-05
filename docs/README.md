# docs/ — pm 專案文件

| 文件 | 內容 | 讀者 |
|---|---|---|
| [`manual.md`](manual.md) | **完整操作說明書**。從零開始到三個階段全流程 | 所有人，先讀這份 |
| [`cx-reference.md`](cx-reference.md) | `cx` 每一個動詞的完整參考：語法、參數、行為、退出碼、陷阱 | 日常操作 |
| [`docker-reference.md`](docker-reference.md) | 合併鏈、三模式差異、多階段映像、edge / WAF 設定 | 改 compose / Dockerfile 之前 |
| [`ansible-reference.md`](ansible-reference.md) | play 結構、12 個 role、vault、MySQL 五個坑 | 改 Ansible / 上真機之前 |
| [`runners.md`](runners.md) | **兩條 runner**：容器與原生各自需要什麼、怎麼一行裝起來、產出為何不可互換 | 沒有 Docker、或要驗證原生路徑 |
| [`devsecops.md`](devsecops.md) | 四道防線的原理、閘門定義、退出碼、報告格式 | 掃描與 CI |
| [`troubleshooting.md`](troubleshooting.md) | 症狀 → 原因 → 解法。全部是實際踩過的坑 | 出事的時候 |
| [`reports.md`](reports.md) | **測試與掃描的報告怎麼看**：目錄結構、逐檔案讀法、退出碼、SKIP 不等於 PASS | 跑完測試或掃描之後 |
| [`template.md`](template.md) | 拿這個 repo 當**新專案範本**：哪些能刪、哪些不可重建、改 `.cxroot` 會連帶換掉什麼 | 開新專案 |
| [`acceptance.md`](acceptance.md) | 驗收清單：原始需求 → 檢查 ID → 實測結果 |
| [`progress.md`](progress.md) | 進度追蹤與「還沒驗證什麼」 | 交接、規劃 |
| [`docker-verification.md`](docker-verification.md) | Phase 2 的驗收需求與實測結果 | 稽核 |
| [`../docker/ansible-target/README.md`](../docker/ansible-target/README.md) | **本機驗證用的 Ansible 目標容器**：怎麼建 22.04 / 24.04 / 26.04、systemd 需要什麼 | 在 WSL 內驗證部署 |

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
| 想完全不用 Docker | `runners.md` |
| 要裝 php / nginx / git / docker / composer / npm | `cx setup native`，細節見 `runners.md` §2 |
| 想知道測試與掃描的結果在哪、怎麼讀 | `reports.md` |
| 要拿這個 repo 開新專案 | `template.md` |
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
