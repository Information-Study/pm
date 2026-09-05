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


def read_required(rel, ident, title):
    """必填文件。讀不到就印 **FAIL 那一列**，絕不讓它從報告裡消失。

    ⚠ 這是本專案自己指認過、卻仍然存在的最惡劣失效形態。原本的寫法是

        ref, comp = read("docs/cx-reference.md"), completion_verbs()
        if ref and comp:
            ... row(...) ...

    檔案被搬走之後，那個 if 讓 DOC-cx-verbs **整列從報告裡不見** —— 而
    cx verify 的退出碼只看 FAIL 的數量。於是「每個動詞都有文件」這件事
    不再被驗證，報告卻仍然全綠。**少一列比多一列紅難發現得多。**

    ⚠ 但「讀不到」有兩種，而它們的答案不一樣：

      a) **檔案被搬走了** —— 全樹別的地方找得到同名檔。這是硬編路徑漏改，
         是真正的缺陷 → FAIL，而且訊息直接指出它搬到哪裡去了。
      b) **這棵樹根本沒有這份文件** —— 全樹都找不到同名檔。bats 的最小
         fixture、或一棵還沒寫到那份文件的樹都是這樣 → SKIP。

    分不清這兩種的代價已經付過一次：2026-09-05 有人把缺席一律當成 FAIL，
    於是 cli/docs/tui 三個範圍在「全新 clone、還沒跑 cx setup」的樹上全部變紅，
    而那三個範圍存在的全部理由就是「什麼都沒裝也要跑得完」（見 exists() 的說明）。
    rglob 的結果剛好就是區分兩者的依據，所以順手做完。
    """
    txt = read(rel)
    if txt:
        return txt
    name = pathlib.PurePath(rel).name
    skip = {".git", "node_modules", "vendor", ".nuxt", ".output", "reports"}
    hits = sorted(
        str(q.relative_to(ROOT)) for q in ROOT.rglob(name)
        if not skip & set(q.relative_to(ROOT).parts))
    if hits:
        row("FAIL", ident, title,
            f"必填文件 {rel} 讀不到，但同名檔在：{' '.join(hits)}"
            " —— 檔案搬過家，有硬編路徑沒跟著改")
    else:
        row("SKIP", ident, title, f"這棵樹沒有 {rel}")
    return None


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
    # ⚠ 單引號與雙引號都要吃。原本只抓 compgen -W "…"，而 git 那一整塊用的是
    # 單引號 —— 於是 subcommands_of("git") 回傳**空集合**，check_tui 對 git 的
    # 子指令從來沒有驗過任何東西。一條看起來在跑、實際上什麼都沒比對的檢查，
    # 比沒有檢查更糟：它會讓人以為那個面向已經被守住了。
    words = []
    for _q, body in re.findall(r"""compgen -W (['"])(.*?)\1""", m.group(1), re.S):
        words += body.split()
    return set(words)


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
        # ⚠ 把「沒被檢查的是誰」印出來。原本只說「N 個不適用」，於是
        # 24 個動詞裡只有 6 個真的被驗過這件事是隱形的。
        # 2026-09-05 試過放寬判準（把 cx_error + return EX_USAGE 也算成「會拒絕」），
        # 結果對 deploy 的 --env/--key/--port/--user/--no-db/--no-web 與 test 的
        # --build/--filter 產生 8 個假警報 —— 那些旗標分別由 bin/lib/inventory.py
        # 與下游的 compose/phpunit 處理，本來就不該出現在該檔案裡。
        # 一條永遠紅燈的檢查等於沒有人會再看它，所以維持窄判準，但把缺口寫出來。
        row("PASS", "CLI-flags", "usage 宣傳的旗標 parser 都接受",
            f"{checked} 個旗標／{len(skipped) + len(skipped and [] or [])} 略過："
            f"{' '.join(sorted(skipped))}")


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
    ans = read_required("ansible/README.md", "DOC-ansible-run",
                        "ansible/README 的執行狀態與實測一致")
    if ans is None:
        ans = ""                    # 已經 row() 過 FAIL，後面的比對照跑不會誤判
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
    ref = read_required("docs/cx-reference.md", "DOC-cx-verbs", "cx-reference 涵蓋每個動詞")
    comp = completion_verbs()
    if ref is None:
        pass                        # read_required 已經 row() 過 FAIL
    elif not comp:
        row("SKIP", "DOC-cx-verbs", "cx-reference 涵蓋每個動詞", "剖析不到補全的 $verbs")
    else:
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

    # ── 作用群組名的三方一致 ──────────────────────────────────────────────
    # site.yml 的 hosts: ←→ deploy.sh 的 --list-hosts ←→ inventory.py 產生的群組。
    #
    # ⚠ 第三方（inventory.py）是 2026-09-06 才加進來的。在那之前這條檢查只比對
    #   前兩者，而 inventory.py 寫死 "pm_servers" 且 cx rename 的清單裡沒有它 ——
    #   於是 cx rename shop 之後前兩者變成 shop_servers、產生出來的 hosts.yml
    #   仍是 pm_servers，ansible 比對到 0 台主機卻只印 warning 並回 0。
    #   兩方一致不代表三方一致，而漏掉的那一方正是產生檔案的那一個。
    site = read("ansible/site.yml") or ""
    dep = read("bin/cmd/deploy.sh") or ""
    inv = read("bin/lib/inventory.py") or ""
    groups = set(re.findall(r"^\s*hosts:\s*(\S+)", site, re.M)) - {"localhost"}
    used = set(re.findall(r"--list-hosts\s+(\S+)", dep)) | set(re.findall(r"ansible\s+([a-z_]+_servers)", dep))
    # inventory.py 必須用 CX_PROJECT_NAME 推導，不可以是字面值。
    inv_literal = sorted(set(re.findall(r'["\']([a-z][a-z0-9_]*_servers)["\']', inv)))
    inv_derived = bool(re.search(r'SERVERS_GROUP\s*=\s*f?["\']\{?PROJECT\}?_servers', inv)) \
        or bool(re.search(r'SERVERS_GROUP\s*=\s*f["\']\{PROJECT\}_servers', inv))
    if not groups or not used:
        row("SKIP", "TPL-group", "site.yml／deploy.sh／inventory.py 的群組名一致",
            "抓不到群組名")
    elif groups != used:
        row("FAIL", "TPL-group", "site.yml／deploy.sh／inventory.py 的群組名一致",
            f"site.yml={sorted(groups)} vs deploy.sh={sorted(used)}"
            "（不一致時 cx deploy ping 會找不到任何主機，而且只印 warning 並回 0）")
    elif inv and not inv_derived:
        row("FAIL", "TPL-group", "site.yml／deploy.sh／inventory.py 的群組名一致",
            f"inventory.py 沒有從 CX_PROJECT_NAME 推導群組名"
            + (f"（寫死了 {' '.join(inv_literal)}）" if inv_literal else "")
            + " —— cx rename 不會改這個檔，改名後產生的 hosts.yml 會對不上 site.yml")
    else:
        row("PASS", "TPL-group", "site.yml／deploy.sh／inventory.py 的群組名一致",
            " ".join(sorted(groups)) + "；inventory.py 由 CX_PROJECT_NAME 推導")


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


def check_git_subcommands():
    """`cx git` 的子指令必須在四個地方一致。

    這一族今天就抓得到東西：help.sh 曾經同時漏掉 feature、config、remote-set。
    而且它是**新**檢查 —— subcommands_of 原本只吃雙引號的 compgen -W，
    git 那一塊用單引號，所以 git 的子指令從來沒有被任何檢查比對過。

    四個來源都從實際的東西推導，不另外手打第五份清單：
      dispatch   cmd_git_main 的 case 分支
      usage      _git_usage heredoc 的行首詞
      補全       bin/completion/cx.bash 的 git) 區塊
      help       bin/cmd/help.sh 的 `git <子指令>` 行
    """
    gs = read("bin/cmd/git.sh")
    if not gs:
        row("SKIP", "GIT-subs", "cx git 子指令四方一致", "讀不到 bin/cmd/git.sh")
        return

    # ⚠ 不可以用非貪婪抓到第一個 esac：guard) 那一臂裡面**還有一個** case…esac，
    #   於是它後面的 push / remote-init / remote-set / scan-secrets 全部被截掉，
    #   然後這條檢查會反過來說「usage 多了不存在的子指令」。
    #   改成抓整個函式本體，只認**恰好 8 個空白縮排**的臂（巢狀的那些更深）。
    m = re.search(r"cmd_git_main\(\)\s*\{\n(.*?)\n\}", gs, re.S)
    if not m:
        row("SKIP", "GIT-subs", "cx git 子指令四方一致", "剖析不到 cmd_git_main")
        return
    dispatch = set()
    for arm in re.findall(r"^ {8}([a-z|_-]+)\)", m.group(1), re.M):
        for a in arm.split("|"):
            if a and not a.startswith("-"):
                dispatch.add(a)

    um = re.search(r"_git_usage\(\)\s*\{.*?<<'TXT'\n(.*?)\nTXT", gs, re.S)
    usage = set()
    if um:
        for ln in um.group(1).splitlines():
            w = re.match(r"^  ([a-z][a-z-]*)", ln)
            if w:
                usage.add(w.group(1))

    # 補全只取**頂層**那一份（if [[ -z $sub ]] 底下的），不要把 branch/feature/
    # guard 的子項一起算進來 —— 那些是第二層，不是 cx git 的子指令。
    cb = read("bin/completion/cx.bash")
    gm = re.search(r"^\s{8}git\)\n\s*if \[\[ -z \$sub \]\]; then\n\s*COMPREPLY=\(\$\(compgen -W (['\"])(.*?)\1",
                   cb, re.S | re.M)
    comp = set(gm.group(2).split()) if gm else set()

    hs = read("bin/cmd/help.sh")
    helps = set(re.findall(r"^\s*git ([a-z][a-z-]*)", hs, re.M))

    problems = []
    # dispatch 是事實。其他三個都必須涵蓋它（可以多，因為補全會列 branch 的子項）
    for name, have in (("usage", usage), ("補全", comp), ("help", helps)):
        missing = sorted(d for d in dispatch if d not in have)
        if missing:
            problems.append(f"{name} 少了：{' '.join(missing)}")
    # 反向：不存在的子指令不可以出現在任何一份清單裡
    for name, have in (("usage", usage), ("補全", comp), ("help", helps)):
        extra = sorted(x for x in have if x not in dispatch)
        if extra:
            problems.append(f"{name} 多了不存在的：{' '.join(extra)}")

    if problems:
        row("FAIL", "GIT-subs", "cx git 子指令四方一致", "；".join(problems))
    else:
        row("PASS", "GIT-subs", "cx git 子指令四方一致", f"{len(dispatch)} 個子指令")


def check_git_branch_model():
    """`.cxroot` 的 CX_GIT_* 與程式碼裡的讀取端要雙向對得起來。

    兩個方向都會出事：
      定義了沒人讀 —— 使用者改了那一行，行為卻不變（fresh.sh 曾經寫死 -b main，
                      於是 CX_GIT_MAIN_BRANCH 只是裝飾）
      讀了沒定義   —— 靠 shell 的 :- 預設值默默跑掉，換一台機器才發現不一樣
    """
    cxroot = read(".cxroot")
    if not exists(".cxroot"):
        row("SKIP", "GIT-branch-model", "分支模型變數雙向一致", "沒有 .cxroot")
        return
    defined = set(re.findall(r"^(CX_GIT_[A-Z_]+)=", cxroot, re.M))

    used, required = set(), set()
    for f in sorted((ROOT / "bin/cmd").glob("*.sh")) + sorted((ROOT / "bin/lib").glob("*.sh")):
        txt = f.read_text(encoding="utf-8")
        used |= set(re.findall(r"\$\{?(CX_GIT_[A-Z_]+)", txt))
        # ⚠ 有沒有給預設值，語意完全不同：
        #   ${VAR:-x}  可選 —— 那正是「舊的 .cxroot 也要能跑」的相容機制
        #   $VAR       必要 —— 沒定義就會是空字串，行為靜默改變
        # 第一版把兩者一視同仁，於是任何**還沒加這些變數的既有專案**都會紅，
        # 而那是設計上要支援的狀態。一條對正常狀態報錯的檢查等於沒有檢查。
        for name in re.findall(r"\$\{(CX_GIT_[A-Z_]+)\}", txt):
            required.add(name)
        for name in re.findall(r"\$(CX_GIT_[A-Z_]+)\b", txt):
            required.add(name)

    orphan = sorted(defined - used)                 # 定義了沒人讀
    undef  = sorted(required - defined)             # 沒有預設值卻沒定義
    problems = []
    if orphan:
        problems.append(f".cxroot 定義了但沒有任何程式碼讀：{' '.join(orphan)}")
    if undef:
        problems.append(f"程式碼讀了（且沒給預設值）但 .cxroot 沒定義：{' '.join(undef)}")
    if problems:
        row("FAIL", "GIT-branch-model", "分支模型變數雙向一致", "；".join(problems))
    else:
        row("PASS", "GIT-branch-model", "分支模型變數雙向一致",
            (" ".join(sorted(defined)) or "（.cxroot 沒有 CX_GIT_*，程式碼走預設值）")
            + f"；讀取端 {len(used)} 個")


def check_ansible_split():
    """A15：migration 的 gate 與 deploy_backend 的 gate 必須是同一個群組。

    migration 寫在 deploy_backend role 內部，用
        when: inventory_hostname in groups['db_primary']
    gate（不是 run_once —— serial 之下 run_once 只在當前 batch 生效，等同 no-op）。
    而 deploy_backend 本身在 play 層有自己的 gate。

    兩者對不上的後果**沒有任何錯誤訊息**：ansible 全綠，網站停在
    "Base table or view not found"。preflight 的 A15 斷言就是為了擋這件事，
    但它自己也寫著一個群組名 —— 2026-09-06 把 web 拆成 web_frontend /
    web_backend 時，如果只改了 role 的 gate 而忘了改斷言，那條斷言會**通過**，
    然後 migration 一次都不跑。這條檢查盯的就是那個「忘了一起改」。
    """
    site = read("ansible/site.yml")
    if not site:
        row("SKIP", "ANS-split", "A15 斷言與 deploy_backend 的 gate 同群組", "讀不到 site.yml")
        return
    m = re.search(r"role:\s*deploy_backend\b.*?when:\s*inventory_hostname in \(groups\['(\w+)'\]",
                  site, re.S)
    a = re.search(r"groups\['db_primary'\][^\n]*?\|\s*difference\(groups\['(\w+)'\]", site, re.S)
    gate = m.group(1) if m else None
    asserted = a.group(1) if a else None
    if not gate or not asserted:
        row("SKIP", "ANS-split", "A15 斷言與 deploy_backend 的 gate 同群組",
            f"剖析不到（gate={gate or '無'} 斷言={asserted or '無'}）")
    elif gate != asserted:
        row("FAIL", "ANS-split", "A15 斷言與 deploy_backend 的 gate 同群組",
            f"deploy_backend 的 gate 是 groups['{gate}']，但 preflight 斷言的是 "
            f"groups['{asserted}'] —— 不一致時 migration 永遠不會執行，"
            "而且 ansible 會全綠")
    else:
        row("PASS", "ANS-split", "A15 斷言與 deploy_backend 的 gate 同群組", gate)


def check_doc_index():
    """宣稱是「完整清單」的文件索引，必須真的完整。

    claude.md 的 §9 與 docs/README.md 的表格都是索引。少一份文件不會壞掉任何
    東西 —— 它只是讓那份文件沒有人找得到，而這正是本專案已經發生過的事
    （三份角色指南寫完之後，claude.md 的清單裡一份都沒有）。
    """
    docs = sorted(p.name for p in (ROOT / "docs").glob("*.md"))
    if not docs:
        row("SKIP", "DOC-index", "文件索引涵蓋 docs/ 全部", "找不到 docs/*.md")
        return
    problems = []
    # ⚠ README.md 是 2026-09-06 才加進來的。在那之前這條檢查只看 claude.md 與
    #   docs/README.md，於是根 README 的文件表可以無聲漂走 —— 而它漂了：
    #   acceptance.md 與 docker-verification.md 兩份都不在裡面。
    #   索引檢查漏掉一份索引，等於那份索引不受任何約束。
    for src in ("claude.md", "docs/README.md", "README.md"):
        if not exists(src):
            continue
        txt = read(src)
        missing = [d for d in docs if d not in txt]
        if missing:
            problems.append(f"{src} 沒有提到：{' '.join(missing)}")
    if problems:
        row("FAIL", "DOC-index", "文件索引涵蓋 docs/ 全部", "；".join(problems))
    else:
        row("PASS", "DOC-index", "文件索引涵蓋 docs/ 全部", f"{len(docs)} 份都在索引裡")


def check_doc_filemap():
    """claude.md 的檔案地圖要對得上實際的 bin/cmd 與 bin/lib。

    地圖過期的症狀很輕微（沒有人會壞掉），但它是新人理解專案的第一張圖，
    而且它過期的時候看起來完全正常。實測 2026-09-05：地圖列 18 個 bin/cmd，
    實際有 24 個；bin/lib 的 .py 漏掉 4 個。
    """
    cm = read_required("claude.md", "DOC-filemap", "claude.md 的檔案地圖與實際相符")
    if cm is None:
        return                      # read_required 已經 row() 過 FAIL
    problems = []
    for d, pat in (("bin/cmd", "*.sh"), ("bin/lib", "*.py"), ("bin/lib", "*.sh")):
        real = sorted(p.stem for p in (ROOT / d).glob(pat))
        if not real:
            continue
        missing = [x for x in real if not re.search(r"\b%s\b" % re.escape(x), cm)]
        if missing:
            problems.append(f"{d}/{pat} 沒出現在地圖裡：{' '.join(missing)}")
    if problems:
        row("FAIL", "DOC-filemap", "claude.md 的檔案地圖與實際相符", "；".join(problems))
    else:
        row("PASS", "DOC-filemap", "claude.md 的檔案地圖與實際相符", "bin/cmd 與 bin/lib 全部有提到")


def check_doc_verify_scopes():
    """help.sh 宣傳的 verify 範圍，必須涵蓋 verify.sh 真的實作的每一個。

    docs/README.md 明寫「cx help 的輸出是動詞與參數的唯一權威」，
    所以 help 少寫一個範圍，等於那個範圍對使用者不存在。
    """
    vs = read("bin/cmd/verify.sh")
    hs = read("bin/cmd/help.sh")
    if not vs or not hs:
        row("SKIP", "DOC-verify-scopes", "help 的 verify 範圍涵蓋實作", "讀不到來源")
        return
    m = re.search(r"case \$1 in\n\s*([a-z|]+)\)", vs)
    scopes = set()
    for mm in re.finditer(r"^\s{12}([a-z|]+)\)\s*(?:scopes|SCOPES|_vf|;;)", vs, re.M):
        for a in mm.group(1).split("|"):
            scopes.add(a)
    # 保險：直接從 usage 的範圍行抓
    um = re.search(r"範圍[：:]\s*([a-z /|]+)", vs)
    if um:
        for a in re.split(r"[ /|]+", um.group(1)):
            if a:
                scopes.add(a)
    scopes -= {"", "all"}
    if not scopes:
        row("SKIP", "DOC-verify-scopes", "help 的 verify 範圍涵蓋實作", "剖析不到 verify.sh 的範圍")
        return
    # ⚠ 只能拿「範圍清單」那幾行當比對來源，不能拿整個 verify 說明區塊。
    #   區塊裡還有散文（例如「刻意不含 runtime / waf / acl」），那些字一樣是子字串，
    #   於是從清單裡拿掉 acl 之後檢查仍然通過 —— 反向測試當場抓到這件事。
    #   一條抓不到缺漏的檢查，比沒有檢查更糟：它會讓人以為這件事被守住了。
    hm = re.search(r"^  verify .*?(?=^  [a-z]|\Z)", hs, re.S | re.M)
    blk = hm.group(0) if hm else hs
    lm = re.search(r"範圍[：:]\s*\n(.*?)(?=^\s*不給範圍|^\s*（|\Z)", blk, re.S | re.M)
    hay = lm.group(1) if lm else blk
    missing = sorted(x for x in scopes if x not in hay)
    if missing:
        row("FAIL", "DOC-verify-scopes", "help 的 verify 範圍涵蓋實作",
            f"help.sh 少了：{' '.join(missing)}")
    else:
        row("PASS", "DOC-verify-scopes", "help 的 verify 範圍涵蓋實作",
            f"{len(scopes)} 個範圍")


def check_doc_test_count():
    """文件裡寫死的 bats 案例數必須與實際相符。

    這種數字每加一個案例就過期一次，而且過期得毫無徵兆。實測 2026-09-05：
    docs/progress.md 寫 66，實際 68；本輪之後是 89。
    只查「案例」附近的數字，不去猜文件裡每一個數字的意思。
    """
    real = 0
    for f in sorted((ROOT / "bin/test").glob("*.bats")):
        real += len(re.findall(r"^@test ", f.read_text(encoding="utf-8"), re.M))
    if real == 0:
        row("SKIP", "DOC-testcount", "文件寫的 bats 案例數與實際相符", "找不到 bats 檔")
        return
    bad = []
    for rel in ("claude.md", "README.md") + tuple(f"docs/{p.name}" for p in (ROOT / "docs").glob("*.md")):
        if not exists(rel):
            continue
        txt = read(rel)
        for mm in re.finditer(r"\*?\*?(\d{2,3})\s*個案例", txt):
            # ⚠ 只查「整套的總數」。文件裡也會寫**單一檔案**的案例數
            #（例如「bin/test/80_init.bats（12 個案例）」），那不是總數，
            # 拿總數去比它一定紅 —— 而一條必然紅的檢查等於沒有檢查。
            # 判準：往前看 60 個字元，出現具體的 <名字>.bats 就當成單檔計數。
            before = txt[max(0, mm.start() - 60):mm.start()]
            if re.search(r"\b\w+\.bats\b", before):
                continue
            if int(mm.group(1)) != real:
                bad.append(f"{rel}:{mm.group(1)}")
    if bad:
        row("FAIL", "DOC-testcount", "文件寫的 bats 案例數與實際相符",
            f"實際 {real}，但這些地方寫別的：{' '.join(sorted(set(bad)))}")
    else:
        row("PASS", "DOC-testcount", "文件寫的 bats 案例數與實際相符", f"{real} 個案例")


def check_pma_auth():
    """phpMyAdmin 不可以設 PMA_USER —— 那會把登入畫面整個關掉。

    官方 phpmyadmin 映像的 config.inc.php 只要看到 PMA_USER，就把
    $cfg['Servers'][$i]['auth_type'] 從 cookie 換成 config：登入表單消失，
    任何連得到那個埠的人都以那組帳密自動登入。而這裡填過的是 **root**。

    2026-09-05 實測：`curl http://127.0.0.1:8891/` 不帶任何 cookie，回的是
    140KB 的已登入頁（title 是 mysql、內文有 root@172.18.0.4 與 logout 連結），
    不是登入表單。docs/acceptance.md 的 M2「phpMyAdmin 真的能登入」當時只驗過
    HTTP 200 —— 而自動登入的頁面回的正好也是 200，所以那一項驗不到這件事。

    ${MYSQL_BIND:-127.0.0.1} 擋得住 LAN，擋不住 app_net 上的其他容器：
    nuxt / app 裡跑的 npm、composer 相依套件連得到 http://phpmyadmin/，
    而它們手上只有低權限的 DB_PASSWORD，本來拿不到 MYSQL_ROOT_PASSWORD。

    bin/cmd/pma.sh 一直是照「cookie 認證」寫的（它叫使用者去看 .env 的
    DB_USERNAME / DB_PASSWORD），所以這是設定與自己的說明不一致，不是取捨。
    """
    files = [f"docker/compose/{m}.yml" for m in ("dev", "test", "prod")]
    present = [f for f in files if exists(f)]
    if not present:
        row("SKIP", "SEC-pma-auth", "phpMyAdmin 保留登入認證", "找不到任何 compose overlay")
        return
    bad = []
    for f in present:
        for ln, line in enumerate(read(f).splitlines(), 1):
            # 只看設定行，不看註解 —— 註解裡正好寫著「不要設 PMA_USER」
            if re.match(r"\s*PMA_(USER|PASSWORD)\s*:", line):
                bad.append(f"{f}:{ln}")
    if bad:
        row("FAIL", "SEC-pma-auth", "phpMyAdmin 保留登入認證",
            "這些地方設了 PMA_USER／PMA_PASSWORD，會關掉登入表單：" + " ".join(bad))
    else:
        row("PASS", "SEC-pma-auth", "phpMyAdmin 保留登入認證",
            f"{len(present)} 份 overlay 都沒有 PMA_USER（cookie 認證）")


def check_log_dir_mode():
    """日誌目錄不可以對 web_group 可寫，而且三個 role 必須講同一個數字。

    /var/log/php 與 /var/log/<app> 裡都有「**root** 依路徑名開檔」的寫入者：
      * FPM master 以 open(O_CREAT|O_APPEND) 建 slowlog，沒有 O_NOFOLLOW
      * mysql 備份 cron 的 `>> ...`（user: root）
      * queue / schedule unit 的 StandardOutput=append:（systemd 在降權成
        User=www-data **之前**就開好 fd）

    群組是 www-data —— web 層被打穿之後攻擊者拿到的正是這個身分。目錄只要對它
    可寫，它就能 unlink 既有的 log，換上一個指向 /etc/cron.d/x 或
    /etc/ld.so.preload 的 symlink，讓 root 幫它建檔並寫進去。這與
    CVE-2016-1247（Debian nginx）是同一個原語。fs.protected_symlinks 擋不住，
    它只作用在 sticky 且 world-writable 的目錄。

    三個 role 建同一批目錄（common / php / nodejs_pm2），數字不一致的話會
    每次部署互相翻對方的 mode，永遠 changed —— 所以順便比對它們有沒有漂移。
    """
    srcs = {
        "common": ("ansible/roles/common/defaults/main.yml", r"^common_log_dir_mode:\s*\"?([0-7]{3,4})\"?"),
        "php": ("ansible/roles/php/defaults/main.yml", r"^php_log_dir_mode:\s*\"?([0-7]{3,4})\"?"),
    }
    modes = {}
    for name, (f, pat) in srcs.items():
        if not exists(f):
            row("SKIP", "SEC-logdir-mode", "日誌目錄不對 web 群組開放寫入", f"缺少 {f}")
            return
        m = re.search(pat, read(f), re.M)
        if not m:
            row("SKIP", "SEC-logdir-mode", "日誌目錄不對 web 群組開放寫入", f"{f} 讀不到 mode")
            return
        modes[name] = m.group(1)

    # nodejs_pm2 的 app_log_dir 是清單裡的一項，抓它自己那一段
    f = "ansible/roles/nodejs_pm2/tasks/pm2.yml"
    if exists(f):
        m = re.search(r'-\s*path:\s*"\{\{\s*app_log_dir\s*\}\}"\n(?:\s+\w+:.*\n)*?\s+mode:\s*"([0-7]{3,4})"',
                      read(f))
        if m:
            modes["nodejs_pm2"] = m.group(1)

    writable = {n: v for n, v in modes.items() if int(v, 8) & 0o020}
    if writable:
        row("FAIL", "SEC-logdir-mode", "日誌目錄不對 web 群組開放寫入",
            "群組可寫（root 會在這些目錄裡依路徑名開檔）："
            + " ".join(f"{n}={v}" for n, v in sorted(writable.items())))
        return
    distinct = sorted(set(modes.values()))
    if len(distinct) > 1:
        row("FAIL", "SEC-logdir-mode", "日誌目錄不對 web 群組開放寫入",
            "三個 role 的 mode 不一致，會每次部署互相翻："
            + " ".join(f"{n}={v}" for n, v in sorted(modes.items())))
    else:
        row("PASS", "SEC-logdir-mode", "日誌目錄不對 web 群組開放寫入",
            f"{' '.join(sorted(modes))} 都是 {distinct[0]}")


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
        check_pma_auth()
        check_log_dir_mode()
        check_git_subcommands()
        check_git_branch_model()
    if "tui" in families:
        check_tui()
    if "docs" in families:
        check_docs()
        check_ansible_split()
        check_doc_index()
        check_doc_filemap()
        check_doc_verify_scopes()
        check_doc_test_count()
    for st, ident, title, note in ROWS:
        print(f"{st}|{ident}|{title}|{note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
