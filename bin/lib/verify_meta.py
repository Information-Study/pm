#!/usr/bin/env python3
"""cx 自己、文件、與 TUI 選單的一致性檢查。

為什麼要有這一支：本專案已知的缺陷有一半以上不是「程式寫錯」，而是
**兩個地方對同一件事的說法不一致**，而且沒有任何東西在盯著：

  * help 說 doctor 會檢查埠與子模組，doctor 兩個都沒實作
  * usage 說 cx scan 吃 --fail-on-findings，parser 直接拒絕
  * 補全的 $verbs 有 acl，case 沒有 acl 分支
  * TUI 的 galaxy 指到 `cx setup galaxy`，那個子指令不存在
  * ansible/README.md 說「從未在真機跑過」，另外兩份文件記著兩次完整部署
  * ansible/README.md 教人設 waf_mode，沒有任何 role 讀那個變數
  * CX_SETUP_SYSTEM_TOOLS 有 acl，_setup_system_have 沒有 acl 分支

這類缺陷的共通點是：單看任何一個檔案都完全正確。所以檢查一定要**跨檔比對**，
而且比對的兩邊都要從實際的東西推導出來，不能是第三份手打的清單 ——
那只會變成下一個會漂移的地方。

輸出格式（給 verify.sh 讀）：每行一筆
    <PASS|FAIL|SKIP>|<編號>|<標題>|<備註>
標題與備註都不可以含有 "|"（_verify_report 用它切欄位）。
"""
import json
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(os.environ.get("CX_ROOT", ".")).resolve()
ROWS = []


def row(status, ident, title, note=""):
    ROWS.append((status, ident, title, note.replace("|", "／")))


def read(rel):
    try:
        return (ROOT / rel).read_text(encoding="utf-8")
    except OSError:
        return ""


def exists(rel):
    """檔案在不在。

    ⚠ 不要用 `read(rel) is None` 判斷 —— read() 對不存在的檔回的是**空字串**，
    那個判斷永遠是 False。2026-09-05 因此讓 LNT-* 與 TPL-* 在一棵剛 clone、
    還沒跑過 cx setup 的樹上全部報 FAIL，而 cli/docs/tui 三個範圍的合約
    正是「在什麼都沒裝的樹上也要跑得完」。缺檔案是 SKIP，不是 FAIL。
    """
    return (ROOT / rel).is_file()


# ══ 共用：從實際的東西推導出「動詞」這個集合 ═══════════════════════════════

def completion_verbs():
    """補全宣告的動詞 —— 使用者打得出來的那一組。"""
    s = read("bin/completion/cx.bash")
    m = re.search(r"local verbs='([^']*)'", s, re.S)
    return set(m.group(1).split()) if m else set()


def alias_table():
    """dispatcher 的 CX_CMD_FILE_OF（砍掉註解，避免把註解掉的那筆算進來）。"""
    s = read("cx")
    m = re.search(r"declare -A CX_CMD_FILE_OF=\((.*?)\n\)", s, re.S)
    if not m:
        return {}
    body = re.sub(r"#.*", "", m.group(1))
    return dict(re.findall(r"\[([a-z-]+)\]=([a-z]+)", body))


def cmd_files():
    return {p.stem for p in (ROOT / "bin/cmd").glob("*.sh")}


def subcommands_of(verb):
    """從補全的 case 分支取出某個動詞的子指令集合。

    用補全而不是 usage heredoc：補全是機器讀的（COMPREPLY），
    格式穩定；usage 是給人看的自由文字，剖析它只會製造假警報。
    """
    s = read("bin/completion/cx.bash")
    m = re.search(
        r"^\s{8}%s\)\n(.*?)(?=^\s{8}[a-z|*]+\)|\n\s{4}esac)" % re.escape(verb),
        s, re.S | re.M)
    if not m:
        return None
    return set(re.findall(r'compgen -W "([^"]*)"', m.group(1))
               and " ".join(re.findall(r'compgen -W "([^"]*)"', m.group(1))).split()
               or [])


# ══ CLI：cx 自己的四方同步 ═════════════════════════════════════════════════

def check_cli_verbs():
    comp, alias, files = completion_verbs(), alias_table(), cmd_files()
    if not comp:
        row("SKIP", "CLI-verbs", "補全宣告的動詞都有實作", "剖析不到 cx.bash 的 $verbs")
        return
    missing = [v for v in sorted(comp) if v not in files and v not in alias]
    if missing:
        row("FAIL", "CLI-verbs", "補全宣告的動詞都有實作",
            "無實作檔也無別名：" + " ".join(missing))
    else:
        row("PASS", "CLI-verbs", "補全宣告的動詞都有實作", f"{len(comp)} 個")

    # 反方向：寫了實作檔卻沒有動詞叫得到 = 接不上的死碼
    targets = set(alias.values())
    orphan = [f for f in sorted(files) if f not in comp and f not in targets]
    if orphan:
        row("FAIL", "CLI-orphan", "每個實作檔都有動詞叫得到",
            "沒有動詞指向：" + " ".join(orphan))
    else:
        row("PASS", "CLI-orphan", "每個實作檔都有動詞叫得到", f"{len(files)} 個檔")


def check_cli_setup_tools():
    """CX_SETUP_SYSTEM_TOOLS 的每一項都要有 _setup_pkgs_for 與 _setup_system_have。

    這正是 C1 的形狀：acl 在清單裡、有 pkgs_for、沒有 system_have，
    於是 cx setup system 把成功報成失敗。清單再長一項就會再發生一次，
    所以檢查要從清單本身推導。
    """
    s = read("bin/cmd/setup.sh")
    m = re.search(r"CX_SETUP_SYSTEM_TOOLS='([^']*)'", s)
    if not m:
        row("SKIP", "CLI-setup", "system 工具三處定義一致", "剖析不到 CX_SETUP_SYSTEM_TOOLS")
        return
    tools = m.group(1).split()
    pkgs = re.search(r"_setup_pkgs_for\(\).*?\n}", s, re.S)
    have = re.search(r"_setup_system_have\(\).*?\n}", s, re.S)
    bad = []
    for t in tools:
        arm = re.compile(r"^\s*%s\)" % re.escape(t), re.M)
        if not (pkgs and arm.search(pkgs.group(0))):
            bad.append(f"{t}(缺 _setup_pkgs_for)")
        if not (have and arm.search(have.group(0))):
            bad.append(f"{t}(缺 _setup_system_have)")
    if bad:
        row("FAIL", "CLI-setup", "system 工具三處定義一致", " ".join(bad))
    else:
        row("PASS", "CLI-setup", "system 工具三處定義一致", f"{len(tools)} 個工具")


def check_cli_usage_flags():
    """usage heredoc 裡宣傳的長旗標，parser 要真的接受。

    C3 的形狀：_scan_usage 寫著 --fail-on-findings，cmd_scan_main 直接 EX_USAGE。

    ⚠ 只能對「會拒絕未知旗標」的動詞做這件事。cx code / compose / test / npm /
    composer / art 是**轉發型**的：它們的 case 有 `-*) passthru+=("$1")`，
    usage 裡列的 --new-window / --build / --filter 本來就不該出現在 parser 裡 ——
    那是給下游工具的。對它們套同一條規則只會製造假警報，而假警報比沒有檢查更糟：
    一條永遠紅燈的檢查等於沒有人會再看它（這正是 A12 的教訓）。
    """
    bad, checked, skipped = [], 0, []
    for f in sorted((ROOT / "bin/cmd").glob("*.sh")):
        s = f.read_text(encoding="utf-8")
        # 轉發型：把未知旗標收進 passthru，而不是 cx_die
        forwards = re.search(r'-\*\)\s*\w*\+?=?\(?"?\$1"?\)?', s) or "passthru" in s
        rejects = re.search(r'\*\)[^\n]*cx_die "\$EX_USAGE"', s)
        if forwards or not rejects:
            skipped.append(f.stem)
            continue
        for um in re.finditer(r"_\w+_usage\(\)\s*\{(.*?)\n\}", s, re.S):
            body = um.group(1)
            rest = s.replace(um.group(0), "")
            for flag in sorted(set(re.findall(r"(?<![\w-])(--[a-z][a-z0-9-]{2,})", body))):
                if re.search(r"cx\s+%s" % re.escape(flag), body):
                    continue        # 說明裡提到的全域旗標
                checked += 1
                if flag not in rest:
                    bad.append(f"{f.name}:{flag}")
    if bad:
        row("FAIL", "CLI-flags", "usage 宣傳的旗標 parser 都接受", " ".join(sorted(bad)))
    else:
        row("PASS", "CLI-flags", "usage 宣傳的旗標 parser 都接受",
            f"{checked} 個旗標；{len(skipped)} 個轉發型動詞不適用")


def check_cli_help_sync():
    """help.sh 提到的動詞與補全宣告的動詞要是同一組。

    compose 系的 up/down/ps/logs/sh/build/config/restart/dc 在 help 裡是
    **成組**說明的（「這 9 個動作也可以不加模式直接打」），不是各自一行，
    所以它們只要那段文字在就算數。
    """
    comp = completion_verbs()
    if not comp:
        row("SKIP", "CLI-help", "help 與補全的動詞集合一致", "剖析不到 $verbs")
        return
    help_txt = read("bin/cmd/help.sh")
    in_help = set()
    for line in help_txt.splitlines():
        m = re.match(r"^ {2,4}([a-z][a-z0-9-]*)\b", line)
        if m:
            in_help.add(m.group(1))
    grouped = {v for v, f in alias_table().items() if f == "compose"}
    if "cx ps / cx config" in help_txt or "不加模式直接打" in help_txt:
        in_help |= grouped
    in_help.add("help")
    missing = sorted(v for v in comp if v not in in_help)
    if missing:
        row("FAIL", "CLI-help", "help 有寫到每個動詞", "help 沒提到：" + " ".join(missing))
    else:
        row("PASS", "CLI-help", "help 有寫到每個動詞", f"{len(comp)} 個")


# ══ TUI：選單每一項都指得到真的存在的指令 ═════════════════════════════════

def check_tui():
    s = read("bin/cmd/tui.sh")
    if not s:
        row("SKIP", "TUI-resolve", "選單項目都指得到實際存在的指令", "讀不到 tui.sh")
        return
    comp, alias, files = completion_verbs(), alias_table(), cmd_files()
    known = comp | set(files) | set(alias)

    bad, seen = [], set()

    # _tui_freeform <verb> —— 自由參數的動詞（art / php / composer / npm）
    for m in re.finditer(r"_tui_freeform\s+([a-z][a-z0-9-]*)", s):
        if m.group(1) in known:
            seen.add(m.group(1))
        else:
            bad.append(f"{m.group(1)}(不是動詞)")

    # `*) _tui_run "$c"` 的選單：tag 本身就是動詞。這種寫法看不出字面參數，
    # 但「這個 tag 是不是一個真的動詞」仍然驗得到。
    for fn in re.finditer(r"^_tui_\w+\(\)\s*\{(.*?)^\}", s, re.S | re.M):
        body = fn.group(1)
        if not re.search(r'_tui_run\s+"\$c"', body):
            continue
        for mm in re.finditer(r'^\s{8}([a-z][a-z0-9-]*)\s+"', body, re.M):
            tag = mm.group(1)
            if tag in known:
                seen.add(tag)

    # _tui_stack <mode> —— 容器子選單，dev/prod 是模式前綴動詞
    if "_tui_stack" in s:
        seen |= {v for v in ("dev", "prod", "test") if v in known}

    # _tui_run <verb> [args...]  —— 只看寫死的字面參數，變數展開的略過
    for m in re.finditer(r"_tui_run\s+([a-z][a-z0-9-]*)((?:\s+(?:--)?[a-z][\w.:-]*)*)", s):
        verb, rest = m.group(1), m.group(2).split()
        if verb not in known:
            bad.append(f"{verb}(不是動詞)")
            continue
        seen.add(verb)
        if not rest:
            continue
        sub = rest[0]
        if sub.startswith("-"):
            continue
        subs = subcommands_of(verb)
        # 補全沒有為這個動詞宣告子指令清單 → 無從判斷，不誤報
        if subs and sub not in subs:
            key = f"{verb} {sub}"
            if key not in bad:
                bad.append(f"{key}(不是 {verb} 的子指令)")
    if bad:
        row("FAIL", "TUI-resolve", "選單項目都指得到實際存在的指令", " ".join(sorted(set(bad))))
    else:
        row("PASS", "TUI-resolve", "選單項目都指得到實際存在的指令", f"涵蓋 {len(seen)} 個動詞")

    # 覆蓋率：哪些動詞從選單完全到不了
    # 這幾個刻意只走命令列：tui 自己、安裝／移除、以及 compose 的原始逃生門
    CLI_ONLY = {"tui", "install", "uninstall", "dc", "config", "help",
                "up", "down", "restart", "ps", "logs", "sh", "build"}
    unreachable = sorted(v for v in comp if v not in seen and v not in CLI_ONLY)
    if unreachable:
        row("FAIL", "TUI-coverage", "每個動詞都能從選單到達",
            "到不了：" + " ".join(unreachable))
    else:
        row("PASS", "TUI-coverage", "每個動詞都能從選單到達",
            f"{len(seen)} 個可達，{len(CLI_ONLY & comp)} 個刻意只走命令列")


# ══ DOCS：文件與實作是否一致 ═══════════════════════════════════════════════

def check_docs():
    # ── 反向警語。ansible/README.md 說「從未在真機執行過」，而 progress 與
    #    ansible-reference 都記著實跑結果。三份文件不可能都對。
    ans = read("ansible/README.md")
    evidence = ("failed=0" in read("docs/progress.md")
                or "ok=49" in read("docs/ansible-reference.md"))
    stale = [p for p in ("從未在真實主機上執行過", "這套東西沒有在真機上跑過",
                         "連 `--syntax-check` 都跑不了")
             if p in ans]
    if stale and evidence:
        row("FAIL", "DOC-ansible-run", "ansible/README 的執行狀態與實測一致",
            "README 仍寫著：" + "／".join(stale))
    elif stale:
        row("SKIP", "DOC-ansible-run", "ansible/README 的執行狀態與實測一致",
            "README 說沒跑過，且找不到實跑記錄 —— 可能是真的")
    else:
        row("PASS", "DOC-ansible-run", "ansible/README 的執行狀態與實測一致")

    # ── claude.md 被 README 宣告為權威來源，不能還停在「尚未上真機」
    cm = read("claude.md")
    if evidence and re.search(r"尚未上真機", cm):
        row("FAIL", "DOC-claude-run", "claude.md 的 Ansible 狀態與實測一致",
            "claude.md 仍寫著「尚未上真機」")
    else:
        row("PASS", "DOC-claude-run", "claude.md 的 Ansible 狀態與實測一致")

    # ── 文件教的變數要真的被讀。waf_mode 是這一類的原型。
    prescribed = set(re.findall(r"`(waf_[a-z_]+)`\s*\|", ans))
    code = "".join(read(str(p.relative_to(ROOT)))
                   for p in list((ROOT / "ansible/roles").rglob("*.yml"))
                   + list((ROOT / "ansible/roles").rglob("*.j2"))
                   + list((ROOT / "ansible/inventory").rglob("*.yml")))
    dead = sorted(v for v in prescribed if v not in code)
    if dead:
        row("FAIL", "DOC-ansible-vars", "README 教的變數都真的被 role 讀取",
            "沒有任何地方讀：" + " ".join(dead))
    else:
        row("PASS", "DOC-ansible-vars", "README 教的變數都真的被 role 讀取",
            f"{len(prescribed)} 個 waf_* 變數")

    # ── group_vars/all 是目錄不是檔。指錯路徑的人會編輯一個不被載入的檔。
    wrong = []
    for rel in ("ansible/README.md", "docs/ansible-reference.md",
                "docs/docker-verification.md", "claude.md"):
        for line in read(rel).splitlines():
            if "group_vars/all.yml" not in line:
                continue
            # 「不是 / 不用 group_vars/all.yml」這種否定句是在**警告**別用錯路徑，
            # 不是在教人用它。把警告也判成違規的話，修好之後反而會再紅一次
            # —— 而一條修好還是紅的檢查，下一個人就會直接把它關掉。
            #
            # 這是啟發式判斷，不是語意分析：判準是「同一行有沒有否定詞」。
            # 誤放行的代價（漏抓一處錯路徑）比誤攔截（永遠紅燈）小得多。
            if any(k in line for k in ("不是", "不能", "不用", "而非", "別用",
                                       "錯誤", "誤", "避免", "曾經")):
                continue
            wrong.append(rel)
            break
    if wrong:
        row("FAIL", "DOC-groupvars", "文件指向的 group_vars 路徑正確",
            "寫成 all.yml（實際是目錄 all/main.yml）：" + " ".join(wrong))
    else:
        row("PASS", "DOC-groupvars", "文件指向的 group_vars 路徑正確")

    # ── Livewire 前綴。docker 與 ansible 兩條路都不可以再用字面前綴比對。
    # 只看實際生效的規則，不看說明文字 —— 這兩個檔的註解與 comment: 欄位裡
    # 本來就會寫「不能用 @beginsWith /livewire/」，那是說明，不是規則。
    # .conf 看 SecRule 行；.yml 看 condition: 欄位。
    hits = []
    for rel, keep in (
            ("docker/waf/exclusions-before/pm-exclusions-before.conf",
             lambda l: l.lstrip().startswith("SecRule")),
            ("ansible/roles/nginx_myguard/defaults/main.yml",
             lambda l: l.lstrip().startswith("condition:")),
    ):
        for line in read(rel).splitlines():
            if keep(line) and "@beginsWith /livewire/" in line:
                hits.append(rel)
                break
    if hits:
        row("FAIL", "DOC-livewire", "Livewire 排除規則用得到的前綴形狀",
            "仍是 @beginsWith /livewire/（v4 的前綴帶 APP_KEY 雜湊）：" + " ".join(hits))
    else:
        row("PASS", "DOC-livewire", "Livewire 排除規則用得到的前綴形狀")

    # ── cx-reference 要涵蓋每個動詞
    ref, comp = read("docs/cx-reference.md"), completion_verbs()
    if ref and comp:
        # compose 系（up/down/ps/…）在 cx-reference 是成組說明的一節，
        # 不是每個動詞各一節 —— 那一節在就算數。
        grouped = {v for v, f in alias_table().items() if f == "compose"}
        # compose 系那一節的標題是 `cx dev` / `cx test` / `cx prod` / `cx up|down|…`，
        # 不是每個動詞各一個 `cx <verb>` 的字樣。認那一節在不在。
        documented_grouped = "cx up|down" in ref or "容器操作" in ref
        # 判準是「這份文件有沒有提到這個動詞」，不是「有沒有專屬章節」——
        # 後者太嚴（很多動詞本來就該合在一節講），而前者已經抓得到真正的漏網：
        # cx style 在補上文件之前就是被這一項抓出來的。
        undocumented = sorted(
            v for v in comp
            if not re.search(r"`cx %s[ `]" % re.escape(v), ref)
            and not (v in grouped and documented_grouped))
        if undocumented:
            row("FAIL", "DOC-cx-verbs", "cx-reference 涵蓋每個動詞",
                "沒有文件：" + " ".join(undocumented))
        else:
            row("PASS", "DOC-cx-verbs", "cx-reference 涵蓋每個動詞", f"{len(comp)} 個")


# ══ GRD：測試資料庫防護的接線 ═════════════════════════════════════════════

def check_test_db_guard():
    """防護的三個零件必須同時在位，而且 phpunit.xml 要真的指過去。

    最重要的是第一項。`_fresh_carryover` 的 KEEP 清單帶 `tests`，
    但**不帶 `phpunit.xml`** —— 所以一次 carryover 重建會把 tests/bootstrap.php
    疊回去，卻讓 phpunit.xml 被重新產生回 bootstrap="vendor/autoload.php"。
    結果是：防護的檔案都還在，但已經沒有任何人呼叫它了。
    那是最惡劣的一種失效 —— 看起來有防護，實際上沒有。
    """
    xml = read("backend/phpunit.xml")
    if not xml:
        row("SKIP", "GRD-wire", "phpunit.xml 指向測試防護", "讀不到 backend/phpunit.xml")
        return

    m = re.search(r'bootstrap="([^"]+)"', xml)
    got = m.group(1) if m else "(未宣告)"
    if got == "tests/bootstrap.php":
        row("PASS", "GRD-wire", "phpunit.xml 指向測試防護", got)
    else:
        row("FAIL", "GRD-wire", "phpunit.xml 指向測試防護",
            f'bootstrap="{got}"，應為 tests/bootstrap.php'
            "（cx fresh --mode carryover 會重新產生 phpunit.xml 而不會帶回這一行）")

    missing = [f for f in ("backend/tests/bootstrap.php", "backend/tests/DatabaseSafetyGuard.php")
               if not (ROOT / f).exists()]
    if missing:
        row("FAIL", "GRD-files", "測試防護的檔案都在", "缺少：" + " ".join(missing))
    else:
        boot = read("backend/tests/bootstrap.php")
        if "DatabaseSafetyGuard" in boot and "assertProcessEnv" in boot:
            row("PASS", "GRD-files", "測試防護的檔案都在")
        else:
            row("FAIL", "GRD-files", "測試防護的檔案都在",
                "bootstrap.php 沒有呼叫 DatabaseSafetyGuard::assertProcessEnv()")

    # Layer B 一定要掛在 createApplication()，不能是 setUp()。
    tc = read("backend/tests/TestCase.php")
    if "assertResolvedConfig" not in tc:
        row("FAIL", "GRD-layer2", "Layer B 掛在 createApplication()",
            "TestCase.php 沒有呼叫 assertResolvedConfig()")
    elif re.search(r"function\s+setUp\s*\(", tc):
        row("FAIL", "GRD-layer2", "Layer B 掛在 createApplication()",
            "掛在 setUp() —— RefreshDatabase 在 setUpTraits() 就清庫了，"
            "那時候檢查已經太晚（順序見 InteractsWithTestCaseLifecycle）")
    elif re.search(r"public\s+function\s+createApplication\s*\(", tc):
        row("PASS", "GRD-layer2", "Layer B 掛在 createApplication()")
    else:
        row("FAIL", "GRD-layer2", "Layer B 掛在 createApplication()",
            "找不到 public function createApplication()（父類別是 public，覆寫不能降可見度）")

    # cx test 那條 shell 路徑不能與防護漂移
    sh = read("bin/cmd/test.sh")
    want = ("DB_CONNECTION=sqlite", "DB_DATABASE=:memory:")
    lost = [w for w in want if w not in sh]
    if lost:
        row("FAIL", "GRD-cxtest", "cx test 的 env 清單仍導向 sqlite", "缺少：" + " ".join(lost))
    else:
        row("PASS", "GRD-cxtest", "cx test 的 env 清單仍導向 sqlite")


def check_bats_wiring():
    """cx 的行為測試接線。

    **只驗接線，不代表測試通過** —— 「測試有沒有過」這個宣稱只屬於
    `cx test cli`，不屬於任何別的地方。這一項抓的是漂移：
    有測試檔卻沒有動詞叫得到，或有動詞卻沒有測試檔。
    """
    tests = sorted((ROOT / "bin/test").glob("*.bats")) if (ROOT / "bin/test").is_dir() else []
    sh = read("bin/cmd/test.sh")
    has_arm = bool(re.search(r"^\s*cli\|self\)", sh, re.M))
    comp = read("bin/completion/cx.bash")
    m = re.search(r"^\s{8}test\)\n(.*?)(?=^\s{8}[a-z|*]+\)|\n\s{4}esac)", comp, re.S | re.M)
    in_comp = bool(m and "cli" in m.group(1))

    if not tests and not has_arm:
        row("SKIP", "CLI-bats", "cx 行為測試的接線", "沒有 bin/test/*.bats，也沒有 cli 分支")
        return
    problems = []
    if tests and not has_arm:
        problems.append("有 bin/test/*.bats 但 cmd_test_main 沒有 cli) 分支")
    if has_arm and not tests:
        problems.append("有 cli) 分支但 bin/test/ 底下沒有 .bats")
    if has_arm and not in_comp:
        problems.append("補全的 test 子指令清單沒有 cli")
    if problems:
        row("FAIL", "CLI-bats", "cx 行為測試的接線", "；".join(problems))
    else:
        row("PASS", "CLI-bats", "cx 行為測試的接線", f"{len(tests)} 支 .bats")


def _eslint_cx_row():
    """cx lint js 有沒有真的接上 ESLint —— 這一項與 frontend/ 在不在無關。"""
    lint = read("bin/cmd/lint.sh")
    if "_lint_js_eslint" in lint and re.search(r"js\)\s+_lint_one _lint_js_eslint", lint):
        row("PASS", "LNT-eslint-cx", "cx lint js 真的會跑 ESLint", "js 與 all 兩個分支都接了")
    else:
        row("FAIL", "LNT-eslint-cx", "cx lint js 真的會跑 ESLint",
            "bin/cmd/lint.sh 的 js 分支沒有呼叫 _lint_js_eslint —— 只會跑 Prettier")


def check_eslint_wiring():
    """ESLint 的四個零件必須同時在位。

    理由與 GRD-wire 完全相同，而且這裡更脆：`_fresh_keep_dirs frontend` 的
    KEEP 清單只有目錄（app / components / pages …），**不含 eslint.config.mjs、
    也不含 nuxt.config.ts 與 package.json**。所以一次 carryover 重建會：
      - `nuxi init` 重新產生 package.json  → eslint 與 @nuxt/eslint 兩個
        devDependency 消失
      - 重新產生 nuxt.config.ts            → modules 少掉 '@nuxt/eslint'
      - eslint.config.mjs 不在 KEEP 裡     → 直接被刪掉
    三件事同時發生，而 `cx lint js` 只會安靜地少跑一半 —— 它不會說
    「ESLint 不見了」，只會回報 Prettier 的結果然後印「靜態檢查通過」。
    """
    # 判準用 nuxt.config.ts 而不是 package.json：ESLint 的接線是**Nuxt 專案**
    # 才有意義的東西，而 package.json 隨便一個 stub 都有（bats 的 fixture 就是
    # 一行 {"name":"bats-frontend"}）。沒有 nuxt.config.ts 就沒有 Nuxt 專案，
    # 這三項無從檢查 —— 那是 SKIP，不是 FAIL。
    nuxt_cfg = next((f for f in ("frontend/nuxt.config.ts", "frontend/nuxt.config.js",
                                 "frontend/nuxt.config.mjs") if exists(f)), None)
    if not nuxt_cfg:
        why = "這棵樹沒有 frontend/nuxt.config.*（不是 Nuxt 專案）"
        row("SKIP", "LNT-eslint-cfg", "frontend/eslint.config.mjs 存在", why)
        row("SKIP", "LNT-eslint-dep", "frontend 有 eslint 與 @nuxt/eslint", why)
        row("SKIP", "LNT-eslint-mod", "nuxt.config 的 modules 含 @nuxt/eslint", why)
        _eslint_cx_row()
        return
    cfg = read("frontend/eslint.config.mjs")
    if not exists("frontend/eslint.config.mjs"):
        row("FAIL", "LNT-eslint-cfg", "frontend/eslint.config.mjs 存在",
            "檔案不存在（cx fresh --mode carryover 不會把它帶回來）")
    elif ".nuxt/eslint.config.mjs" not in cfg:
        row("FAIL", "LNT-eslint-cfg", "frontend/eslint.config.mjs 存在",
            "沒有 import ./.nuxt/eslint.config.mjs —— Nuxt 的 auto-import 全域會全部報 no-undef")
    else:
        row("PASS", "LNT-eslint-cfg", "frontend/eslint.config.mjs 存在", "並 extend .nuxt 的產生設定")

    pkg = read("frontend/package.json")
    if True:
        try:
            dev = (json.loads(pkg).get("devDependencies") or {})
        except ValueError:
            dev = {}
        miss = [d for d in ("eslint", "@nuxt/eslint") if d not in dev]
        if miss:
            row("FAIL", "LNT-eslint-dep", "frontend 有 eslint 與 @nuxt/eslint",
                f"devDependencies 缺少 {', '.join(miss)}")
        else:
            row("PASS", "LNT-eslint-dep", "frontend 有 eslint 與 @nuxt/eslint",
                " ".join(f"{d}@{dev[d]}" for d in ("eslint", "@nuxt/eslint")))

    nc = read(nuxt_cfg)
    if "'@nuxt/eslint'" in nc or '"@nuxt/eslint"' in nc:
        row("PASS", "LNT-eslint-mod", "nuxt.config 的 modules 含 @nuxt/eslint", "")
    else:
        row("FAIL", "LNT-eslint-mod", "nuxt.config 的 modules 含 @nuxt/eslint",
            "少了它就不會產生 .nuxt/eslint.config.mjs，eslint.config.mjs 的 import 會失敗")

    _eslint_cx_row()


def _project_name():
    """從 .cxroot 讀出專案名 —— 與 cx_project() 同一個來源。"""
    txt = read(".cxroot") or ""
    m = re.search(r"^CX_PROJECT_NAME=(\S+)", txt, re.M)
    return m.group(1) if m else None


def check_template_identity():
    """專案身分只能有一個事實來源：.cxroot 的 CX_PROJECT_NAME。

    `cx` 的 shell / Python 層是乾淨的（全部走 cx_project()），
    但有四個地方是**硬編碼或第二事實來源**，就地改名時會靜默不一致：

      .env 的 PROJECT_SLUG / IMAGE_PREFIX
          `_setup_env` 只在**產生** .env 時寫入，檔案已存在就早退、
          從不回頭核對。所以改了 .cxroot 之後，compose 專案前綴仍然是舊的
          （網路還叫 pm_dev_net），而且沒有任何地方會說出來。
      sonar-project.properties 的 projectKey / projectName
      group_vars/all/main.yml 的 app_name / app_slug
      site.yml 的 hosts 群組名 ←→ deploy.sh 的 --list-hosts 參數
          這兩個必須彼此一致，否則 cx deploy ping 會找不到任何主機。

    這一族檢查比 `cx rename` 更重要：自動化可以用手做，
    但「改到一半而且沒人知道」只有檢查抓得到。
    """
    want = _project_name()
    if not want:
        row("SKIP", "TPL-name", "專案身分一致", "讀不到 .cxroot 的 CX_PROJECT_NAME")
        return

    env = read(".env")
    if not exists(".env"):
        row("SKIP", "TPL-env", ".env 的 slug 與 .cxroot 一致", "沒有 .env（跑 cx setup env）")
    else:
        bad = []
        for key in ("PROJECT_SLUG", "IMAGE_PREFIX"):
            m = re.search(rf"^{key}=(\S*)", env, re.M)
            got = m.group(1) if m else "(未宣告)"
            if got != want:
                bad.append(f"{key}={got}")
        if bad:
            row("FAIL", "TPL-env", ".env 的 slug 與 .cxroot 一致",
                f"{' '.join(bad)}，應為 {want}"
                "（_setup_env 在 .env 已存在時會早退，不會自己修正）")
        else:
            row("PASS", "TPL-env", ".env 的 slug 與 .cxroot 一致", want)

    sonar = read("sonar-project.properties")
    if not exists("sonar-project.properties"):
        row("SKIP", "TPL-sonar", "sonar-project.properties 與 .cxroot 一致", "檔案不存在")
    else:
        bad = []
        for key in ("sonar.projectKey", "sonar.projectName"):
            m = re.search(rf"^{re.escape(key)}=(\S*)", sonar, re.M)
            got = m.group(1) if m else "(未宣告)"
            if got != want:
                bad.append(f"{key}={got}")
        if bad:
            row("FAIL", "TPL-sonar", "sonar-project.properties 與 .cxroot 一致",
                f"{' '.join(bad)}，應為 {want}")
        else:
            row("PASS", "TPL-sonar", "sonar-project.properties 與 .cxroot 一致", want)

    gv = read("ansible/inventory/group_vars/all/main.yml")
    if not exists("ansible/inventory/group_vars/all/main.yml"):
        row("SKIP", "TPL-ansible", "group_vars 的 app_slug 與 .cxroot 一致", "讀不到 group_vars")
    else:
        m = re.search(r'^app_slug:\s*"?([^"\s]+)"?', gv, re.M)
        got = m.group(1) if m else "(未宣告)"
        if got != want:
            row("FAIL", "TPL-ansible", "group_vars 的 app_slug 與 .cxroot 一致",
                f"app_slug={got}，應為 {want}")
        else:
            row("PASS", "TPL-ansible", "group_vars 的 app_slug 與 .cxroot 一致", want)

    site = read("ansible/site.yml") or ""
    dep = read("bin/cmd/deploy.sh") or ""
    groups = set(re.findall(r"^\s*hosts:\s*(\S+)", site, re.M)) - {"localhost"}
    used = set(re.findall(r"--list-hosts\s+(\S+)", dep)) | set(re.findall(r"ansible\s+([a-z_]+_servers)", dep))
    if not groups or not used:
        row("SKIP", "TPL-group", "site.yml 的 hosts 群組與 deploy.sh 一致",
            "抓不到群組名")
    elif groups != used:
        row("FAIL", "TPL-group", "site.yml 的 hosts 群組與 deploy.sh 一致",
            f"site.yml={sorted(groups)} vs deploy.sh={sorted(used)}"
            "（不一致時 cx deploy ping 會找不到任何主機）")
    else:
        row("PASS", "TPL-group", "site.yml 的 hosts 群組與 deploy.sh 一致",
            " ".join(sorted(groups)))


def check_php_prefix_parity():
    """Docker 的 edge 與原生的 nginx 必須把**同一組前綴**交給 PHP。

    這一族差異的症狀都一樣：某個路徑在一邊正常、在另一邊 404，而且看起來
    像「應用壞了」而不是「路由設錯了」。docker/edge/conf.d/default.conf 自己
    第 55 行的註解就記過同一種故障（Filament 的資產被前端吃掉 → 後台沒樣式）。

    2026-09-05 實測的分岔：/filament /login /logout /broadcasting 四個前綴在
    Docker 側會掉進 catch-all 交給 Nuxt（回 Nitro 的 404），原生側則交給 PHP。
    """
    gv = read("ansible/inventory/group_vars/all/main.yml")
    conf = read("docker/edge/conf.d/default.conf")
    if not exists("ansible/inventory/group_vars/all/main.yml") or not exists("docker/edge/conf.d/default.conf"):
        row("SKIP", "A13-parity", "Docker 與原生的 PHP 前綴一致", "少了其中一份設定")
        return

    m = re.search(r"^nginx_php_prefixes:\n((?:\s*-\s*\"[^\"]+\"\n)+)", gv, re.M)
    if not m:
        row("SKIP", "A13-parity", "Docker 與原生的 PHP 前綴一致", "讀不到 nginx_php_prefixes")
        return
    native = {x.strip().lstrip("/") for x in re.findall(r'-\s*"([^"]+)"', m.group(1))}

    # Docker 側：把所有交給 pm-php.inc 的 location 抓出來
    docker = set()
    # 前綴型（= / ^~）與正規式型分開抓
    for lm in re.finditer(r"location\s+(?:=|\^~)\s+(/[A-Za-z0-9_./-]*)\s*\{[^}]*pm-php\.inc", conf):
        docker.add(lm.group(1).strip("/").split("/")[0])
    for lm in re.finditer(r"location\s+~\s+\^/\(([^)]+)\)", conf):
        for alt in lm.group(1).split("|"):
            alt = alt.strip()
            if re.match(r"^[a-z0-9_-]+$", alt):
                docker.add(alt)

    # livewire 在 Docker 是帶 hash 的正規式，原生是字面 + pattern，兩邊都算有
    if re.search(r"location\s+~\s+\^/livewire", conf):
        docker.add("livewire")

    missing = sorted(native - docker)
    if missing:
        row("FAIL", "A13-parity", "Docker 與原生的 PHP 前綴一致",
            "docker/edge 少了：" + " ".join("/" + x for x in missing)
            + "（原生側 group_vars 的 nginx_php_prefixes 有）")
    else:
        row("PASS", "A13-parity", "Docker 與原生的 PHP 前綴一致",
            " ".join(sorted("/" + x for x in native)))


def check_setup_completion_drift():
    """`cx setup tools|system` 的補全清單必須涵蓋 setup.sh 的權威清單。

    這一族漂移不會讓任何東西壞掉 —— 它只是讓 Tab 補不出真的裝得起來的工具，
    於是使用者以為那個工具不存在。2026-09-05 實測：`CX_SETUP_TOOLS` 已經含
    shellcheck 與 bats（`cx lint sh` / `cx test cli` 也會叫使用者去裝），
    而補全的清單少了這兩個；`CX_SETUP_SYSTEM_TOOLS` 的 jq 同樣沒進補全。

    既有的 `CLI-setup` 只查 `CX_SETUP_SYSTEM_TOOLS` 有沒有對應的函式，
    查不到這一種。
    """
    setup = read("bin/cmd/setup.sh")
    comp = read("bin/completion/cx.bash")
    if not setup or not comp:
        row("SKIP", "CLI-setup-comp", "setup 的補全清單涵蓋權威清單", "讀不到來源")
        return

    bad = []
    for var, key in (("CX_SETUP_TOOLS", "tools"),
                     ("CX_SETUP_SYSTEM_TOOLS", "system")):
        m = re.search(rf"{var}='([^']*)'", setup)
        if not m:
            bad.append(f"{var}(讀不到)")
            continue
        want = set(m.group(1).split())
        cm = re.search(rf'{key}\)\s*COMPREPLY=\(\$\(compgen -W "([^"]+)"', comp)
        if not cm:
            bad.append(f"補全沒有 {key}) 分支")
            continue
        have = set(cm.group(1).split())
        miss = sorted(want - have)
        if miss:
            bad.append(f"{key} 少了 {' '.join(miss)}")
    if bad:
        row("FAIL", "CLI-setup-comp", "setup 的補全清單涵蓋權威清單",
            "; ".join(bad) + "（Tab 補不出來的工具，使用者會以為不存在）")
    else:
        row("PASS", "CLI-setup-comp", "setup 的補全清單涵蓋權威清單",
            "tools 與 system 都涵蓋")


def main():
    families = sys.argv[1:] or ["cli", "docs", "tui"]
    if "cli" in families:
        check_cli_verbs()
        check_cli_setup_tools()
        check_cli_usage_flags()
        check_cli_help_sync()
        check_test_db_guard()
        check_bats_wiring()
        check_eslint_wiring()
        check_template_identity()
        check_php_prefix_parity()
        check_setup_completion_drift()
    if "tui" in families:
        check_tui()
    if "docs" in families:
        check_docs()
    for st, ident, title, note in ROWS:
        print(f"{st}|{ident}|{title}|{note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
