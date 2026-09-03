# docs/ — 驗證需求文件

本目錄存放**需要另一個對話 / 另一位負責人驗證**的項目。
每份文件都是「驗證需求規格」，不是實作說明 —— 實作原則見根目錄的 `claude.md`。

| 文件 | 負責範圍 | 狀態 |
|---|---|---|
| [docker-verification.md](docker-verification.md) | Docker 三模式架構、多階段映像、edge、WAF、掃描容器 | ⏳ 待驗證（交由另一對話） |

## 使用方式

接手的對話請：

1. 先讀根目錄 `claude.md`（尤其是 §0 紅線、§4 Docker、§5 DevSecOps）。
2. 再讀本目錄對應的驗證需求文件。
3. 逐項驗證，把結果回填到該文件的「驗證結果」欄。
4. 發現新問題就補進「追加發現」一節。

## 先決條件

**Docker daemon 目前在本機不可用** —— Docker Desktop 的 WSL integration 沒開啟。
`docker` 在 PATH 裡但 `docker version --format '{{.Server.Version}}'` 會失敗：

```
The command 'docker' could not be found in this WSL 2 distro.
```

任何 Docker 驗證都要先開啟 Docker Desktop → Settings → Resources → WSL Integration。
`cx doctor` 的第一項檢查就是這個（用 `docker version` 而非 `command -v docker`，因為後者會騙人）。
