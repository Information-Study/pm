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
    pm_servers   site.yml 的作用對象，所有主機都要在裡面（common / hardening）
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
    web = set(((children.get("web") or {}).get("hosts") or {}) or {})
    dbp = set(((children.get("db_primary") or {}).get("hosts") or {}) or {})

    # ⚠ 每台主機要記住**自己**屬於哪個環境群組。
    #   原本只用 next() 取一個 env，然後 render() 把所有主機寫進那一個群組 ——
    #   於是一個同時有 staging 與 production 的檔案，只要跑一次 add/rm，
    #   production 群組就會整個消失、它的主機被搬進 staging，
    #   而 pm_servers 也跟著少一個 child。hosts.yml 不進版控，沒有 diff 會提醒，
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
                "web": name in web,
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
    add("#   pm_servers  site.yml 的作用對象，所有主機都要在裡面")
    add("#   web         php-fpm / nginx / node+PM2 / deploy_* / healthcheck")
    add("#   db_primary  MySQL + artisan migrate。剛好一台，且必須也在 web 裡")
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
    add("    pm_servers:")
    add("      children:")
    for e in present:
        add(f"        {e}: {{}}")
    add("")
    add("    web:")
    add("      hosts:")
    for h in hosts:
        if h.get("web"):
            add(f"        {h['name']}: {{}}")
    add("")
    add("    # 剛好一台，而且必須也是 web 成員（A15）")
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

    web = [h["name"] for h in hosts if h.get("web")]
    dbp = [h["name"] for h in hosts if h.get("db")]
    if not web:
        out.append(("E", "web 群組是空的 —— 不會有任何機器跑 nginx/php/前端"))
    if len(dbp) == 0:
        out.append(("E", "db_primary 是空的 —— migration 永遠不會執行"))
    elif len(dbp) > 1:
        out.append(("E", f"db_primary 有 {len(dbp)} 台（{', '.join(dbp)}）—— 必須剛好一台。"
                         " migration 用 groups['db_primary'] 當 gate，對象必須唯一"))
    for d in dbp:
        if d not in web:
            out.append(("E", f"{d} 是 db_primary 但不在 web —— deploy_backend 不會在它上面跑，"
                             "migration 一次都不會執行（site.yml 的 A15 斷言會擋）"))
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
    print(f"{'主機':<22}{'位址':<24}{'帳號':<12}{'埠':<7}web  db_primary")
    print("-" * 78)
    for h in hosts:
        print(f"{h['name']:<22}{str(h['ip']):<24}{str(h['user'] or '-'):<12}"
              f"{str(h['port'] or 22):<7}{'✔' if h.get('web') else ' ':<5}"
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
    # 第一台預設同時是 web 與 db_primary（單機拓撲，與 hosts.yml.example 一致）
    first = not hosts
    hosts.append({
        "name": args.name, "env": new_env, "ip": args.ip, "user": args.user,
        "port": args.port, "key": args.key,
        "web": True if args.web is None else args.web,
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
