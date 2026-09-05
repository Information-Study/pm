# DevSecOps 四道防線

> 掃描與 CI 的完整說明。每一道防線都有明確的閘門定義與專屬的退出碼，
> CI 才分得出「掃描器有意見」與「掃描器當掉」。

---

## 0. 總覽

| 防線 | 指令 | 工具 | 閘門 | 退出碼 | 報告 |
|---|---|---|---|---|---|
| ① Quality | `cx scan code` | Larastan (level 5) + SonarQube | 任一 finding | 20 | `reports/quality/larastan.json` |
| ② SAST | `cx scan sast` | Semgrep | **只有 `error` 等級** | 21 | `reports/sast/` |
| ③ SCA | `cx scan sca` | Trivy + `composer audit` + `npm audit` | 任一 finding | 22 | `reports/sca/` |
| ④ DAST | `cx scan dast` | OWASP ZAP baseline | High risk alert | 23 | `reports/dast/` |
| 祕密 | `cx scan secrets` | gitleaks（全歷史） | 任一 finding | **22**（與 ③ 共用） | `reports/secrets/gitleaks-*.json` |

```bash
cx scan all                      # ①②③④ 再加 secrets，全部跑完
cx scan all --runner native      # 用 ~/.local 的二進位
cx scan all --runner docker      # 用容器
```

> `all` **不是**「任一失敗即停」。五道全部跑完，最後回傳其中**最嚴重**的退出碼。
> 停在第一道會讓後面幾道永遠沒機會跑，而掃描的價值就在於一次看到全部問題。

`--runner auto`（預設）**有可用的 Docker daemon 就走容器**，沒有才走原生
（`cx_runner()` 在 `bin/lib/common.sh`）。ZAP 只有 docker 一條路（要 Java）。

被 `--runner` 明確指定的那一邊不可用時是**硬失敗**，不會偷偷換另一邊 ——
否則「原生路徑可以獨立運作」永遠無法被驗證。

---

## 1. 為什麼退出碼要分開

```bash
cx scan sast; rc=$?
case $rc in
  0)  echo "乾淨" ;;
  21) echo "有 ERROR 等級的 finding，擋 merge" ;;
  3)  echo "Semgrep 沒裝 / 目標不存在，這是環境問題" ;;
  *)  echo "工具當掉" ;;
esac
```

用單一的「非零 = 失敗」會讓「Semgrep 根本沒跑起來」跟「找到 SQL injection」
在 CI 上長得一模一樣。第一種情況會被當成「修一下 CI 設定」，
第二種是真的要擋人。

### 反過來也一樣危險：把「掃不成」報成「掃乾淨了」或「有問題」

工具的退出碼常常一碼多義。`npm audit` 的 `exit 1` 同時代表
「找到漏洞」與「連不到 registry」——

```json
{"message":"network timeout at: https://registry.npmjs.org/…","error":{…}}
```

只看退出碼的話，一次網路抖動就會變成一份假的資安報告：CI 拿到 22
（SCA 有問題），有人去查 npm-audit.json，裡面根本沒有漏洞清單。

所以 `cx scan sca` 跑完會再看報告本身：成功的 audit 一定有
`auditReportVersion` / `metadata` / `vulnerabilities`，
沒有就改判 `EX_PRECOND`(3) 並印出真正的原因。

同樣的邏輯也適用於 ZAP（見 §5 的退出碼映射）與 Larastan
（報告是 JSONL，而且**有兩種格式**：標準的 `{"totals":{"file_errors":N}}` 與
扁平的 `{"result":"failed","errors":N}`。標準格式裡頂層的 `errors` 是通用錯誤
**陣列**不是計數，扁平格式裡它才是整數 —— 只認一種的話另一種會靜靜印出空白，
跟「乾淨」長得一模一樣。讀法見 `docs/reports.md` §7 ①）。

---

## 2. ① Quality

### Larastan

`level: 5`，設定在 `src/backend/phpstan.neon.dist`（另有 `checkModelProperties: true`）。
第 5 級的意思是「型別完整但不強制所有 array 泛型」，新專案可以逐步往上提。

報告 `reports/quality/larastan.json` 是 **JSONL**（一行一個 JSON 物件），
不是單一 JSON —— phpstan 有 note 要說時會多吐一行 `{"tool":…,"raw":[…]}`。
用 `json.load(整個檔)` 讀會 JSONDecodeError。

### SonarQube

`cx sonar up` 起一個常駐的 SonarQube（獨立 compose project `<專案>_devsecops`，
本專案是 `pm_devsecops`；網路 `pm_devsecops_net`，不干擾三個模式）。
前綴跟著 `.cxroot` 的 `CX_PROJECT_NAME` 走，見 `bin/lib/common.sh` 的 `cx_sonar_project()`。

token 從 `.cx/sonar-token` 讀（mode 0600）。
**不用 `${SONAR_TOKEN:?}`** —— 在 `set -u` 之下，`:?` 會直接讓整個 shell 結束，
連「SonarQube 未設定，略過」這行訊息都印不出來。
沒有 token 就跳過 Sonar 那一段，Larastan 照跑。

```bash
cx sonar up
cx sonar wait          # 等它真的可以接受掃描
cx sonar token         # 引導產生並存檔
cx sonar url           # 印出網址
cx scan code
```

---

## 3. ② SAST（Semgrep）

### 不使用 `--error`

`semgrep --error` 的語意是「只要有任何 finding 就回傳非零」。
於是 INFO 等級的風格建議跟 SQL injection 有同樣的效果 ——
閘門一定會被關掉，而關掉之後就再也沒有閘門了。

改成**永遠產出 SARIF**，再由 `bin/lib/sarif_gate.py` 依 `level` 分級：

| SARIF level | 處置 |
|---|---|
| `error` | 回傳 `EX_SCAN_SAST`（21） |
| `warning` | 印出來，放行 |
| `note` / `none` | 印出來，放行 |

SARIF 也是 GitHub Code Scanning 吃的格式，同一份輸出兩用。

### `.semgrepignore` 必須在專案根目錄

Semgrep 只在**掃描目標的根目錄**找 `.semgrepignore`。
放在 `env/docker/security/` 底下完全不會被讀到，而且**不會有任何警告** ——
你只會看到掃描時間變長、finding 變多，然後以為那是正常的。

---

## 4. ③ SCA

三個來源：

| 工具 | 掃什麼 |
|---|---|
| Trivy | 檔案系統 + 映像（OS 套件 + 語言相依） |
| `composer audit` | PHP 相依的已知漏洞 |
| `npm audit` | Node 相依的已知漏洞 |

**不要用 `--ignore-platform-reqs` 或 `-W` 硬過相依衝突。**
`cx composer` 會主動拒絕：

```
✘ 拒絕 --ignore-platform-reqs —— 正確診斷是 composer why-not <套件> <版本>
```

理由：那兩個旗標的作用是「假裝相依有解」，於是問題從 build time
移到 runtime，而 runtime 的症狀是 `Call to undefined method`，
跟相依衝突看起來毫無關係。

---

## 5. ④ DAST（OWASP ZAP）

### 跑兩次

```
DetectionOnly  →  WAF 只記錄不阻擋  →  看應用本身有多少問題
On             →  WAF 真的阻擋      →  看 WAF 擋掉了哪些
```

兩份報告的差集就是「WAF 現在幫你擋著、但應用本身還沒修」的清單。
只跑後者會讓 WAF 變成遮羞布：應用的漏洞還在，但掃描是綠的。

### 退出碼映射

ZAP baseline 的退出碼**不是**「0 成功 / 非 0 失敗」：

| ZAP rc | 意義 | cx 的處置 |
|---|---|---|
| 0 | 沒有任何 alert | 通過 |
| 1 | 至少一個 FAIL | `EX_SCAN_DAST`（23） |
| 2 | **只有 WARN** | **通過**（印出警告數） |
| ≥3 | 工具本身出錯（目標連不上、設定壞掉） | `EX_FAIL`，不是掃描失敗 |

把 2 當失敗 → 每次掃描都紅，三天後沒人看。
把 ≥3 當成功 → 「ZAP 根本沒跑起來」被記成「沒有漏洞」。

### 先探測目標

`_scan_dast_probe` 在正式掃描前先確認目標會回應。
沒有這一步的話，目標沒起來時 ZAP 會掃出一份「零個 alert」的漂亮報告。

### baseline.conf 的掛載位置

掛在 `/zap/pmconf/`，**不是** `/zap/wrk/`。
`/zap/wrk/` 是輸出目錄，ZAP 會往裡面寫，把唯讀設定放進去會在某些版本被覆寫。

---

## 6. 祕密掃描

### `cx scan secrets`

gitleaks，掃**全部歷史**而不只是工作區。
祕密一旦進過任何一個 commit 就等於外洩 —— 刪掉檔案再 commit 沒有用。

### `cx git push` 的兩層

推送前會再掃一次，兩層：

| 層 | 掃什麼 |
|---|---|
| 檔名層 | `.env`、`*.pem`、`id_rsa`、`*.p12`、`.vault_pass`… |
| 內容層 | AWS key、私鑰 PEM header、`APP_KEY=base64:`、高熵字串 |

內容層對每個 repo 都會先 `cd` 進去再掃。早期版本沒有這個 `cd`，
於是兩個子模組實際上**掃了零個檔案** —— 而輸出看起來完全正常
（「掃描完成，未發現問題」）。修好之後用植入的假憑證驗證過，會被抓到。

---

## 7. 第五道：WAF

ModSecurity + OWASP CRS，只在 test 模式的 `waf` 服務裡。

排除規則走官方擴充點：

```
/opt/owasp-crs/plugins/pm-before.conf     # CRS 規則之前
/opt/owasp-crs/plugins/pm-after.conf      # CRS 規則之後
```

直接改 CRS 自己的檔案會在下次拉映像時被覆蓋。

自訂的 nginx 設定要掛成 **template**：

```yaml
- ./env/docker/waf/proxy_backend.conf:/etc/nginx/templates/includes/proxy_backend.conf:ro
```

掛進 `/etc/nginx/includes/` 會跳過 envsubst，設定裡的變數不會被展開。

`waf_rule_engine` 變數控制 `DetectionOnly` / `On`。

---

## 8. 應用層的四道防線

掃描是外部的，應用內部也有對應的防護：

| | 做法 | 檔案 |
|---|---|---|
| 信任的代理 | `trustProxies(at: [私有網段])` | `src/backend/bootstrap/app.php` |
| 訪客導向 | API / JSON 請求回 401 而不是重導到 `/login` | 同上 |
| 測試隔離 | `phpunit.xml` 每個 `<env>` 都有 `force="true"` | `src/backend/phpunit.xml` |
| 型別檢查 | `vue-tsc` + `tsconfig.json` extends `.nuxt/tsconfig.json` | `frontend/` |

### `trustProxies` 為什麼要限制網段

不設定的話 Laravel 不信任任何 `X-Forwarded-*`，於是 `url()` 產生的網址
都是容器內部的 `http://app:8080`。設成 `at: '*'` 則是另一個極端 ——
任何人都能用 `X-Forwarded-Host` 偽造密碼重設信裡的網址。
限制在私有網段是唯一正確的選擇。

### `phpunit.xml` 的 `force="true"`

沒有 `force="true"` 時，`<env>` 只在該環境變數**尚未存在**時才生效。
CI 或 shell 裡只要有一個同名變數（例如 `DB_DATABASE`），
測試就會安靜地打到那個資料庫 —— 而且測試會通過，直到某一次它清空了正式資料。

`cx test back` 另外再傳一次 `-e DB_CONNECTION=sqlite -e DB_DATABASE=:memory:`，
是第二道保險。

---

## 9. CI 建議

```bash
set -e
cx doctor                # 環境
cx scan secrets          # 最快，先擋
cx scan code             # 靜態
cx scan sast
cx scan sca
cx test all              # 單元 + 型別
cx test up -d --build    # 起環境
cx verify runtime app    # 端點
cx scan dast             # 最慢，放最後
cx test down -v
```

`cx scan all` 已經把前四項加上 secrets 串起來（全部跑完，回傳最嚴重的碼）。
分開寫的好處是 CI 上每一步各自一個 job，看得出是哪一道防線紅的。
