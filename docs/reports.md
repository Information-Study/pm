# 測試與掃描的報告怎麼看

> 所有輸出都落在 `reports/`。這個目錄**進版控但內容不進**
>（`.gitignore` 排除內容，保留目錄結構），所以可以安心刪除重建。

---

## 1. 目錄結構

```
reports/
├── verify/     cx verify 的驗收報告（Markdown，帶時間戳）
├── quality/    ① Larastan、覆蓋率、junit
├── sast/       ② Semgrep（SARIF + 文字摘要）
├── sca/        ③ Trivy、composer audit、npm audit
├── dast/       ④ OWASP ZAP（HTML / JSON / MD）
│   └── compare/  WAF DetectionOnly 對 On 的對照與攔截率
├── secrets/    gitleaks
└── db/         cx db dump 的備份
```

`reports/` 的葉目錄必須由 `cx setup dirs` 以**你的身分**建立。
讓 Docker 去建會是 `root:root 0755`，之後以 uid 1000 執行的
Trivy / Semgrep / PHPStan / ZAP 全部 EACCES。

---

## 2. 最快的看法

```bash
cx verify                      # 跑驗收，最後一行就是報告路徑
ls -t reports/verify | head -3 # 最近三份
```

`cx verify` 每次都會印出總結並附上報告路徑：

```
══ 總結 ══
  通過 39 ・ 失敗 0 ・ 未驗 0
✔ 報告：/home/you/pm/reports/verify/20260904T035945Z.md
```

報告本身是一張 `PASS / FAIL / SKIP` 的逐項表格。

> **`SKIP` 不等於 `PASS`。** 它的意思是「這次沒辦法驗」——
> 容器沒起來、工具沒裝、或那一項只在別的模式有意義。
> 把 SKIP 當成通過，是驗收報告最常見的誤讀。

---

## 3. 各道防線的報告

| 指令 | 產出 | 怎麼看 |
|---|---|---|
| `cx scan code` | `reports/quality/` | Larastan 的文字輸出；有 SonarQube 時另有 Quality Gate |
| `cx scan sast` | `reports/sast/semgrep.sarif` | SARIF；`bin/lib/sarif_gate.py` 依 `level` 分級 |
| `cx scan sca` | `reports/sca/` | Trivy JSON + `composer audit` / `npm audit` 輸出 |
| `cx scan dast` | `reports/dast/` | ZAP 的 HTML 報告最好讀；`compare/` 是 WAF 對照 |
| `cx scan secrets` | `reports/secrets/` | gitleaks 的 finding |
| `cx test coverage` | `reports/quality/coverage-backend.xml`、`junit-backend.xml` | Clover / JUnit 格式，給 CI 與 Sonar 用 |

### 退出碼比報告更適合給 CI 判斷

| 碼 | 意義 |
|---|---|
| 0 | 乾淨 |
| 20 | ① Quality 有 finding |
| 21 | ② SAST 有 **ERROR 等級** finding |
| 22 | ③ SCA 有 finding |
| 23 | ④ DAST 有 High risk alert |
| 3 | 工具沒裝／目標不存在（**環境問題，不是掃描結果**） |

分開的理由：用單一的「非零 = 失敗」會讓「Semgrep 根本沒跑起來」跟
「找到 SQL injection」在 CI 上長得一模一樣。

---

## 4. DAST 的兩份報告要一起看

`cx scan dast` 會跑兩次：`DetectionOnly`（WAF 只記錄）與 `On`（WAF 真的擋）。

- 兩份的**差集** = 「WAF 現在幫你擋著、但應用本身還沒修」的清單
- 只看 `On` 那一份會讓 WAF 變成遮羞布：應用的漏洞還在，但掃描是綠的

`reports/dast/compare/waf-probe.json` 記錄攔截率（攻擊擋掉幾項、正常請求誤擋幾項）。

### ZAP 的退出碼不是「0 成功 / 非 0 失敗」

| ZAP rc | 意義 | cx 的處置 |
|---|---|---|
| 0 | 沒有 alert | 通過 |
| 1 | 至少一個 FAIL | `EX_SCAN_DAST`(23) |
| 2 | **只有 WARN** | **通過** |
| ≥3 | 工具本身出錯 | `EX_FAIL`，不是掃描結果 |

把 ≥3 當成功，會讓「ZAP 根本沒跑起來」被記成「沒有漏洞」。

---

## 5. 測試

```bash
cx test back        # 後端 PHPUnit（sqlite :memory:，不需要 MySQL）
cx test front       # 前端型別檢查（nuxt typecheck）
cx test all
cx test coverage    # 覆蓋率（只有容器路徑，需要 test 映像的 xdebug）
```

`cx test back` 的結果直接印在終端機；`coverage` 才會產生檔案。
覆蓋率報告會從容器 `docker cp` 出來放到 `reports/quality/`，
因為 `sonar-project.properties` 指定的是那個路徑。

---

## 6. 這些報告可以安全刪除

`reports/` 底下的**內容**全部是產出物，刪掉再跑一次就有。

```bash
rm -rf reports && cx setup dirs     # 重建空的目錄骨架
```

備份（`reports/db/`）例外 —— 那是資料，不是產出物。刪之前先確認你不需要它。
