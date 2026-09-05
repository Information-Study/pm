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
import re
import subprocess
import sys

# 映像版本的單一事實來源是 bin/lib/common.sh；cx 會把它 export 進來。
# 這裡的字面值只是「直接跑這支程式」時的備援，不是第二份宣告。
DEFAULT_CURL_IMAGE = "curlimages/curl:8.11.1"

# 從環境變數進來、之後會被交給 subprocess 的值，一律先驗形狀。
#
# 這裡沒有 shell（subprocess 收的是 argv 列表，不是字串），所以不存在
# shell injection；但「不會被注入」不等於「可以不看」——
# 一個打錯字的 CX_IMG_CURL 會變成 docker 去 registry 拉一個不存在的映像，
# 錯誤訊息完全指不到是環境變數寫錯。驗形狀同時解決這兩件事，
# 也讓 Semgrep 的 dangerous-subprocess-use-tainted-env-args 有明確的收斂點。
_IMAGE_RE = re.compile(
    r"^[a-z0-9]+(?:[._-][a-z0-9]+)*"                 # 第一段（registry 或 namespace）
    r"(?::[0-9]{1,5})?"                              # 選用的 registry port
    r"(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*"            # 其餘路徑段
    r"(?::[A-Za-z0-9][A-Za-z0-9._-]{0,127})?"        # 選用的 tag
    r"(?:@sha256:[a-f0-9]{64})?$"                    # 選用的 digest
)
# docker 網路名：docker 自己只接受 [a-zA-Z0-9][a-zA-Z0-9_.-]*
_NET_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$")


def _checked(value, pattern, what, fallback=None):
    """驗過形狀才交給 subprocess；不合法就用備援值或直接退出。"""
    if value and pattern.match(value):
        return value
    if fallback is not None:
        print(f"  ⚠ {what} 的值不合法（{value!r}）—— 改用 {fallback}", file=sys.stderr)
        return fallback
    print(f"  ✘ {what} 的值不合法：{value!r}", file=sys.stderr)
    raise SystemExit(2)


CURL_IMAGE = _checked(os.environ.get("CX_IMG_CURL"), _IMAGE_RE,
                      "CX_IMG_CURL", DEFAULT_CURL_IMAGE)

# (名稱, 路徑, 是否為攻擊, POST body 或 None)
CASES = [
    ("sqli-or-1-1",      "/?id=1%27%20OR%20%271%27=%271",              True,  None),
    ("sqli-union",       "/?id=1%20UNION%20SELECT%20NULL,NULL--",      True,  None),
    ("xss-script-tag",   "/?q=%3Cscript%3Ealert(1)%3C/script%3E",      True,  None),
    ("xss-img-onerror",  "/?q=%3Cimg%20src=x%20onerror=alert(1)%3E",   True,  None),
    ("traversal-passwd", "/?f=../../../../etc/passwd",                 True,  None),
    ("cmd-injection",    "/?c=%3Bcat%20/etc/passwd",                   True,  None),
    ("normal-root",      "/",                                          False, None),
    ("normal-health",    "/up",                                        False, None),
    ("normal-admin",     "/admin/login",                               False, None),
    ("normal-csrf",      "/sanctum/csrf-cookie",                       False, None),
]

# Filament 後台的每一次互動都是一個 Livewire POST，body 是整個元件狀態的
# JSON 快照 —— 使用者在富文字欄位或表格篩選器裡打的任何東西都在裡面，
# 包含引號、角括號、以及會讓 CRS 941/942 誤判的字串。
#
# 這一項是 2026-09-05 補的，因為在它之前，「正常請求」那一組全是不帶 body 的
# GET，於是 Livewire 排除規則整整壞了一段時間都沒被任何自動檢查發現：
# 排除規則寫的是 @beginsWith /livewire/，而 Livewire v4 的端點前綴由 APP_KEY
# 推導（/livewire-<8 碼 hash>/），一條都比對不到。
# 攻擊全擋 100% 與後台完全不能用，是可以同時成立的。
# 用 json.dumps 組，不要手寫字面量：body 裡同時有單引號、雙引號與角括號
# （那正是它會踩到 CRS 941/942 的原因），手寫轉義只會製造難查的語法錯誤。
LIVEWIRE_BODY = json.dumps({
    "_token": "probe",
    "components": [{
        # 內容要用「排除規則正是為了放行它才存在」的那一種。太溫和的字串
        # 在 PL1 之下不會觸發 CRS，對照組就測不到東西（2026-09-05 實測）。
        # <script> 與 UNION SELECT 各自都會被 941/942 命中，而它們分別是
        # 「富文字欄位貼上 HTML」與「表格篩選器打了一句話」—— 後台的日常操作。
        "snapshot": json.dumps({"data": {
            "bio": "<script>alert(1)</script>",
            "q": "1 UNION SELECT NULL FROM users",
        }}),
        "updates": {},
        "calls": [],
    }],
})

ENGINES = ["DetectionOnly", "On"]

# 引擎探測完要還原成宣告值，否則 cx scan dast 會把 test 堆疊留在 On，
# 而 docker/env/test.env 宣告的是 DetectionOnly —— 下一個人看到的環境
# 與版控裡寫的不一樣，而且沒有任何地方會告訴他。
DEFAULT_ENGINE = "DetectionOnly"

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


def probe(net, path, body=None):
    """從一個一次性容器打 waf:8080，回傳狀態碼。

    用容器而不是 host 的 curl：這樣走的是 compose 網路內部，
    與 ZAP 的路徑完全一致（host 那條路要經過發布的埠，中間多一層 NAT）。
    """
    cmd = ["docker", "run", "--rm", "--network", net,
           CURL_IMAGE,
           "-s", "-o", "/dev/null", "-m", "20", "-w", "%{http_code}"]
    if body is not None:
        cmd += ["-X", "POST",
                "-H", "Content-Type: application/json",
                "-H", "X-Livewire: 1",
                "--data-binary", body]
    cmd.append(f"http://waf:8080{path}")
    # 書面理由（sarif_gate.py 只放行有書面理由的抑制），對應下一行的 nosemgrep：
    #   規則追的是 CX_IMG_CURL / CX_NET 這兩個環境變數流進 subprocess。
    #   三件事讓它在這裡不構成風險，而且不是靠「看起來還好」：
    #   (1) 沒有 shell —— subprocess 收的是 argv 列表，shell=False 是預設值，
    #       所以不存在字串被重新解析的路徑。
    #   (2) 兩個值在模組載入時都過了 _checked()：CX_IMG_CURL 比對 _IMAGE_RE
    #       （小寫、明確的 tag/digest 形狀），不合法就退回釘住的預設值；
    #       CX_NET 比對 _NET_RE（docker 自己接受的字元集），不合法直接 exit 2。
    #       Semgrep 的污點分析看不懂正規表示式當 sanitizer，所以仍會標記。
    #   (3) 這兩個變數由**執行 cx 的人**設定 —— 與能直接跑 docker 的是同一個
    #       身分。能改它們的人本來就能直接下 docker run，沒有提權。
    #
    # ⚠ nosemgrep 必須**緊貼**被標記的那一行（中間不能夾任何東西），
    #   所以理由寫在上面，指令單獨一行放在下面。
    # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-tainted-env-args.dangerous-subprocess-use-tainted-env-args
    out = subprocess.run(cmd, capture_output=True, text=True)
    return (out.stdout or "000").strip()


def livewire_prefix(net):
    """問應用自己要 Livewire 的端點前綴。

    前綴 = '/livewire-' + substr(sha256(APP_KEY . 'livewire-endpoint'), 0, 8)，
    每個部署都不同，所以絕對不能寫死。從後台登入頁的 HTML 裡撈 —— 那正是
    瀏覽器會拿到、也正是真實流量會打的那一個。
    """
    out = subprocess.run(
        ["docker", "run", "--rm", "--network", net,
         CURL_IMAGE, "-s", "-m", "20",
         "http://waf:8080/admin/login"],
        capture_output=True, text=True)
    m = re.search(r"/livewire-[0-9a-zA-Z]+", out.stdout or "")
    return m.group(0) if m else None


def declared_engine(root):
    """docker/env/test.env 宣告的引擎值 —— 探測結束後要還原成這個。"""
    path = os.path.join(root, "docker/env/test.env")
    try:
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if line.startswith("MODSEC_RULE_ENGINE="):
                return line.split("=", 1)[1].strip() or DEFAULT_ENGINE
    except OSError:
        pass
    return DEFAULT_ENGINE


def main() -> int:
    root = os.environ["CX_ROOT"]
    net = _checked(os.environ.get("CX_NET"), _NET_RE, "CX_NET")
    out_path = sys.argv[1]

    cases = list(CASES)
    lw = livewire_prefix(net)
    if lw:
        # 這一項才是「排除規則有沒有生效」的真正判準。
        cases.append(("normal-livewire-post", f"{lw}/update", False, LIVEWIRE_BODY))
        print(f"  Livewire 端點：{lw}/update", file=sys.stderr)
    else:
        print("  ⚠ 抓不到 Livewire 端點前綴 —— 略過該對照項"
              "（/admin/login 沒有回 HTML？）", file=sys.stderr)

    results = {}
    try:
        for engine in ENGINES:
            try:
                set_engine(root, engine)
            except subprocess.CalledProcessError:
                print(f"  無法把 WAF 切到 {engine} —— 略過主動探測", file=sys.stderr)
                return 0
            results[engine] = {
                name: probe(net, path, body) for name, path, _, body in cases
            }
    finally:
        # 一定要還原。少了這一段，cx scan dast 會把 test 堆疊留在最後一個
        # 引擎值（On）上，而版控裡宣告的是 DetectionOnly ——
        # 下一個人拿到的環境與 docker/env/test.env 說的不一樣，
        # 而且沒有任何地方會提醒他。實測確認過這個漂移真的會發生。
        want = declared_engine(root)
        try:
            set_engine(root, want)
            print(f"  WAF 引擎已還原為宣告值 {want}", file=sys.stderr)
        except subprocess.CalledProcessError:
            print(f"  ⚠ 無法把 WAF 還原成 {want} —— 請手動 cx test up -d waf",
                  file=sys.stderr)

    attacks = [c for c in cases if c[2]]
    normals = [c for c in cases if not c[2]]

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
