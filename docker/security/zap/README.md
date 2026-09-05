# OWASP ZAP（DAST）

**只能在 Docker 模式執行** —— ZAP 需要 Java runtime，本機沒有。

`cx scan dast` 會跑兩次 baseline，每次之前先把 waf 容器重建成對應的引擎模式：

1. `MODSEC_RULE_ENGINE=DetectionOnly` → `reports/dast/detect/`
2. `MODSEC_RULE_ENGINE=On`            → `reports/dast/blocking/`

跑完會**還原成 `docker/env/test.env` 宣告的值**，不會把 test 堆疊留在 On。

> ⚠ 兩份 baseline 的 alert 差集**不是** WAF 攔截率。
> `zap-baseline.py` 是被動掃描：它爬站、檢查回應標頭，不送攻擊 payload，
> 所以兩個引擎模式下看到的 alert 幾乎必然相同，相減永遠得到「擋下 0 項」。
> 那個數字不是「WAF 沒用」，是量錯了東西。
>
> 攔截率由 `bin/lib/waf_probe.py` 的**主動探測**量，寫進
> `reports/dast/compare/waf-probe.json`。它送一組已知會命中 CRS 的 payload，
> 外加一組正常請求當對照組 —— 其中包含一個**真實的 Livewire POST**
> （端點前綴由 APP_KEY 推導，探測時現場從 `/admin/login` 的 HTML 撈）。
> 那一項才是「排除規則有沒有生效」的判準：攻擊全擋 100% 與後台完全不能用，
> 是可以同時成立的，2026-09-05 之前就是這個狀態。
>
> `reports/dast/compare/waf-effectiveness.json` 是被動 alert 的差異，
> 保留它是因為「Blocking 模式下多出來的 alert」仍然有意義，但它不叫攔截率。

## 已知陷阱

- 容器內以 **uid 1000** 執行，`/zap/wrk` 必須由 cx 事先以呼叫者身分建立，
  否則 Docker 會建成 root:root，ZAP 寫不進去。
- 目標要指向 **WAF 前門**（`http://waf:8080`）而非 app，否則量不到 WAF 效果。
- 掃描容器必須與 waf 在同一個 network，且 network 名稱要在 compose 明寫 `name:`，
  否則會被命名空間化成 `<project>_<key>` 而找不到。
