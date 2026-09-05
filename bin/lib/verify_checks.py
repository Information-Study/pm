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


# 自家建置的映像（pm/app、pm/nuxt）tag 由模式組出來，不適用外部映像的規則。
_LOCAL_IMAGE_RE = re.compile(r"^[A-Za-z0-9_.-]+/(app|nuxt):")

# 沒有版本資訊的 tag。這些是**浮動**的：同一份 compose 在兩天之內可以拉到
# 完全不同的東西，而 git log 上什麼都看不到。
_FLOATING_TAGS = {"latest", "stable", "main", "master", "edge", "nightly", "dev"}


def _tag_is_pinned(image):
    """image 是否釘到了明確版本。回傳 (ok, 原因)。"""
    ref = image.split("@")[0]              # digest 形式一律算釘住
    if "@sha256:" in image:
        return True, ""
    host_or_ns, _, last = ref.rpartition("/")
    if ":" not in last:
        return False, "完全沒有 tag（等同 latest）"
    tag = last.rsplit(":", 1)[1]
    if tag.lower() in _FLOATING_TAGS:
        return False, f"tag「{tag}」是浮動的"
    if not any(c.isdigit() for c in tag):
        # 例如 owasp/modsecurity-crs:nginx-alpine —— 有 tag，但沒有版本成分
        return False, f"tag「{tag}」不含任何版本數字"
    # 至少要有 major.minor。只有 major 的 tag（phpmyadmin:5、postgres:17-alpine）
    # 仍然是浮動的：整個 5.x / 17.x 系列都可能在某天被換掉。
    if not re.search(r"\d+\.\d+", tag):
        return False, f"tag「{tag}」只有 major，仍然是浮動的（要 major.minor）"
    return True, ""


def check_external_image_pins(cfgs, root):
    """所有外部映像都必須釘到明確版本 —— 不接受 latest／stable／無版本。

    為什麼連掃描器也要釘：trivy 的漏洞庫與 semgrep 的規則集都是**執行期**
    下載的，不烘在映像裡，所以釘住映像版本不會讓它漏掉新的 CVE。
    反過來，讓掃描器浮動代表 CI 可能在沒有任何 commit 的情況下突然多出或
    少掉一批 finding，而沒有人說得出為什麼。
    """
    seen = {}      # image -> 來源描述

    for mode, doc in sorted(cfgs.items()):
        for name, svc in sorted(services(doc).items()):
            img = svc.get("image") or ""
            if img and not _LOCAL_IMAGE_RE.match(img):
                seen.setdefault(img, f"{mode}/{name}")

    # cx 自己 docker run 起來的映像：單一事實來源在 bin/lib/common.sh
    common = Path(root, "bin/lib/common.sh")
    if common.exists():
        for m in re.finditer(r'^(CX_IMG_[A-Z_]+)="\$\{\1:-([^}]+)\}"',
                             common.read_text(encoding="utf-8"), re.M):
            seen.setdefault(m.group(2), f"common.sh/{m.group(1)}")

    # Dockerfile 的 FROM 與 COPY --from（ARG 預設值也算）
    for df in sorted(Path(root, "docker").rglob("Dockerfile")):
        txt = df.read_text(encoding="utf-8")
        for m in re.finditer(r"^ARG\s+\w*IMAGE\w*=(\S+)", txt, re.M):
            seen.setdefault(m.group(1), f"{df.parent.name}/ARG")
        for m in re.finditer(r"^COPY\s+--from=([A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+:\S+)",
                             txt, re.M):
            seen.setdefault(m.group(1), f"{df.parent.name}/COPY --from")

    bad = []
    for img, where in sorted(seen.items()):
        if "${" in img:                    # 純變數引用，展開後的值會另外被看到
            continue
        ok, why = _tag_is_pinned(img)
        if not ok:
            bad.append(f"{img}（{where}：{why}）")

    if bad:
        out("FAIL", "4b", "外部映像一律釘版本（無 latest／無版本 tag）",
            "; ".join(bad))
    else:
        out("PASS", "4b", "外部映像一律釘版本（無 latest／無版本 tag）",
            f"{len(seen)} 個外部映像全部釘住")


def check_dockerfiles(root):
    """3.2 不用 pecl；2.1 vendor-dev 不加 --no-autoloader；
    D12 prod 有 xdebug 斷言；D14 dev 不 COPY 原始碼；D15 nuxt 多 target。"""
    php = Path(root, "env/docker/php/Dockerfile")
    if not php.exists():
        out("FAIL", "3.2", "Dockerfile 存在", "缺少 env/docker/php/Dockerfile")
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

    nuxt = Path(root, "env/docker/nuxt/Dockerfile")
    if not nuxt.exists():
        out("FAIL", "D15", "nuxt 有多個 target", "缺少 env/docker/nuxt/Dockerfile")
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
    targets = list(Path(root, "bin").rglob("*.sh")) + [Path(root, "env/docker/php/Dockerfile")]
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


def check_dockerignore_secrets(root):
    """.dockerignore 的祕密排除樣式，必須涵蓋每一個被 COPY 的子專案。

    2026-09-05 實測到的缺陷：`.dockerignore` 有 `.env` 與 `.env.*`，但那些樣式
    **錨定在 build context 根目錄**，只排除 <root>/.env。而 Dockerfile 是
    `COPY backend/ ./` 與 `COPY frontend/ ./` —— 於是開發者的 backend/.env
    （含真實 APP_KEY 與 DB_PASSWORD）整份被烘進 test/prod 的映像層。

    映像層是撤不回來的，而當時 `cx scan sca` 一路全綠，因為 trivy fs 掃的是
    工作樹、不是映像。所以這一項要靠**靜態比對**擋住：
    凡是 Dockerfile 裡出現 `COPY <dir>/ `，`.dockerignore` 就必須有
    `<dir>/.env` 這條樣式。
    """
    di = Path(root, ".dockerignore")
    if not di.exists():
        out("FAIL", "sec-ignore", ".dockerignore 擋得住子專案的 .env", "找不到 .dockerignore")
        return
    patterns = {ln.strip() for ln in di.read_text(encoding="utf-8").splitlines()
                if ln.strip() and not ln.strip().startswith("#")}

    copied = set()
    for df in sorted(Path(root, "docker").rglob("Dockerfile")):
        for m in re.finditer(r"^COPY\s+(?:--\S+\s+)*([A-Za-z0-9_.-]+)/\s",
                             df.read_text(encoding="utf-8"), re.M):
            copied.add(m.group(1))

    missing = []
    for d in sorted(copied):
        if f"{d}/.env" not in patterns:
            missing.append(f"{d}/.env")
        if f"{d}/.env.*" not in patterns:
            missing.append(f"{d}/.env.*")
    if missing:
        out("FAIL", "sec-ignore", ".dockerignore 擋得住子專案的 .env",
            "缺少樣式：" + " ".join(missing) + "（裸的 .env 只錨定 context 根目錄）")
    else:
        out("PASS", "sec-ignore", ".dockerignore 擋得住子專案的 .env",
            "涵蓋 " + " ".join(sorted(copied)) if copied else "沒有子專案被 COPY")


def check_app_key_injected(cfgs):
    """APP_KEY 必須由 compose 注入，而且是必填（:?）不是有預設（:-）。

    .env 被排除出映像之後，容器裡的 .env 落在 writable layer、不在任何 volume 上。
    沒有注入的話，entrypoint 會在**每一次 --force-recreate** 產生新金鑰，
    把 session 與 encrypted cast 的資料變成解不開的亂碼 —— 而且要等到有人
    回報「登入一直被登出」才會被發現。
    """
    bad = []
    for mode, cfg in cfgs.items():
        env = ((cfg.get("services") or {}).get("app") or {}).get("environment") or {}
        if "APP_KEY" not in env:
            bad.append(f"{mode}(未注入)")
        elif not str(env.get("APP_KEY") or "").strip():
            bad.append(f"{mode}(空值)")
    if bad:
        out("FAIL", "sec-appkey", "APP_KEY 由 compose 注入且非空", " ".join(bad))
    else:
        out("PASS", "sec-appkey", "APP_KEY 由 compose 注入且非空")


# 每個 service 允許的 capability。**寫在檢查裡**是刻意的：
# 要多給一個 capability 就必須改這張表，也就是必須產生一個可以被 review 的 diff。
_CAP_ALLOW = {
    "mysql":      {"CHOWN", "FOWNER", "DAC_OVERRIDE", "SETUID", "SETGID"},
    "app":        {"CHOWN", "FOWNER", "DAC_OVERRIDE", "SETUID", "SETGID"},
    "edge":       {"CHOWN", "DAC_OVERRIDE", "SETUID", "SETGID"},
    "waf":        {"CHOWN", "FOWNER", "DAC_OVERRIDE", "SETUID", "SETGID"},
    # phpmyadmin 是唯一需要 NET_BIND_SERVICE 的：官方映像的 apache 在
    # **容器內**綁 80（<1024）。其餘服務容器內綁的都是 8080/9000/3000。
    "phpmyadmin": {"CHOWN", "DAC_OVERRIDE", "SETUID", "SETGID", "NET_BIND_SERVICE"},
    "nuxt":       set(),          # dev 與 prod target 都已經是 USER node
}


def check_hardening_baseline(cfgs):
    """每個 service 都要有 no-new-privileges 與 cap_drop: [ALL]，
    而 cap_add 必須是允許清單的子集。"""
    bad = []
    for mode, cfg in sorted(cfgs.items()):
        for name, svc in sorted((cfg.get("services") or {}).items()):
            so = [str(x) for x in (svc.get("security_opt") or [])]
            if not any("no-new-privileges" in x for x in so):
                bad.append(f"{mode}/{name}(無 no-new-privileges)")
            drop = {str(x).upper() for x in (svc.get("cap_drop") or [])}
            if "ALL" not in drop:
                bad.append(f"{mode}/{name}(cap_drop 不含 ALL)")
            add = {str(x).upper() for x in (svc.get("cap_add") or [])}
            allowed = _CAP_ALLOW.get(name)
            if allowed is None:
                bad.append(f"{mode}/{name}(不在 capability 允許表中)")
            elif not add <= allowed:
                bad.append(f"{mode}/{name}(多給了 {' '.join(sorted(add - allowed))})")
    if bad:
        out("FAIL", "hard-caps", "執行期硬化基線（no-new-privileges + cap_drop）",
            " ".join(bad))
    else:
        n = sum(len(c.get("services") or {}) for c in cfgs.values())
        out("PASS", "hard-caps", "執行期硬化基線（no-new-privileges + cap_drop）",
            f"{n} 個 service（跨 {len(cfgs)} 個模式）")


def check_stop_semantics(cfgs, root):
    """app 的 stop_grace_period 必須大於 supervisord 的 stopwaitsecs。

    這是跨檔的一致性檢查。原本兩者是**直接矛盾**的：supervisord 等 100 秒，
    Docker 10 秒就 SIGKILL —— 於是處理中的 queue job 一律被砍，而兩個檔案
    各自看起來都很合理。
    """
    conf = Path(root, "env/docker/php/supervisord.conf")
    if not conf.exists():
        out("SKIP", "hard-stop", "stop_grace_period 大於 supervisord 的 stopwaitsecs",
            "找不到 supervisord.conf")
        return
    m = re.search(r"^\s*stopwaitsecs\s*=\s*(\d+)", conf.read_text(encoding="utf-8"), re.M)
    if not m:
        out("SKIP", "hard-stop", "stop_grace_period 大於 supervisord 的 stopwaitsecs",
            "supervisord.conf 沒有 stopwaitsecs")
        return
    want = int(m.group(1))

    def secs(v):
        if v is None:
            return None
        t = str(v).strip()
        if t.endswith("s"):
            return int(float(t[:-1]))
        if t.endswith("m"):
            return int(float(t[:-1]) * 60)
        try:
            return int(float(t))
        except ValueError:
            return None

    bad = []
    for mode, cfg in sorted(cfgs.items()):
        app = (cfg.get("services") or {}).get("app") or {}
        g = secs(app.get("stop_grace_period"))
        if g is None:
            bad.append(f"{mode}(app 沒有 stop_grace_period)")
        elif g <= want:
            bad.append(f"{mode}(grace {g}s ≤ stopwaitsecs {want}s)")
    # edge 與 waf 的 nginx 要用 SIGQUIT 才是優雅關閉
    for mode, cfg in sorted(cfgs.items()):
        for name in ("edge", "waf"):
            svc = (cfg.get("services") or {}).get(name)
            if svc and str(svc.get("stop_signal") or "").upper() != "SIGQUIT":
                bad.append(f"{mode}/{name}(nginx 需要 stop_signal: SIGQUIT)")
    if bad:
        out("FAIL", "hard-stop", "停機語意跨檔一致", " ".join(bad))
    else:
        out("PASS", "hard-stop", "停機語意跨檔一致",
            f"app grace > supervisord stopwaitsecs({want}s)；nginx 用 SIGQUIT")


def _size_to_bytes(v):
    """把 nginx 的大小寫法（64m / 512k / 1048576）換成 bytes。"""
    t = str(v).strip().lower()
    m = re.match(r"^(\d+)([kmg]?)$", t)
    if not m:
        return None
    n = int(m.group(1))
    return n * {"": 1, "k": 1024, "m": 1024 ** 2, "g": 1024 ** 3}[m.group(2)]


def check_upload_limit_chain(cfgs, root):
    """A16：WAF 的 body 上限必須 ≥ nginx 的 client_max_body_size。

    順序反過來的後果不是報錯，是**難以歸因的 413**：檔案先通過 nginx，
    再被 ModSecurity 以 SecRequestBodyLimitAction Reject 擋掉，
    而訊息只會指向 ModSecurity，看不出是兩個限制設反了。

    原生側（env/ansible/roles/nginx_myguard/defaults/main.yml）一直是從
    app_max_upload_mb 推導整條鏈並在 A16 明文要求這個順序；
    Docker 側曾經是 12.5MB < 64m，也就是兩條路徑對同一件事的規則不一致。
    這個檢查就是不讓它們再分岔。
    """
    conf = Path(root, "env/docker/edge/nginx.conf")
    if not conf.exists():
        out("SKIP", "A16", "上傳大小的限制鏈（nginx ≤ WAF）", "找不到 env/docker/edge/nginx.conf")
        return
    m = re.search(r"^\s*client_max_body_size\s+(\S+?);", conf.read_text(encoding="utf-8"), re.M)
    if not m:
        out("SKIP", "A16", "上傳大小的限制鏈（nginx ≤ WAF）", "nginx.conf 沒有 client_max_body_size")
        return
    nginx_b = _size_to_bytes(m.group(1))
    if nginx_b is None:
        out("SKIP", "A16", "上傳大小的限制鏈（nginx ≤ WAF）", f"看不懂的大小：{m.group(1)}")
        return

    bad, seen = [], 0
    for mode, cfg in sorted(cfgs.items()):
        svc = (cfg.get("services") or {}).get("waf")
        if not svc:
            continue
        seen += 1
        env = svc.get("environment") or {}
        if isinstance(env, list):
            env = dict(e.split("=", 1) for e in env if "=" in e)
        waf_b = _size_to_bytes(env.get("MODSEC_REQ_BODY_LIMIT", ""))
        if waf_b is None:
            bad.append(f"{mode}(WAF 沒有 MODSEC_REQ_BODY_LIMIT)")
        elif waf_b < nginx_b:
            bad.append(f"{mode}(WAF {waf_b} < nginx {nginx_b} —— 順序反了)")
    if not seen:
        out("SKIP", "A16", "上傳大小的限制鏈（nginx ≤ WAF）", "沒有模式含 waf service")
    elif bad:
        out("FAIL", "A16", "上傳大小的限制鏈（nginx ≤ WAF）", " ".join(bad))
    else:
        out("PASS", "A16", "上傳大小的限制鏈（nginx ≤ WAF）",
            f"nginx {m.group(1)} ≤ WAF body limit（{seen} 個模式）")


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
    # 純檔案檢查先跑 —— 它們不需要 compose config，不該被「沒有 .env」連坐。
    # 之前的寫法是 cfgs 為空就直接 return 1，於是一個全新 clone（還沒 cx setup env）
    # 連「.dockerignore 擋不擋得住祕密」這種完全靜態的檢查都跑不到。
    check_dockerignore_secrets(root)
    check_base_has_no_ports(root)
    check_dockerfiles(root)
    check_scan_no_fixed_name(root)
    check_no_ignore_platform(root)

    if not cfgs:
        out("FAIL", "cfg", "compose config 可解析", "三個模式都產不出設定（跑 cx setup env）")
        return 1

    check_dockerfile_case(root, cfgs)
    check_no_container_name(cfgs)
    check_no_app_entrypoint(cfgs)
    check_port_isolation(cfgs)
    check_network_named(cfgs)
    check_image_tag_has_mode(cfgs)
    check_prod_closed(cfgs)
    check_db_mysql(cfgs)
    check_app_key_injected(cfgs)
    check_hardening_baseline(cfgs)
    check_stop_semantics(cfgs, root)
    check_mysql_health_dep(cfgs)
    check_mount_sources(root, cfgs)
    check_version_pins(cfgs)
    check_external_image_pins(cfgs, root)
    check_upload_limit_chain(cfgs, root)
    return 0


if __name__ == "__main__":
    sys.exit(main())
