#!/usr/bin/env python3
"""判定 SARIF 報告是否應該讓掃描 lane 失敗，並印出人看得懂的摘要。

閘門定義來自 claude.md §5：SAST 的通過條件是「無 ERROR 等級 finding」。
Semgrep 的 --error 旗標做不到這件事 —— 它對「任何 finding」都回 exit 1，
包含 warning。用它當閘門的結果是 lane 永遠紅燈，於是沒有人會再看它。

被 # nosemgrep 抑制的項目在 SARIF 裡帶 suppressions，這裡一律不計入閘門，
但仍會計數，因為「抑制了幾條」本身是需要被看見的資訊。

退出碼：0 = 沒有 ERROR；1 = 有 ERROR。
"""
import json
import sys
from collections import Counter


def main() -> int:
    path = sys.argv[1]
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except Exception as exc:
        print(f"無法讀取 SARIF：{exc}", file=sys.stderr)
        return 1

    active = Counter()
    suppressed = Counter()
    error_rows = []

    for run in doc.get("runs", []):
        rules = {r["id"]: r for r in run.get("tool", {}).get("driver", {}).get("rules", [])}
        for res in run.get("results", []):
            rid = res.get("ruleId", "?")
            short = rid.split(".")[-1]
            level = (rules.get(rid, {})
                     .get("defaultConfiguration", {})
                     .get("level", "warning"))
            if res.get("suppressions"):
                suppressed[short] += 1
                continue
            active[(level, short)] += 1
            if level == "error":
                loc = (res.get("locations") or [{}])[0].get("physicalLocation", {})
                error_rows.append(
                    f"{loc.get('artifactLocation', {}).get('uri', '?')}"
                    f":{loc.get('region', {}).get('startLine', '?')}  {short}")

    n_err = sum(v for (lvl, _), v in active.items() if lvl == "error")
    n_warn = sum(v for (lvl, _), v in active.items() if lvl != "error")

    print(f"  ERROR {n_err} ・ WARNING {n_warn} ・ 已抑制 {sum(suppressed.values())}",
          file=sys.stderr)
    for (lvl, name), n in sorted(active.items(), key=lambda kv: (-kv[1], kv[0][1])):
        print(f"    [{lvl:7}] {n:3}  {name}", file=sys.stderr)
    if suppressed:
        print("  已抑制（有書面理由，見對應檔案的 nosemgrep 註解）：", file=sys.stderr)
        for name, n in suppressed.most_common():
            print(f"    {n:3}  {name}", file=sys.stderr)

    if error_rows:
        print("  ERROR 等級的位置：", file=sys.stderr)
        for row in error_rows[:30]:
            print(f"    {row}", file=sys.stderr)

    return 1 if n_err else 0


if __name__ == "__main__":
    sys.exit(main())
