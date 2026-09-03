#!/usr/bin/env python3
"""列出合併後 compose 設定裡「位於專案內」的 bind mount 來源（相對 CX_ROOT）。

為什麼要用 `docker compose config --format json` 而不是 grep yaml：
base 與 overlay 合併後的結果才是 Docker 真正會用的東西，而 compose 的
volumes 合併規則（以容器內 target 為鍵）並不是單純的字串疊加。

為什麼需要這支程式：bind mount 來源不存在時，Docker 不會報錯，它會
「靜默建立一個 root:root 0755 的空目錄」再掛上去。於是 CRS 排除規則
從未載入、WAF 悄悄失效，而且沒有任何線索。
"""
import json
import os
import sys


def main() -> int:
    root = os.environ.get("CX_ROOT", "")
    if not root:
        print("compose_mounts: 需要 CX_ROOT", file=sys.stderr)
        return 2
    try:
        doc = json.load(sys.stdin)
    except Exception:
        # config 失敗（例如缺 env 變數）時交由呼叫者的 config --quiet 報錯，
        # 這裡不要再吵一次，也不要假裝「沒有任何 mount」是錯誤。
        return 0

    prefix = root.rstrip("/") + "/"
    found = set()
    for svc in (doc.get("services") or {}).values():
        for vol in (svc.get("volumes") or []):
            if vol.get("type") != "bind":
                continue
            src = vol.get("source") or ""
            if not src.startswith(prefix):
                continue
            found.add(os.path.relpath(src, root))

    for path in sorted(found):
        print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
