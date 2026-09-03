# OWASP ZAP（DAST）

**只能在 Docker 模式執行** —— ZAP 需要 Java runtime，本機沒有。

`cx scan dast` 會跑兩次，比對 WAF 的實際攔截率：

1. `MODSEC_RULE_ENGINE=DetectionOnly` → `reports/dast/detect/`
2. `MODSEC_RULE_ENGINE=On`            → `reports/dast/blocking/`

兩者的 alert 差集就是 ModSecurity CRS 真正擋下來的東西，寫入 `reports/dast/compare/`。

## 已知陷阱

- 容器內以 **uid 1000** 執行，`/zap/wrk` 必須由 cx 事先以呼叫者身分建立，
  否則 Docker 會建成 root:root，ZAP 寫不進去。
- 目標要指向 **WAF 前門**（`http://waf:8080`）而非 app，否則量不到 WAF 效果。
- 掃描容器必須與 waf 在同一個 network，且 network 名稱要在 compose 明寫 `name:`，
  否則會被命名空間化成 `<project>_<key>` 而找不到。
