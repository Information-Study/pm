#!/usr/bin/env python3
"""主動量測 ModSecurity + CRS 的實際攔截率。

為什麼需要這支程式：`zap-baseline.py` 是**被動**掃描 —— 它爬站、檢查回應標頭，
不送任何攻擊 payload。拿 DetectionOnly 與 Blocking 兩份 baseline 報告去比對，
兩邊必然完全一樣，結論永遠是「WAF 擋下 0 項」。
那個數字不是「WAF 沒用」，是量錯了東西。

這裡改成真的送請求，並比較兩個引擎模式下的狀態碼：

  攻擊請求   DetectionOnly 應為 2xx/3xx（只記錄）  Blocking 應為 403
  正常請求   兩邊都應該通過

正常請求那一組是對照組，而且比攻擊那組更重要：**正常請求在 Blocking 模式下被擋，
代表排除規則沒生效**（Livewire / Filament 的表單送出會被 941/942 誤判）。
那才是上線之後真正會痛的失敗模式。

探測容器要加進 WAF 所在的 compose 網路，才解析得到 http://waf:8080。
"""
import json
import os
import subprocess
import sys

# (名稱, 路徑, 是否為攻擊)
CASES = [
    ("sqli-or-1-1",      "/?id=1%27%20OR%20%271%27=%271",              True),
    ("sqli-union",       "/?id=1%20UNION%20SELECT%20NULL,NULL--",      True),
    ("xss-script-tag",   "/?q=%3Cscript%3Ealert(1)%3C/script%3E",      True),
    ("xss-img-onerror",  "/?q=%3Cimg%20src=x%20onerror=alert(1)%3E",   True),
    ("traversal-passwd", "/?f=../../../../etc/passwd",                 True),
    ("cmd-injection",    "/?c=%3Bcat%20/etc/passwd",                   True),
    ("normal-root",      "/",                                          False),
    ("normal-health",    "/up",                                        False),
    ("normal-admin",     "/admin/login",                               False),
    ("normal-csrf",      "/sanctum/csrf-cookie",                       False),
]

ENGINES = ["DetectionOnly", "On"]

# 專案名一律從 .cxroot 推導（cx 會 export CX_PROJECT_NAME）。
# 這裡曾經寫死 "pm_test"，於是專案改名之後 compose 專案前綴對不上，
# 探測會打到別的專案的 test 堆疊、或是根本找不到容器。
PROJECT = os.environ.get("CX_PROJECT_NAME") or "pm"


def compose(root, *args):
    base = [
        "docker", "compose",
        "--project-directory", root,
        "-p", f"{PROJECT}_test",
        "-f", os.path.join(root, "docker-compose.yml"),
        "-f", os.path.join(root, "docker/compose/test.yml"),
    ]
    for f in (".env", "docker/env/test.env"):
        p = os.path.join(root, f)
        if os.path.exists(p):
            base += ["--env-file", p]
    return base + list(args)


def set_engine(root, engine):
    """重建 waf 容器並套用新的 MODSEC_RULE_ENGINE，然後等它 healthy。"""
    env = dict(os.environ, MODSEC_RULE_ENGINE=engine)
    subprocess.run(compose(root, "up", "-d", "--wait", "waf"),
                   env=env, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def probe(net, path):
    """從一個一次性容器打 waf:8080，回傳狀態碼。

    用容器而不是 host 的 curl：這樣走的是 compose 網路內部，
    與 ZAP 的路徑完全一致（host 那條路要經過發布的埠，中間多一層 NAT）。
    """
    out = subprocess.run(
        ["docker", "run", "--rm", "--network", net,
         "curlimages/curl:8.11.1",
         "-s", "-o", "/dev/null", "-m", "20", "-w", "%{http_code}",
         f"http://waf:8080{path}"],
        capture_output=True, text=True)
    return (out.stdout or "000").strip()


def main() -> int:
    root = os.environ["CX_ROOT"]
    net = os.environ["CX_NET"]
    out_path = sys.argv[1]

    results = {}
    for engine in ENGINES:
        try:
            set_engine(root, engine)
        except subprocess.CalledProcessError:
            print(f"  無法把 WAF 切到 {engine} —— 略過主動探測", file=sys.stderr)
            return 0
        results[engine] = {name: probe(net, path) for name, path, _ in CASES}

    attacks = [c for c in CASES if c[2]]
    normals = [c for c in CASES if not c[2]]

    blocked = [c[0] for c in attacks if results["On"].get(c[0]) == "403"]
    leaked = [c[0] for c in attacks if results["On"].get(c[0]) != "403"]
    false_positives = [c[0] for c in normals if results["On"].get(c[0]) == "403"]

    rate = (len(blocked) / len(attacks) * 100) if attacks else 0.0
    report = {
        "engines": ENGINES,
        "attack_cases": len(attacks),
        "blocked_in_blocking_mode": blocked,
        "not_blocked": leaked,
        "block_rate_percent": round(rate, 1),
        "normal_requests_falsely_blocked": false_positives,
        "raw": results,
    }
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(report, fh, ensure_ascii=False, indent=2)

    print(f"  攻擊 {len(attacks)} 項 → Blocking 模式擋下 {len(blocked)} 項"
          f"（{rate:.0f}%）", file=sys.stderr)
    if leaked:
        print(f"  ⚠ 未擋下：{', '.join(leaked)}", file=sys.stderr)
    if false_positives:
        # 這比「沒擋到攻擊」更嚴重：代表排除規則沒生效，後台會不能用。
        print(f"  ✘ 正常請求被誤擋：{', '.join(false_positives)}", file=sys.stderr)
        print("    這代表 CRS 排除規則沒生效，檢查 docker/waf/exclusions-before/",
              file=sys.stderr)
    else:
        print("  ✔ 正常請求全部通過（排除規則有效）", file=sys.stderr)
    print(f"  報告：{os.path.relpath(out_path, root)}", file=sys.stderr)

    # 探測本身不決定 lane 的成敗 —— 它是量測，不是閘門。
    return 0


if __name__ == "__main__":
    sys.exit(main())
