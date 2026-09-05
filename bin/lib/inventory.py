#!/usr/bin/env python3
"""ansible/inventory/hosts.yml 的產生、修改與檢查。

為什麼要有這支程式：`cx deploy` 的每一個動詞都需要 hosts.yml，而它是唯一
一個**沒有任何工具幫忙產生**的必要檔案 —— 從選單走到部署那一步會撞牆，
訊息只說「缺少 ansible/inventory/hosts.yml」，然後叫人離開 cx 自己 cp 範例檔。

為什麼用 Python 而不是在 bash 裡改 YAML：巢狀結構加上「同一台主機要同時
出現在環境群組、web、db_primary 三個地方」，用 sed/awk 改是找死。

⚠ 這支程式是**重新產生**整個檔案，不是就地修補。
   所以使用者手寫的註解會消失（結構與值都會保留）。
   換來的是產出一定是合法且一致的 —— 三個群組不會對不起來。
   要手寫就用 `cx deploy hosts edit`，那條路徑不會經過這裡。

群組模型（來源：ansible/site.yml 的 roles 區塊）：
    <專案>_servers  site.yml 的作用對象，所有主機都要在裡面（common / hardening）
    web          php-fpm / nginx / node+PM2 / deploy_* / healthcheck
    db_primary   MySQL，而且由它執行 artisan migrate。**剛好一台**，
                 而且必須同時是 web 成員（A15：migration 掛在 web 的 gate 上，
                 db_primary 不在 web 就永遠不會跑）
"""
import argparse
import json
import os
import re
import subprocess
import sys

try:
    import yaml
except ImportError:                                  # pragma: no cover
    print("需要 PyYAML：pip install --user pyyaml", file=sys.stderr)
    sys.exit(3)

# site.yml 的作用群組名。cx 會 export CX_PROJECT_NAME（見 cx 的 export 那一行：
# bin/lib/*.py 是子行程，看不到只被 source 的變數）。
#
# ⚠ 這裡原本寫死 "pm_servers"，而 cx rename 的改名清單裡**沒有這個檔**
#   （rename.sh 改的是 .cxroot / .env / sonar-project.properties /
#     group_vars/all/main.yml / ansible/site.yml / bin/cmd/deploy.sh）。
#   後果很具體：cx rename shop 之後 site.yml 與 deploy.sh 都變成 shop_servers，
#   但 cx deploy hosts init/add 產生的 hosts.yml 群組仍叫 pm_servers →
#   ansible 比對到 0 台主機，而它對「比對不到任何主機」只印 warning 並回 0。
#   也就是 cx deploy ping / check / apply 全部靜默地什麼都不做卻回報成功。
#   守著這件事的 TPL-group 檢查只比對 site.yml 與 deploy.sh，看不到這個檔。
PROJECT = os.environ.get("CX_PROJECT_NAME", "").strip() or "pm"
SERVERS_GROUP = f"{PROJECT}_servers"

ENVS = ("staging", "production")
# 主機名會變成 ansible 的 inventory_hostname，也會被拼進路徑與 systemd unit 名。
HOSTNAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,62}$")


# ── 讀 ───────────────────────────────────────────────────────────────────────
def load(path):
    """把 hosts.yml 讀成 [{name, ip, user, port, key, db}] + env 名稱。"""
    if not os.path.exists(path):
        return None, []
    with open(path, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh) or {}
    children = ((doc.get("all") or {}).get("children") or {})
    env = next((e for e in ENVS if e in children), None)
    dbp = set(((children.get("db_primary") or {}).get("hosts") or {}) or {})
    # web_frontend / web_backend 是 2026-09-06 才有的。舊檔只有一個 web ——
    # 那時前後端一定同機，所以「只有 web」讀作「兩邊都是」。
    #
    # ⚠ 向後相容是硬需求，不是禮貌：hosts.yml **不進版控**，沒有 diff 會提醒，
    #   也沒有還原點。一個讀不懂舊檔的 load() 會把使用者的主機清單靜默改形狀。
    fe = set(((children.get("web_frontend") or {}).get("hosts") or {}) or {})
    be = set(((children.get("web_backend") or {}).get("hosts") or {}) or {})
    web = set(((children.get("web") or {}).get("hosts") or {}) or {})
    if not fe and not be:
        fe = be = set(web)

    # ⚠ 每台主機要記住**自己**屬於哪個環境群組。
    #   原本只用 next() 取一個 env，然後 render() 把所有主機寫進那一個群組 ——
    #   於是一個同時有 staging 與 production 的檔案，只要跑一次 add/rm，
    #   production 群組就會整個消失、它的主機被搬進 staging，
    #   而 <專案>_servers 也跟著少一個 child。hosts.yml 不進版控，沒有 diff 會提醒，
    #   也沒有還原點。（2026-09-05 實測重現。）
    hosts = []
    for env_name in ENVS:
        grp = children.get(env_name) or {}
        for name, v in (grp.get("hosts") or {}).items():
            v = v or {}
            hosts.append({
                "name": name,
                "env": env_name,
                "ip": v.get("ansible_host", ""),
                "user": v.get("ansible_user", ""),
                "port": v.get("ansible_port"),
                "key": v.get("ansible_ssh_private_key_file"),
                "fe": name in fe,
                "be": name in be,
                "db": name in dbp,
            })
    return env, hosts


# ── 寫 ───────────────────────────────────────────────────────────────────────
def render(env, hosts):
    """產生帶說明的 hosts.yml 內容。"""
    L = []
    add = L.append
    add("---")
    add("# 由 `cx deploy hosts` 產生。要手寫請用 `cx deploy hosts edit`——")
    add("# 再跑一次 add/rm 會重新產生這個檔，手寫的註解會不見（結構與值會保留）。")
    add("#")
    add("# 群組的意義（來源：ansible/site.yml 的 roles 區塊）：")
    add(f"#   {SERVERS_GROUP}  site.yml 的作用對象，所有主機都要在裡面")
    add("#   web_frontend  node+PM2 / deploy_frontend")
    add("#   web_backend   php-fpm / composer / deploy_backend（migration 在這裡）")
    add("#   web           上面兩者的 children 聯集。nginx / certbot / healthcheck 對它跑")
    add("#   db_primary    MySQL + artisan migrate。剛好一台，且必須也在 web_backend 裡")
    add("#")
    add("# 單機拓撲：同一台同時在 web_frontend、web_backend、db_primary 裡（預設）。")
    add("# 要拆機請先看 docs/guide-deployer.md §3.3 —— php_fpm_listen 要改成 TCP，")
    add("# 而 FPM 沒有認證機制，allowed_clients 與防火牆都要跟著設。")
    add("#")
    add("# ⚠ 一個 inventory 檔 = 一個環境。兩個環境寫進同一個檔會讓 db_primary")
    add("#   變成兩台而被 preflight 擋下（--limit 不會讓 groups 變小）。")
    add("")
    # 出現過的環境群組全部保留，主機各自回到自己的群組。
    present = [e for e in ENVS if any(h.get("env", env) == e for h in hosts)] or [env]
    add("all:")
    add("  children:")
    for e in present:
        add("")
        add(f"    {e}:")
        add("      hosts:")
        for h in hosts:
            if h.get("env", env) != e:
                continue
            add(f"        {h['name']}:")
            add(f"          ansible_host: {h['ip']}")
            if h.get("user"):
                add(f"          ansible_user: {h['user']}")
            if h.get("port"):
                add(f"          ansible_port: {h['port']}")
            if h.get("key"):
                add(f"          ansible_ssh_private_key_file: {h['key']}")
    add("")
    add(f"    {SERVERS_GROUP}:")
    add("      children:")
    for e in present:
        add(f"        {e}: {{}}")
    add("")
    add("    web_frontend:")
    add("      hosts:")
    for h in hosts:
        if h.get("fe"):
            add(f"        {h['name']}: {{}}")
    add("")
    add("    web_backend:")
    add("      hosts:")
    for h in hosts:
        if h.get("be"):
            add(f"        {h['name']}: {{}}")
    add("")
    # ⚠ web 用 children 而不是 hosts。這是整個拆分能成立的關鍵：
    #   site.yml 裡所有既有的 groups['web'] gate（nginx / certbot / healthcheck）
    #   完全不用改，單機拓撲（一台同時在兩個群組）的行為 100% 不變。
    add("    # 兩者的聯集。nginx / certbot / healthcheck 對它跑 —— 不要手動加 hosts。")
    add("    web:")
    add("      children:")
    add("        web_frontend: {}")
    add("        web_backend: {}")
    add("")
    add("    # 剛好一台，而且必須也是 web_backend 成員（A15：migration 在 deploy_backend 內）")
    add("    db_primary:")
    add("      hosts:")
    for h in hosts:
        if h.get("db"):
            add(f"        {h['name']}: {{}}")
    add("")
    return "\n".join(L)


def save(path, env, hosts):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(render(env, hosts))


# ── 檢查 ─────────────────────────────────────────────────────────────────────
def problems(env, hosts):
    """回傳 [(嚴重度, 訊息)]；嚴重度 'E' 會讓 check 失敗，'W' 只提醒。"""
    out = []
    if not env:
        out.append(("E", "沒有任何環境群組（staging / production）"))
    if not hosts:
        out.append(("E", "一台主機都沒有 —— 跑 cx deploy hosts add <名稱> --ip <IP>"))
        return out

    seen = set()
    for h in hosts:
        n = h["name"]
        if not HOSTNAME_RE.match(n):
            out.append(("E", f"主機名不合法：{n}（小寫英數開頭，只能有 . _ -）"))
        if n in seen:
            out.append(("E", f"主機名重複：{n}"))
        seen.add(n)
        if not h["ip"]:
            out.append(("E", f"{n} 沒有 ansible_host（IP 或 DNS 名稱）"))
        if not h["user"]:
            out.append(("W", f"{n} 沒有 ansible_user —— 會用你目前的登入帳號"))
        if h.get("key") and not os.path.exists(os.path.expanduser(str(h["key"]))):
            out.append(("W", f"{n} 的私鑰不存在：{h['key']}"))

    envs_used = sorted({h.get("env") for h in hosts if h.get("env")})
    if len(envs_used) > 1:
        out.append(("E", f"同一個檔案裡有 {len(envs_used)} 個環境群組（{', '.join(envs_used)}）—— "
                         "preflight 會因為 db_primary 超過一台而擋下。一個 inventory 檔 = 一個環境，"
                         "請拆成 inventory/staging.yml 與 inventory/production.yml"))

    fe  = [h["name"] for h in hosts if h.get("fe")]
    be  = [h["name"] for h in hosts if h.get("be")]
    dbp = [h["name"] for h in hosts if h.get("db")]
    web = sorted(set(fe) | set(be))

    if not be:
        out.append(("E", "web_backend 是空的 —— 不會有任何機器跑 php-fpm、"
                         "也不會有人執行 migration"))
    if not fe:
        out.append(("E", "web_frontend 是空的 —— 不會有任何機器跑 Node/PM2。"
                         "（frontend_mode=static 也一樣需要一台來 nuxt generate）"))
    if len(dbp) == 0:
        out.append(("E", "db_primary 是空的 —— migration 永遠不會執行"))
    elif len(dbp) > 1:
        out.append(("E", f"db_primary 有 {len(dbp)} 台（{', '.join(dbp)}）—— 必須剛好一台。"
                         " migration 用 groups['db_primary'] 當 gate，對象必須唯一"))
    for d in dbp:
        if d not in be:
            out.append(("E", f"{d} 是 db_primary 但不在 web_backend —— deploy_backend 不會在"
                             "它上面跑，migration 一次都不會執行，而且**不會有任何錯誤訊息**"
                             "（site.yml 的 A15 斷言會在連線前擋下）"))

    # ── 真的分機時，兩個預設值會讓那個拓撲直接不會動 ──────────────────
    # 這兩條是 W 不是 E：檢查看不到 group_vars，所以它只能提醒，不能斷定。
    # 但不提醒的話，症狀會是「部署全綠、網站 502」，而原因在兩個沒人動過的預設值上。
    if fe and be and not (set(fe) & set(be)):
        out.append(("W", "web_frontend 與 web_backend 沒有交集（真的分機）。"
                         "兩個預設值會讓這個拓撲不會動："))
        out.append(("W", "  php_fpm_listen 預設是 unix socket —— nginx 在 A 機，"
                         "socket 在 B 機，連不到。要改成 TCP 並填 php_fpm_allowed_clients"
                         "（FPM 沒有認證機制，空清單等於對整個網路開放）"))
        out.append(("W", "  frontend_host 預設是 127.0.0.1 —— Nitro 綁在 loopback，"
                         "別台的 nginx 連不到。要改成內網位址"))
        out.append(("W", "  另外還要放行防火牆（hardening_ufw_allowed_tcp_ports）。"
                         "完整清單見 docs/guide-deployer.md §3.3"))

    if len(web) > 1:
        out.append(("W", f"web 有 {len(web)} 台。多台要另外處理：mysql_bind_address 改內網位址、"
                         "db_host 指過去、mysql_app_user_hosts 加上各台內網 IP、"
                         "並建議 deploy_serial: 1。見 hosts.yml.example 檔尾"))
    return out


# ── 子指令 ───────────────────────────────────────────────────────────────────
def cmd_show(args):
    env, hosts = load(args.path)
    if env is None and not hosts:
        print(f"沒有 {args.path} —— 跑 cx deploy hosts init", file=sys.stderr)
        return 3
    print(f"環境群組：{env}")
    print(f"{'主機':<22}{'位址':<24}{'帳號':<12}{'埠':<7}前端 後端 db_primary")
    print("-" * 78)
    for h in hosts:
        print(f"{h['name']:<22}{str(h['ip']):<24}{str(h['user'] or '-'):<12}"
              f"{str(h['port'] or 22):<7}{'✔' if h.get('fe') else ' ':<5}"
              f"{'✔' if h.get('be') else ' ':<5}"
              f"{'✔' if h.get('db') else ''}")
    print()
    for sev, msg in problems(env, hosts):
        print(f"  {'✘' if sev == 'E' else '⚠'} {msg}", file=sys.stderr)
    return 0


def cmd_check(args):
    env, hosts = load(args.path)
    if env is None and not hosts:
        print(f"沒有 {args.path}", file=sys.stderr)
        return 3
    errs = 0
    for sev, msg in problems(env, hosts):
        print(f"  {'✘' if sev == 'E' else '⚠'} {msg}", file=sys.stderr)
        errs += (sev == "E")
    # 再讓 ansible 自己剖析一次 —— 我們的模型對了不代表 ansible 讀得懂
    if args.ansible:
        r = subprocess.run(["ansible-inventory", "-i", args.path, "--list"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print("  ✘ ansible-inventory 剖析失敗：", file=sys.stderr)
            print("    " + (r.stderr.strip().splitlines() or ["（無訊息）"])[-1], file=sys.stderr)
            errs += 1
        else:
            try:
                data = json.loads(r.stdout)
                n = len((data.get("_meta", {}).get("hostvars") or {}))
                print(f"  ✔ ansible-inventory 剖析通過（{n} 台主機）", file=sys.stderr)
            except ValueError:
                print("  ⚠ ansible-inventory 的輸出不是 JSON", file=sys.stderr)
    return 1 if errs else 0


def cmd_add(args):
    env, hosts = load(args.path)
    # --env 只決定**這一台新主機**要放進哪個群組；既有主機留在原本的群組。
    # 原本是 `env = args.env or env or "staging"` 再讓 render 把所有主機
    # 寫進那一個 env —— `--env production` 會把既有的 staging 主機整批搬走。
    new_env = args.env or env or "staging"
    env = env or new_env
    if not HOSTNAME_RE.match(args.name):
        print(f"主機名不合法：{args.name}", file=sys.stderr)
        return 2
    if any(h["name"] == args.name for h in hosts):
        print(f"已經有這台主機：{args.name}（要改就先 rm）", file=sys.stderr)
        return 2
    # 第一台預設同時跑前端、後端與資料庫（單機拓撲，與 hosts.yml.example 一致）。
    # 之後加的預設跑前後端但不是 db_primary（那個必須剛好一台）。
    first = not hosts
    # --web / --no-web 是「兩邊一起」的捷徑。明確的 --fe / --be 優先 ——
    # `--web --no-be` 讀作「這台在 web 裡，但只跑前端」，那是合理的組合。
    fe = args.fe if args.fe is not None else args.web
    be = args.be if args.be is not None else args.web
    hosts.append({
        "name": args.name, "env": new_env, "ip": args.ip, "user": args.user,
        "port": args.port, "key": args.key,
        "fe": True if fe is None else fe,
        "be": True if be is None else be,
        "db": (first if args.db is None else args.db),
    })
    save(args.path, env, hosts)
    print(f"已加入 {args.name}（{args.ip}）到 {env}", file=sys.stderr)
    return cmd_check(args)


def cmd_rm(args):
    env, hosts = load(args.path)
    if env is None and not hosts:
        print(f"沒有 {args.path}", file=sys.stderr)
        return 3
    keep = [h for h in hosts if h["name"] != args.name]
    if len(keep) == len(hosts):
        print(f"找不到主機：{args.name}", file=sys.stderr)
        return 2
    save(args.path, env, keep)
    print(f"已移除 {args.name}", file=sys.stderr)
    return cmd_check(args)


def cmd_init(args):
    if os.path.exists(args.path) and not args.force:
        print(f"{args.path} 已經存在（要重來請加 --force）", file=sys.stderr)
        return 2
    save(args.path, args.env or "staging", [])
    print(f"已建立 {args.path}（還沒有任何主機）", file=sys.stderr)
    print("  下一步： cx deploy hosts add <名稱> --ip <IP> --user <帳號>", file=sys.stderr)
    return 0


def main():
    ap = argparse.ArgumentParser(prog="inventory.py")
    ap.add_argument("--path", required=True)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("init"); p.add_argument("--env", choices=ENVS)
    p.add_argument("--force", action="store_true"); p.set_defaults(fn=cmd_init, ansible=False)

    p = sub.add_parser("show"); p.set_defaults(fn=cmd_show, ansible=False)

    p = sub.add_parser("check"); p.add_argument("--ansible", action="store_true")
    p.set_defaults(fn=cmd_check)

    p = sub.add_parser("add")
    p.add_argument("name"); p.add_argument("--ip", required=True)
    p.add_argument("--user"); p.add_argument("--port", type=int); p.add_argument("--key")
    p.add_argument("--env", choices=ENVS)
    # --web / --no-web 保留為「兩邊一起」的捷徑：舊的指令列與文件仍然可用，
    # 而拆機是少數情況，不該讓多數人多打兩個旗標。
    p.add_argument("--fe", dest="fe", action="store_true", default=None)
    p.add_argument("--no-fe", dest="fe", action="store_false")
    p.add_argument("--be", dest="be", action="store_true", default=None)
    p.add_argument("--no-be", dest="be", action="store_false")
    p.add_argument("--web", dest="web", action="store_true", default=None)
    p.add_argument("--no-web", dest="web", action="store_false")
    p.add_argument("--db", dest="db", action="store_true", default=None)
    p.add_argument("--no-db", dest="db", action="store_false")
    p.set_defaults(fn=cmd_add, ansible=False)

    p = sub.add_parser("rm"); p.add_argument("name"); p.set_defaults(fn=cmd_rm, ansible=False)

    args = ap.parse_args()
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
