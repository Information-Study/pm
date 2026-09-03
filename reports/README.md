# reports/

DevSecOps 四道防線的輸出目錄。內容不進版控，但**目錄本身必須進版控**。

| 子目錄 | 產生者 |
|---|---|
| `quality/` | SonarQube scanner、Larastan |
| `sast/` | Semgrep |
| `sca/` | Trivy（fs / secret / misconfig / image） |
| `dast/` | OWASP ZAP（`no-waf` / `detect` / `blocking` / `compare`） |
| `waf/` | ModSecurity audit log |

葉目錄由 `cx` 以呼叫者身分預先建立 —— 不能讓 Docker 自動建立，否則會是 root:root。
