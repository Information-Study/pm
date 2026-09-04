# reports/

測試、驗收與 DevSecOps 四道防線的輸出目錄。
內容不進版控，但**目錄本身必須進版控**（`reports/.gitignore` 只放行自己與這份 README）。

| 子目錄 | 產生者 | 主要檔案 |
|---|---|---|
| `quality/` | `cx scan code`、`cx test coverage` | `larastan.json`（**JSONL**，計數看 `totals.file_errors` 不是頂層 `errors`）、`coverage-backend.xml`、`junit-backend.xml` |
| `sast/` | `cx scan sast` | `semgrep.sarif` |
| `sca/` | `cx scan sca` | `trivy-fs.json`、`composer-audit.json`、`npm-audit.json` |
| `secrets/` | `cx scan secrets` | `gitleaks-{pm,backend,frontend}.json` |
| `dast/` | `cx scan dast` | `detect/`、`blocking/` 各一份 `report.json` + `report.html`。`compare/waf-probe.json` 是**攔截率**（主動送攻擊量出來的）；`compare/waf-effectiveness.json` 只是被動 alert 差異，**不是攔截率** |
| `waf/` | 手動擷取 ModSecurity audit log | `cx --mode test logs waf \| grep '^{' > reports/waf/audit.jsonl` |
| `verify/` | `cx verify` | `<UTC 時間戳>.md`（PASS / FAIL / SKIP 逐項表） |
| `db/` | `cx db dump` | `<mode>-<時間>.sql.gz` |

葉目錄由 `cx setup dirs` 以呼叫者的身分預先建立 —— 不能讓 Docker 自動建立，
否則會是 `root:root 0755`，之後以 uid 1000 執行的 Trivy / Semgrep / PHPStan / ZAP 全部 EACCES。

## 怎麼看這些報告

完整說明在 [`docs/reports.md`](../docs/reports.md)。最短版本：

```bash
cx verify                        # 跑驗收，最後一行就是報告路徑
ls -t reports/verify | head -3   # 最近三份
```

CI 判斷用退出碼比讀報告可靠：`20`/`21`/`22`/`23` 各代表一道防線有 finding，
`3` 是環境問題（工具沒裝、Docker 不可用），不是掃描結果。

## 可以安心刪掉重建

`db/` 是**資料**不是產出物 —— 其餘都可以刪掉重跑。

```bash
rm -rf reports && cx setup dirs
```

`cx setup dirs` 會重建葉目錄、補回 `reports/.gitignore`，
並且在版控可用時把這份 README 一起 `git checkout` 回來。
