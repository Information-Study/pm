# 測試與掃描的報告怎麼看

> 所有輸出都落在 `reports/`。這個目錄**進版控但內容不進**
>（`.gitignore` 排除內容，保留目錄結構），所以可以安心刪除重建。

---

## 1. 目錄結構

```
reports/
├── verify/     cx verify 的驗收報告（Markdown，帶時間戳）
├── quality/    ① larastan.json、coverage-backend.xml、junit-backend.xml
├── sast/       ② semgrep.sarif
├── sca/        ③ trivy-fs.json、composer-audit.json、npm-audit.json
├── dast/       ④ OWASP ZAP
│   ├── detect/     WAF = DetectionOnly 那一輪的 report.json / report.html
│   ├── blocking/   WAF = On 那一輪
│   └── compare/    兩輪的對照與 WAF 攔截率
├── secrets/    gitleaks-{pm,backend,frontend}.json
├── waf/        ModSecurity audit log（手動擷取，見下方 §8）
└── db/         cx db dump 的備份
```

`reports/` 的葉目錄必須由 `cx setup dirs` 以**你的身分**建立。
讓 Docker 去建會是 `root:root 0755`，之後以 uid 1000 執行的
Trivy / Semgrep / PHPStan / ZAP 全部 EACCES。

---

## 2. 最快的看法

```bash
cx verify                      # 驗收（39 項）→ reports/verify/<時間戳>.md
cx scan all                    # 四道防線 + 祕密掃描 → reports/ 底下各自的目錄
cx test all                    # 測試套件（結果只印在終端機）
```

> `cx scan all` **不會**遇到第一個問題就停。四道防線加祕密掃描全部跑完，
> 最後回傳最嚴重的那個退出碼。停在第一道會讓後面幾道永遠沒機會跑，
> 而掃描的價值正是「一次看到全部」。


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
| `cx scan code` | `reports/quality/larastan.json` | Larastan（level 5，設定在 `backend/phpstan.neon.dist`）；有 SonarQube 時另有 Quality Gate |
| `cx scan sast` | `reports/sast/semgrep.sarif` | SARIF（只有這一個檔，沒有文字摘要）；`bin/lib/sarif_gate.py` 只把 **ERROR** 等級算成失敗 |
| `cx scan sca` | `reports/sca/` | Trivy JSON + `composer audit` / `npm audit` 輸出 |
| `cx scan dast` | `reports/dast/{detect,blocking}/report.{json,html}` | HTML 那份最好讀；`compare/` 是 WAF 對照 |
| `cx scan secrets` | `reports/secrets/gitleaks-*.json` | 三個 repo 各一份，`[]` 代表乾淨 |
| `cx test coverage` | `reports/quality/coverage-backend.xml`、`junit-backend.xml` | Clover / JUnit 格式，給 CI 與 Sonar 用 |

### 退出碼比報告更適合給 CI 判斷

| 碼 | 意義 |
|---|---|
| 0 | 乾淨 |
| 20 | ① Quality 有 finding |
| 21 | ② SAST 有 **ERROR 等級** finding |
| 22 | ③ SCA 有 finding（**gitleaks 的祕密 finding 也用這個碼**） |
| 23 | ④ DAST 有 High risk alert |
| 3 | 工具沒裝／目標不存在（**環境問題，不是掃描結果**） |

分開的理由：用單一的「非零 = 失敗」會讓「Semgrep 根本沒跑起來」跟
「找到 SQL injection」在 CI 上長得一模一樣。

---

## 4. DAST 的兩份報告要一起看

`cx scan dast` 會跑兩次：`DetectionOnly`（WAF 只記錄）與 `On`（WAF 真的擋）。

- 兩份的**差集** = 「WAF 現在幫你擋著、但應用本身還沒修」的清單
- 只看 `On` 那一份會讓 WAF 變成遮羞布：應用的漏洞還在，但掃描是綠的

攔截率看 `reports/dast/compare/waf-probe.json`（主動攻擊探測：攻擊擋掉幾項、
正常請求誤擋幾項）。**不要**拿 `waf-effectiveness.json` 的差值當攔截率 ——
`zap-baseline.py` 是被動掃描，不送攻擊 payload，兩個模式看到的回應標頭本來就一樣，
所以那個差值恆為 0。畫面上會同時出現「主動探測擋下 100%」與「被動 alert 差 0 項」，
兩個都對，量的是不同東西。

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

`cx test back` 的結果直接印在終端機；只有 `coverage` 會產生檔案。
覆蓋率報告會從容器 `docker cp` 出來放到 `reports/quality/`，
因為 `sonar-project.properties` 指定的是那個路徑。

`cx test coverage` **測試失敗時回傳測試的退出碼，但報告照樣產生** ——
測試失敗的時候 junit 報告才是最有用的，不能因為 rc 非 0 就跳過。
（2026-09-04 之前它一律回傳 0，在 CI 上是一個永遠綠的步驟。）

⚠ 跑測試請一律用 `cx test`，不要在容器裡裸跑 `php artisan test` ——
`phpunit.xml` 的 `force="true"` 擋不住 compose 注入的環境變數，
裸跑會打到真正的開發資料庫。原因見
[`troubleshooting.md`](troubleshooting.md) 的「測試」一節。

```bash
# 覆蓋率總計（Clover XML 的根節點就有全專案數字）
python3 -c 'import xml.etree.ElementTree as E;m=E.parse("reports/quality/coverage-backend.xml").getroot().find("project/metrics");print(m.get("coveredstatements"),"/",m.get("statements"))'

# 失敗了哪幾個測試（JUnit XML）
python3 -c 'import xml.etree.ElementTree as E;[print(t.get("classname"),t.get("name")) for t in E.parse("reports/quality/junit-backend.xml").iter("testcase") if len(t)]'
```

前端目前**沒有測試框架** —— `cx test front` 跑的是 `nuxt typecheck`（型別檢查），
不是單元測試，也不產生報告檔。`sonar-project.properties` 裡的
`coverage-frontend/lcov.info` 目前沒有任何東西會產生它。

---

## 6. 這些報告可以安全刪除

`reports/` 底下的**內容**全部是產出物，刪掉再跑一次就有。

```bash
rm -rf reports && cx setup dirs     # 重建空的目錄骨架
```

`cx setup dirs` 會把兩個進版控的檔案一起補回來：`.gitignore`（heredoc 重寫）
與 `README.md`（從版控 `git checkout` 取回）。重建之後 `git status reports/`
應該是空的 —— 如果不是，代表有東西沒還原。

備份（`reports/db/`）例外 —— 那是資料，不是產出物。刪之前先確認你不需要它。
還沒 commit 的改動也不在保護範圍內：`git checkout` 取回的是版控裡的版本。

---

## 7. 逐個檔案怎麼讀

這些都是機器格式，用眼睛掃 JSON 很痛苦。下面是各報告最短的「只看重點」指令
（本專案沒有 `jq`，所以一律用 `python3`，免安裝）。

```bash
# ① Larastan：有幾個錯、分別在哪
#    ⚠ 兩個坑。第一，這個檔可能是 JSONL（phpstan 有 note 要說的時候會多吐一行），
#      json.load(整個檔) 會炸。第二，**不要看頂層的 "errors"** ——
#      那是「通用錯誤」的陣列（設定檔問題之類），不是計數；
#      100 個檔案錯誤時它仍然是 []，看起來永遠乾淨。
#      要看的是 totals.file_errors。
python3 -c 'import json;[print("file_errors=%s generic=%s"%(d["totals"]["file_errors"],d["totals"]["errors"])) for l in open("reports/quality/larastan.json") if l.strip() for d in [json.loads(l)] if isinstance(d.get("totals"),dict)]'
python3 -c 'import json;[print(f,m["line"],m["message"]) for l in open("reports/quality/larastan.json") if l.strip() for d in [json.loads(l)] if isinstance(d.get("files"),dict) for f,v in d["files"].items() for m in v["messages"]]'

# ② Semgrep：只列 ERROR 等級（那才是會擋 CI 的）
python3 -c 'import json;d=json.load(open("reports/sast/semgrep.sarif"));[print(r["level"],r["ruleId"],r["locations"][0]["physicalLocation"]["artifactLocation"]["uri"]) for run in d["runs"] for r in run["results"] if r.get("level")=="error"]'

# ③ Trivy：只列 HIGH / CRITICAL
python3 -c 'import json;d=json.load(open("reports/sca/trivy-fs.json"));[print(v["Severity"],v["VulnerabilityID"],v.get("PkgName")) for r in (d.get("Results") or []) for v in (r.get("Vulnerabilities") or []) if v["Severity"] in ("HIGH","CRITICAL")]'

# ④ ZAP：HTML 那份直接用瀏覽器開最快
cx code reports/dast/blocking/report.html      # 或 xdg-open / explorer.exe

# 祕密掃描：空陣列 [] 就是乾淨
head -c 200 reports/secrets/gitleaks-pm.json
```

`cx scan` 每一道跑完都會自己印出報告路徑，所以通常不必記這些路徑 ——
往上捲就看得到。

---

## 8. WAF 的 audit log

`reports/waf/` 不是掃描器產生的，要自己從 test 模式的 WAF 容器擷取：

```bash
cx --mode test logs waf | grep '^{' > reports/waf/audit.jsonl

# 被擋下來的請求各是哪一條 CRS 規則
python3 -c 'import json,sys;[print(t["transaction"]["messages"][0]["details"]["ruleId"], t["transaction"]["request"]["uri"]) for l in open("reports/waf/audit.jsonl") if (t:=json.loads(l)).get("transaction",{}).get("messages")]'
```

這份與 `reports/dast/compare/` 是互補的：`compare/` 說「攔截率是多少」，
audit log 說「是被哪一條規則攔的」。調 CRS 誤擋的時候需要後者。
