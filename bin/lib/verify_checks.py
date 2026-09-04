#!/usr/bin/env python3
"""cx verify 的靜態檢查：對「合併後的 compose 設定」做斷言。

為什麼吃 `docker compose config --format json` 而不是直接讀 yaml：
base 與 overlay 合併之後的結果才是 Docker 真正會用的東西，而 compose 的
合併規則並不直觀（ports 是附加、volumes 以容器內路徑為鍵、networks 會被
命名空間化）。只 grep yaml 檔會漏掉 overlay 造成的差異。

每個檢查印一行：<PASS|FAIL>\t<編號>\t<標題>\t<備註>
"""
import json
import os
import re
import sys
from pathlib import Path


def out(status, cid, title, note=""):
    print(f"{status}\t{cid}\t{title}\t{note}")


def load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def services(doc):
    return doc.get("services") or {}


def uncommented(text):
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))


def check_no_container_name(cfgs):
    """D11：寫死 container_name 等於放棄 -p 的隔離，三個模式無法並存。"""
    bad = [f"{m}/{n}" for m, d in cfgs.items()
           for n, s in services(d).items() if s.get("container_name")]
    if bad:
        out("FAIL", "D11", "無 container_name", "有寫死名稱：" + ", ".join(bad))
    else:
        out("PASS", "D11", "無 container_name")


def check_no_app_entrypoint(cfgs):
    """3.3：app service 不可宣告 entrypoint。

    image 的 ENTRYPOINT 必須保持 docker-php-entrypoint 的 argv 直通，否則
    `compose run --rm --entrypoint composer app install` 會變成
    `<entrypoint> composer install`。
    """
    bad = [m for m, d in cfgs.items() if (services(d).get("app") or {}).get("entrypoint")]
    if bad:
        out("FAIL", "3.3", "app 未宣告 entrypoint", "這些模式宣告了：" + ", ".join(bad))
    else:
        out("PASS", "3.3", "app 未宣告 entrypoint")


def check_port_isolation(cfgs):
    """2.2：-p 不隔離 host 埠。三個模式的已發布埠必須完全不重疊。"""
    used, clash = {}, []
    for mode, doc in cfgs.items():
        for name, svc in services(doc).items():
            for p in (svc.get("ports") or []):
                pub = str(p.get("published") or "")
                if not pub or pub == "0":
                    continue
                key = (p.get("host_ip") or "0.0.0.0", pub, p.get("protocol") or "tcp")
                if key in used and used[key][0] != mode:
                    clash.append(f"{pub} 同時被 {used[key][0]}/{used[key][1]} 與 {mode}/{name} 佔用")
                used[key] = (mode, name)
    if clash:
        out("FAIL", "2.2", "三模式埠段不重疊", "; ".join(clash))
    else:
        ports = sorted({k[1] for k in used}, key=int)
        out("PASS", "2.2", "三模式埠段不重疊", "已發布：" + ", ".join(ports))


def check_base_has_no_ports(root):
    """2.2 的成因：compose 的 ports 是「附加」合併，不是覆寫。

    base 寫 8080、overlay 再寫 18080，結果是兩個都發布，
    第二個模式起來時就 port is already allocated。
    """
    lines = uncommented(Path(root, "docker-compose.yml").read_text(encoding="utf-8")).splitlines()
    if any(re.match(r"^\s+ports:\s*$", l) for l in lines):
        out("FAIL", "2.2b", "base 檔沒有 ports:", "docker-compose.yml 出現 ports:（必須只在 overlay）")
    else:
        out("PASS", "2.2b", "base 檔沒有 ports:")


def check_network_named(cfgs):
    """2.5：網路名會被命名空間化成 <project>_<key>。

    cx scan dast 要用 `docker run --network <專案>_test_net` 把 ZAP 塞進 WAF 的網路，
    留給 compose 自動命名就會變成 <專案>_test_app_net。

    專案名從 CX_PROJECT_NAME（.cxroot）來，不能寫死 pm ——
    否則專案改名之後 docker-compose.yml 的 name: 跟著 PROJECT_SLUG 變了，
    這個檢查卻還在期待 pm_<mode>_net，會把正確的設定判成 FAIL。
    """
    proj = os.environ.get("CX_PROJECT_NAME") or "pm"
    problems = []
    for mode, doc in cfgs.items():
        for key, net in (doc.get("networks") or {}).items():
            nm = (net or {}).get("name")
            if not nm:
                problems.append(f"{mode}/{key} 沒有明寫 name:")
            elif nm != f"{proj}_{mode}_net":
                problems.append(f"{mode}/{key} name={nm}（預期 {proj}_{mode}_net）")
    if problems:
        out("FAIL", "2.5", "網路明寫 name:", "; ".join(problems))
    else:
        out("PASS", "2.5", "網路明寫 name:",
            f"{proj}_dev_net / {proj}_test_net / {proj}_prod_net")


def check_image_tag_has_mode(cfgs):
    """3.1：映像 tag 必須含模式。

    spa/static 的 API base URL 是 build 時烘進 bundle 的；test 與 prod 共用 tag
    會讓 `cx test up`（未加 --build）拿到 prod 的 bundle。
    """
    seen, problems = {}, []
    for mode, doc in cfgs.items():
        for name in ("app", "nuxt"):
            svc = services(doc).get(name)
            if not svc:
                continue
            img = svc.get("image") or ""
            if mode not in img:
                problems.append(f"{mode}/{name} 的 tag 不含模式：{img}")
            if img in seen and seen[img] != (mode, name):
                problems.append(f"{img} 被 {seen[img]} 與 ({mode}, {name}) 共用")
            seen[img] = (mode, name)
    if problems:
        out("FAIL", "3.1", "映像 tag 含模式", "; ".join(problems))
    else:
        out("PASS", "3.1", "映像 tag 含模式", ", ".join(sorted(seen)))


def check_prod_closed(cfgs):
    """D13 / 3.6：prod 不發布資料庫與管理工具的埠，也不發布沒有 TLS 的 8443。"""
    prod = cfgs.get("prod")
    if not prod:
        out("FAIL", "D13", "prod 不發布 DB 與管理工具", "沒有 prod 設定")
        return
    problems = []
    for name, svc in services(prod).items():
        pubs = [str(p.get("published") or "") for p in (svc.get("ports") or [])]
        pubs = [p for p in pubs if p and p != "0"]
        if name in ("mysql", "phpmyadmin") and pubs:
            problems.append(f"{name} 發布了 {pubs}")
        if "8443" in pubs:
            problems.append("發布了 8443 但 edge 沒有 listen ssl（Filament 登入會無限 419）")
    if "phpmyadmin" in services(prod):
        problems.append("prod 有 phpmyadmin service")
    if problems:
        out("FAIL", "D13", "prod 不發布 DB 與管理工具", "; ".join(problems))
    else:
        out("PASS", "D13", "prod 不發布 DB 與管理工具")


def check_db_mysql(cfgs):
    """D9：舊的 .env.example 是 sqlite，而環境其實是 MySQL。"""
    problems = []
    for mode, doc in cfgs.items():
        env = (services(doc).get("app") or {}).get("environment") or {}
        if env.get("DB_CONNECTION") != "mysql":
            problems.append(f"{mode}: DB_CONNECTION={env.get('DB_CONNECTION')}")
    if problems:
        out("FAIL", "D9", "DB_CONNECTION=mysql", "; ".join(problems))
    else:
        out("PASS", "D9", "DB_CONNECTION=mysql")


def check_mysql_health_dep(cfgs):
    """D7：php 無 depends_on mysql、mysql 無 healthcheck。"""
    problems = []
    for mode, doc in cfgs.items():
        svcs = services(doc)
        if not (svcs.get("mysql") or {}).get("healthcheck"):
            problems.append(f"{mode}: mysql 沒有 healthcheck")
        dep = (svcs.get("app") or {}).get("depends_on") or {}
        cond = (dep.get("mysql") or {}).get("condition") if isinstance(dep, dict) else None
        if cond != "service_healthy":
            problems.append(f"{mode}: app 對 mysql 的 depends_on condition={cond}")
    if problems:
        out("FAIL", "D7", "mysql healthcheck + depends_on", "; ".join(problems))
    else:
        out("PASS", "D7", "mysql healthcheck + depends_on")


def check_mount_sources(root, cfgs):
    """2.3：bind mount 來源不存在時，Docker 會靜默建立 root:root 空目錄再掛上去。

    於是 CRS 排除規則從未載入、WAF 悄悄失效，而且沒有任何線索。
    """
    missing = []
    prefix = root.rstrip("/") + "/"
    for mode, doc in cfgs.items():
        for name, svc in services(doc).items():
            for v in (svc.get("volumes") or []):
                if v.get("type") != "bind":
                    continue
                src = v.get("source") or ""
                if src.startswith(prefix) and not Path(src).exists():
                    missing.append(f"{mode}/{name}: {src}")
    if missing:
        out("FAIL", "2.3", "bind mount 來源都存在", "; ".join(missing))
    else:
        out("PASS", "2.3", "bind mount 來源都存在")


def check_version_pins(cfgs):
    """§4 版本鎖定表。"""
    want = {
        "mysql": ("mysql:8.4", "8.4 是 LTS（至 2032-04）；9.x 每版只有 8 個月支援"),
        "edge": ("nginx:1.30", "1.29 已 EOL，會變成自家 Trivy 掃出的最大漏洞來源"),
    }
    problems = []
    for mode, doc in cfgs.items():
        for name, spec in want.items():
            svc = services(doc).get(name)
            if not svc:
                continue
            img = svc.get("image") or ""
            if not img.startswith(spec[0]):
                problems.append(f"{mode}/{name}={img}（預期 {spec[0]}*；{spec[1]}）")
    if problems:
        out("FAIL", "4", "版本鎖定", "; ".join(problems))
    else:
        out("PASS", "4", "版本鎖定", "mysql:8.4 / nginx:1.30-alpine")


def check_dockerfiles(root):
    """3.2 不用 pecl；2.1 vendor-dev 不加 --no-autoloader；
    D12 prod 有 xdebug 斷言；D14 dev 不 COPY 原始碼；D15 nuxt 多 target。"""
    php = Path(root, "docker/php/Dockerfile")
    if not php.exists():
        out("FAIL", "3.2", "Dockerfile 存在", "缺少 docker/php/Dockerfile")
        return
    body = uncommented(php.read_text(encoding="utf-8"))

    if "pecl install" in body:
        out("FAIL", "3.2", "不用 pecl install",
            "PECL 已被 Xdebug 官方標為 deprecated，Alpine PHP 8.4+ 有 Filename too long 的已知失敗")
    else:
        out("PASS", "3.2", "不用 pecl install", "改用 mlocati/php-extension-installer")

    if "--no-autoloader" in body:
        out("FAIL", "2.1", "vendor-dev 不加 --no-autoloader",
            "該旗標會跳過 vendor/autoload.php 產生，dev 容器在 entrypoint 就 fatal")
    else:
        out("PASS", "2.1", "vendor-dev 不加 --no-autoloader")

    prod_idx = body.find("AS prod")
    if prod_idx >= 0 and "BUILD ASSERT" in body[prod_idx:] and "xdebug" in body[prod_idx:]:
        out("PASS", "D12", "prod 有 xdebug build 斷言")
    else:
        out("FAIL", "D12", "prod 有 xdebug build 斷言", "prod stage 找不到斷言")

    dev_start, dev_end = body.find("AS dev"), body.find("AS test")
    seg = body[dev_start:dev_end] if 0 <= dev_start < dev_end else ""
    if "backend/ ./" in seg:
        out("FAIL", "D14", "dev stage 不 COPY 原始碼", "dev target 出現 COPY backend/")
    else:
        out("PASS", "D14", "dev stage 不 COPY 原始碼")

    nuxt = Path(root, "docker/nuxt/Dockerfile")
    if not nuxt.exists():
        out("FAIL", "D15", "nuxt 有多個 target", "缺少 docker/nuxt/Dockerfile")
        return
    n = nuxt.read_text(encoding="utf-8")
    targets = [t for t in ("AS deps", "AS dev", "AS build", "AS prod", "AS static") if t in n]
    if len(targets) >= 4:
        out("PASS", "D15", "nuxt 有多個 target", ", ".join(t[3:] for t in targets))
    else:
        out("FAIL", "D15", "nuxt 有多個 target", "只找到：" + ", ".join(targets))


def check_dockerfile_case(root, cfgs):
    """D1：compose 寫 nuxt/Dockerfile，實檔卻是 nuxt/dockerfile（小寫）。"""
    problems = []
    for mode, doc in cfgs.items():
        for name, svc in services(doc).items():
            b = svc.get("build")
            if not isinstance(b, dict):
                continue
            df = b.get("dockerfile")
            if not df:
                continue
            p = Path(df) if Path(df).is_absolute() else Path(root, df)
            if not p.exists():
                problems.append(f"{mode}/{name}: {df} 不存在")
    if problems:
        out("FAIL", "D1", "Dockerfile 路徑大小寫一致", "; ".join(problems))
    else:
        out("PASS", "D1", "Dockerfile 路徑大小寫一致")


def check_scan_no_fixed_name(root):
    """3.8：短暫容器不要固定 --name。

    --rm 在 CLI 被 SIGKILL、daemon 重啟、OOM 時不會執行，
    下一次就 Conflict. The container name is already in use。
    """
    scan = Path(root, "bin/cmd/scan.sh")
    if not scan.exists():
        out("FAIL", "3.8", "掃描容器不固定 --name", "缺少 bin/cmd/scan.sh")
        return
    if "--name " in uncommented(scan.read_text(encoding="utf-8")):
        out("FAIL", "3.8", "掃描容器不固定 --name", "scan.sh 出現 --name")
    else:
        out("PASS", "3.8", "掃描容器不固定 --name")


def check_no_ignore_platform(root):
    """D10 / 紅線 4：不得用 --ignore-platform-reqs 硬過相依衝突。"""
    hits = []
    targets = list(Path(root, "bin").rglob("*.sh")) + [Path(root, "docker/php/Dockerfile")]
    for p in targets:
        if not p.exists():
            continue
        for i, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            if "--ignore-platform-req" in line and "EX_USAGE" not in line and "拒絕" not in line:
                hits.append(f"{p.relative_to(root)}:{i}")
    if hits:
        out("FAIL", "D10", "無 --ignore-platform-reqs", "; ".join(hits))
    else:
        out("PASS", "D10", "無 --ignore-platform-reqs", "cx composer 會主動拒絕這個旗標")


def main():
    root = sys.argv[1]
    cfgs = {}
    for mode in ("dev", "test", "prod"):
        p = Path(root, ".cx", f"verify-config-{mode}.json")
        if not p.exists():
            continue
        try:
            cfgs[mode] = load(p)
        except Exception as exc:
            out("FAIL", f"cfg-{mode}", "compose config 可解析", str(exc))
    if not cfgs:
        out("FAIL", "cfg", "compose config 可解析", "三個模式都產不出設定")
        return 1

    check_dockerfile_case(root, cfgs)
    check_no_container_name(cfgs)
    check_no_app_entrypoint(cfgs)
    check_base_has_no_ports(root)
    check_port_isolation(cfgs)
    check_network_named(cfgs)
    check_image_tag_has_mode(cfgs)
    check_prod_closed(cfgs)
    check_db_mysql(cfgs)
    check_mysql_health_dep(cfgs)
    check_mount_sources(root, cfgs)
    check_version_pins(cfgs)
    check_dockerfiles(root)
    check_scan_no_fixed_name(root)
    check_no_ignore_platform(root)
    return 0


if __name__ == "__main__":
    sys.exit(main())
