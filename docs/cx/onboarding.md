# 人員接續專案

> 這一份給「**接手一個已經在跑的 pm 專案**」的人。
>
> 不是這一份的情境：
> * 拿這個 repo 當**新**專案的範本 → [`../guide-developer.md`](../guide-developer.md) §0（`cx init`）
> * 已經在專案裡寫功能 → [`../guide-developer.md`](../guide-developer.md) §1 起

## 為什麼需要一份獨立的文件

clone 完之後有五件事**不會**自動就緒，而它們的失敗訊息都不會說出真正的原因：

| 缺什麼 | 症狀 |
|---|---|
| `.env` | 不進版控。缺了它 compose 的 DB 憑證與 UID/GID 全是預設值 |
| `env/ansible/inventory/hosts.yml` | 不進版控。`cx deploy` 每一個動詞都撞牆 |
| 子模組的分支 | clone 之後是 **detached HEAD**，`git status` 看起來很正常 |
| push guard | **選用，預設不安裝**（2026-09-04 起）。`cx doctor` 顯示 0/3 |
| 子模組的 origin | 可能還指著範本的 repo |

## 流程

```bash
# 1. clone —— --recurse-submodules 不是選用的
git clone --recurse-submodules git@github.com:<組織>/<repo>.git
cd <repo>

# 2. 先看現況（這兩個動詞在什麼都沒裝的樹上都跑得起來）
./cx status                    # 身分／版面版號／容器／分支／gitlink／上次驗收
./cx doctor                    # 環境能不能用；有問題會回非 0

# 3. 工具鏈
./cx setup native              # system(需 root) + tools(~/.local) + 專案相依
                               # cx 絕不偷偷跑 sudo —— 不可用時只把 apt-get 那行印出來

# 4. 產生 .env（⚠ 已存在時會早退，不會覆寫）
./cx setup env
./cx verify cli                # TPL-env 應該是綠的

# 5. git 身分（三個 repo 一起設）
./cx git config identity

# 6. 子模組接回分支
./cx git sync                  # 依主庫目前在哪條線決定接到 main 還是 dev

# 7. 起環境
./cx dev up -d --build
./cx verify static app
./cx open                      # 印出這個模式的所有服務網址

# 8. 確認自己拿到的是完整的樹
./cx test cli                  # cx 自己的行為測試
./cx test back                 # 後端測試（sqlite :memory:）
```

## 要另外知道的五件事

**`cx status` 與 `cx doctor` 的分工。**
`status` 回答「這棵樹現在是什麼狀態」，**永遠 rc=0**；
`doctor` 回答「環境能不能用」，有問題就非 0。接手的人兩個都該先跑一次。

**`cx git sync` 依主庫當前分支決定子模組要站哪條線。**
`.gitmodules` 只能寫一個 branch 值，而主庫有 `main`（發布）與 `dev`（開發）
兩條線。所以主庫在 `dev` 時子模組也去 `dev`，在 `main` 時去 `main` ——
`.gitmodules` 的值只是 fallback。站在 `feature/*` 或 `hotfix/*` 上的子模組
`sync` **不會動它**（有人正在上面工作）。

**push guard 是選用的。**
`cx git guard install` 才會裝 pre-push hook。**沒裝也不代表沒有防線** ——
`cx git push` 開頭一定會跑 gitleaks 全歷史掃描、白名單檢查與子模組順序。
繞過它的是**裸 `git push`**，那條路沒有任何檢查。

**`hosts.yml` 要自己產生。**
```bash
./cx deploy hosts init --env staging
./cx deploy hosts add <名稱> --ip <IP> --user <帳號>
./cx deploy hosts check --ansible
```

**子模組的 remote 可能還是範本的。**
`./cx git status` 會把三個 repo 的 origin 都印出來。要改用
`cx git remote-set <URL>` 或 `cx git remote-init`（後者用 `gh` 建新的）。

## 開始工作之前

```bash
./cx git flow-init             # 補齊三個 repo 的 main/dev 拓撲（冪等）
./cx git feature start <名稱> --repo backend|frontend
```

工作分支**只開在子模組**；主庫只有 `main ← dev` 兩條線，它的 `dev` 會在
`feature finish` 時同步 gitlink。緊急修正用 `cx git hotfix`（拓撲相同，
只是前綴不同）。發布到 `main` 用 `cx git release`。

完整的日常流程見 [`../guide-developer.md`](../guide-developer.md)。
