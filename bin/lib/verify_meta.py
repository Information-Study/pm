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


def main():
    families = sys.argv[1:] or ["cli", "docs", "tui"]
    if "cli" in families:
        check_cli_verbs()
        check_cli_setup_tools()
        check_cli_usage_flags()
        check_cli_help_sync()
        check_test_db_guard()
        check_bats_wiring()
    if "tui" in families:
        check_tui()
    if "docs" in families:
        check_docs()
    for st, ident, title, note in ROWS:
        print(f"{st}|{ident}|{title}|{note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
