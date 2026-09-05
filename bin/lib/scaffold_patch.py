#!/usr/bin/env python3
"""把「範本自己擁有的東西」裝回剛產生的骨架上。

為什麼需要這支程式：
`composer create-project` 與 `nuxi init` 產生的是**框架的**骨架，裡面當然
沒有本專案加上去的保護。於是 `cx fresh` / `cx init` 跑完之後，新專案會少掉：

  * 測試資料庫的應用層 hard guard（tests/bootstrap.php + DatabaseSafetyGuard.php
    + phpunit.xml 的 bootstrap= 那一行 + TestCase 的 createApplication 覆寫）
  * 前端的 ESLint 基線（eslint.config.mjs + 兩個 devDependency
    + nuxt.config 的 modules）

2026-09-05 實測：`cx init shop` 產出的專案，`cx verify cli` 有 9 個 FAIL，
其中 6 個正是上面這兩組。而 GRD-wire 這個檢查的說明裡早就寫過同一件事會發生
—— 只是當時說的是 carryover，實際上 scaffold 更嚴重（連檔案都沒有）。

⚠ 每一個動作都必須是**冪等**的。fresh 可以重跑，init 也可以，
   而「重跑一次就多一份 devDependency / 多一行 import」是很難查的那種壞法。
"""
import argparse
import json
import os
import re
import shutil
import sys

# 前端要確保存在的 devDependency（版本與 templates/frontend 保持一致）
FRONTEND_DEV_DEPS = {
    "@nuxt/eslint": "1.17.0",
    "eslint": "10.10.0",
}


def _same(a, b):
    try:
        with open(a, "rb") as fa, open(b, "rb") as fb:
            return fa.read() == fb.read()
    except OSError:
        return False


def log(msg):
    print(f"    {msg}", file=sys.stderr)


# ── backend ──────────────────────────────────────────────────────────────────
def patch_backend(root, tpl):
    """裝回測試防護的四個零件。"""
    changed = 0
    be = os.path.join(root, "backend")
    if not os.path.isdir(be):
        log("沒有 backend/，略過")
        return 0

    src_tests = os.path.join(tpl, "backend", "tests")
    dst_tests = os.path.join(be, "tests")
    os.makedirs(dst_tests, exist_ok=True)
    for name in ("bootstrap.php", "DatabaseSafetyGuard.php", "TestCase.php"):
        src = os.path.join(src_tests, name)
        if not os.path.exists(src):
            continue
        dst = os.path.join(dst_tests, name)
        # TestCase.php 若已經含有 assertResolvedConfig 就不覆蓋 ——
        # carryover 會把使用者自己的 TestCase 疊回來，那份可能有他的東西。
        if name == "TestCase.php" and os.path.exists(dst):
            with open(dst, encoding="utf-8") as fh:
                if "assertResolvedConfig" in fh.read():
                    continue
        # 內容一樣就不要動，也不要回報「有變更」——
        # 冪等不只是「重跑不會壞」，還包括「重跑不會謊報自己做了事」。
        if os.path.exists(dst) and _same(src, dst):
            continue
        shutil.copyfile(src, dst)
        log(f"裝回 backend/tests/{name}")
        changed += 1

    # phpunit.xml 的 bootstrap= 必須指向 tests/bootstrap.php。
    # 這是整組保護裡**最重要**的一行：檔案都在但沒有人呼叫它，
    # 看起來有防護、實際上沒有（GRD-wire 就是在守這件事）。
    px = os.path.join(be, "phpunit.xml")
    if os.path.exists(px):
        with open(px, encoding="utf-8") as fh:
            txt = fh.read()
        new = re.sub(r'bootstrap="[^"]*"', 'bootstrap="tests/bootstrap.php"', txt, count=1)
        if new != txt:
            with open(px, "w", encoding="utf-8") as fh:
                fh.write(new)
            log('phpunit.xml：bootstrap="tests/bootstrap.php"')
            changed += 1
    else:
        log("⚠ 沒有 backend/phpunit.xml —— 測試防護不會被呼叫到")
    return changed


# ── frontend ─────────────────────────────────────────────────────────────────
def patch_frontend(root, tpl):
    """裝回 ESLint 基線的三個零件。"""
    changed = 0
    fe = os.path.join(root, "frontend")
    if not os.path.isdir(fe):
        log("沒有 frontend/，略過")
        return 0

    src = os.path.join(tpl, "frontend", "eslint.config.mjs")
    dst = os.path.join(fe, "eslint.config.mjs")
    if os.path.exists(src) and not os.path.exists(dst):
        shutil.copyfile(src, dst)
        log("裝回 frontend/eslint.config.mjs")
        changed += 1

    # package.json 的 devDependencies
    pj = os.path.join(fe, "package.json")
    if os.path.exists(pj):
        with open(pj, encoding="utf-8") as fh:
            try:
                doc = json.load(fh)
            except ValueError:
                log("⚠ package.json 不是合法 JSON —— 略過")
                doc = None
        if doc is not None:
            dev = doc.setdefault("devDependencies", {})
            # 原本寫 `dev.get(k) != v and k not in dev` —— 第二個條件涵蓋第一個
            #（不在 dev 裡時 dev.get(k) 必為 None，永遠不等於 v），所以版本比對
            # 是死碼。後果是「已經有但版本不同」會被安靜略過，而工具還回報
            #「已經是最新狀態，沒有變更」—— 對一個不成立的狀態下了斷言。
            added = [k for k in FRONTEND_DEV_DEPS if k not in dev]
            mismatch = [(k, dev[k], v) for k, v in FRONTEND_DEV_DEPS.items()
                        if k in dev and dev[k] != v]
            for k, v in FRONTEND_DEV_DEPS.items():
                dev.setdefault(k, v)
            for k, have, want in mismatch:
                # 不覆蓋使用者釘的版本，但也不要假裝沒看到
                log(f"⚠ package.json 的 {k} 是 {have}，範本預期 {want}（保留你的版本）")
            if added:
                # 保持 key 排序，diff 才穩定
                doc["devDependencies"] = dict(sorted(dev.items()))
                with open(pj, "w", encoding="utf-8") as fh:
                    json.dump(doc, fh, indent=2, ensure_ascii=False)
                    fh.write("\n")
                log(f"package.json devDependencies += {', '.join(added)}")
                changed += 1

    # nuxt.config 的 modules 要含 '@nuxt/eslint'
    nc = next((os.path.join(fe, n) for n in
               ("nuxt.config.ts", "nuxt.config.js", "nuxt.config.mjs")
               if os.path.exists(os.path.join(fe, n))), None)
    if nc:
        with open(nc, encoding="utf-8") as fh:
            txt = fh.read()
        if "@nuxt/eslint" not in txt:
            if re.search(r"modules\s*:\s*\[", txt):
                txt2 = re.sub(r"(modules\s*:\s*\[)", r"\1\n        '@nuxt/eslint',", txt, count=1)
            else:
                # 沒有 modules 就在 defineNuxtConfig({ 後面插一個
                txt2 = re.sub(r"(defineNuxtConfig\(\{)",
                              r"\1\n    modules: ['@nuxt/eslint'],", txt, count=1)
            if txt2 != txt:
                with open(nc, "w", encoding="utf-8") as fh:
                    fh.write(txt2)
                log(f"{os.path.basename(nc)}：modules += '@nuxt/eslint'")
                changed += 1
            else:
                log("⚠ 看不懂 nuxt.config 的結構 —— 請自己加 '@nuxt/eslint' 到 modules")
    return changed


def main():
    ap = argparse.ArgumentParser(prog="scaffold_patch.py")
    ap.add_argument("--root", required=True, help="CX_ROOT")
    ap.add_argument("--templates", help="範本目錄（預設 <root>/templates）")
    ap.add_argument("--only", choices=("backend", "frontend"))
    a = ap.parse_args()
    tpl = a.templates or os.path.join(a.root, "templates")
    if not os.path.isdir(tpl):
        print(f"找不到範本目錄：{tpl}", file=sys.stderr)
        return 3
    n = 0
    if a.only in (None, "backend"):
        n += patch_backend(a.root, tpl)
    if a.only in (None, "frontend"):
        n += patch_frontend(a.root, tpl)
    log(f"共套用 {n} 項" if n else "已經是最新狀態，沒有變更")
    return 0


if __name__ == "__main__":
    sys.exit(main())
