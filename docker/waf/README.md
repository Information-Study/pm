# docker/waf/ — ModSecurity + OWASP CRS

只有 **test 模式**有 WAF service。它是 test 模式的對外入口：

```
ZAP → waf:8080 (ModSecurity + CRS) → edge:8080 → app:8080 / nuxt:3000
```

## 為什麼有兩個排除規則檔

`owasp/modsecurity-crs:nginx-alpine` 的 `setup.conf` 載入順序是：

```
modsecurity.conf
crs-setup.conf
plugins/*-config.conf
plugins/*-before.conf          ← exclusions-before 掛在這裡
rules/*.conf                   ← CRS 本體
plugins/*-after.conf
modsecurity-override.conf      ← exclusions-after 掛在這裡
```

| 檔 | 掛載到 | 放什麼 | 為什麼必須在這一側 |
|---|---|---|---|
| `exclusions-before/pm-exclusions-before.conf` | `plugins/pm-exclusions-before.conf` | `ctl:ruleRemoveById` | `ctl:` 只影響「同 phase 中尚未執行」的規則。載在 CRS 之後等於沒寫 |
| `exclusions-after/pm-exclusions-after.conf` | `modsecurity-override.conf` | `SecRuleUpdateTargetById` | 那是**載入期**指令，要修改的規則必須已經被 Include 進來 |

## 三個會讓 nginx 起不來的寫法

1. **多個 `ctl:` 之間用分號。** 必須是逗號。分號會讓 ModSecurity 拒絕載入整份設定，
   錯誤只說 `Rules error`，看不出是哪個字元。
2. **`SecRuleUpdateTargetById` 引用不存在的規則 ID。** 載入期就報錯。
   所以 `exclusions-after` 預設是空的 —— 先用 DetectionOnly 收 audit log，
   確認真正誤判的 ID 之後再填。
3. **phase 用錯。** 920xxx 是 phase 1，941/942xxx 是 phase 2。
   用 phase:2 的規則去移除 920273 完全無效。

## audit log 從哪裡取

`SecAuditLogType Serial` 預設**只寫 stdout**。給 `MODSEC_AUDIT_STORAGE_DIR`
掛一顆 volume 的話那顆 volume 會是空的，WAF↔ZAP 對照完全沒有素材。

```bash
cx --mode test logs waf | grep '^{' > reports/waf/audit.jsonl
```

`docker/compose/test.yml` 已經把 `MODSEC_AUDIT_LOG=/dev/stdout` 與
`MODSEC_AUDIT_LOG_FORMAT=JSON` 設好。

## 與 Ansible 的關係

`ansible/roles/nginx_myguard` 用同一組規則（`waf_exclusions_before` 的 10010–10014）。
Docker 與原生部署刻意保持相同的 WAF 行為，**改一邊就要改另一邊**。
