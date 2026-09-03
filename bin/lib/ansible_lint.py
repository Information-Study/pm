#!/usr/bin/env python3
"""Ansible 靜態檢查（ansible 未安裝時的替代品）。

檢查項目：
  E1 YAML 無法剖析
  E2 紅線：git push
  E3 紅線：無 gate 的 rm -rf / DROP DATABASE / state=absent
  E4 command/shell 任務缺 changed_when
  E5 未使用 FQCN 的模組
  E6 引用了任何 group_vars/defaults 都沒定義的變數
  E7 Jinja2 大括號不成對
"""
import re, sys, pathlib, yaml

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'ansible')
RED, GRN, YLW, DIM, RST = '\033[31m', '\033[32m', '\033[33m', '\033[2m', '\033[0m'

errors, warns = [], []
def err(code, f, msg):  errors.append((code, f, msg))
def warn(code, f, msg): warns.append((code, f, msg))

yml_files = sorted(ROOT.rglob('*.yml')) + sorted(ROOT.rglob('*.yaml'))
j2_files  = sorted(ROOT.rglob('*.j2'))

# ── 收集已定義的變數 ──────────────────────────────────────────────
defined = set()
for f in yml_files:
    if not re.search(r'(defaults|vars|group_vars|host_vars)/', str(f)):
        continue
    try:
        d = yaml.safe_load(f.read_text()) or {}
        if isinstance(d, dict):
            defined |= set(d.keys())
    except Exception:
        pass

# ansible 內建與常見事實
BUILTIN = {
    'ansible_version','ansible_distribution','ansible_distribution_version',
    'ansible_distribution_release','ansible_os_family','ansible_processor_vcpus',
    'ansible_memtotal_mb','ansible_date_time','ansible_hostname','ansible_fqdn',
    'ansible_default_ipv4','ansible_env','ansible_user_id','ansible_python_interpreter',
    'inventory_hostname','groups','hostvars','play_hosts','item','ansible_loop',
    'lookup','role_path','playbook_dir','inventory_dir','omit','ansible_facts',
}

parsed = 0
for f in yml_files:
    rel = f.relative_to(ROOT.parent)
    try:
        docs = list(yaml.safe_load_all(f.read_text()))
        parsed += 1
    except yaml.YAMLError as e:
        err('E1', rel, f'YAML 剖析失敗：{str(e).splitlines()[0]}')
        continue

    text = f.read_text()

    # E2 紅線：git push
    for m in re.finditer(r'git\s+push', text):
        err('E2', rel, f'第 {text[:m.start()].count(chr(10))+1} 行出現 git push —— 違反紅線 1')

    # E3 紅線：無 gate 的破壞性操作
    for m in re.finditer(r'rm\s+-rf', text):
        ln = text[:m.start()].count('\n') + 1
        ctx = '\n'.join(text.splitlines()[max(0, ln-12):ln+3])
        if not re.search(r'when:|failed_when:|assert|\|\s*default\(', ctx):
            err('E3', rel, f'第 {ln} 行 rm -rf 附近沒有 when/assert gate')
    for m in re.finditer(r'DROP\s+DATABASE|state:\s*absent', text, re.I):
        ln = text[:m.start()].count('\n') + 1
        ctx = '\n'.join(text.splitlines()[max(0, ln-10):ln+6])
        if not re.search(r'when:', ctx):
            warn('E3', rel, f'第 {ln} 行破壞性操作附近沒有 when gate')

    # 逐一走訪 task
    def walk(node):
        if isinstance(node, list):
            for x in node: walk(x)
        elif isinstance(node, dict):
            keys = set(node.keys())
            mods = keys - {
                'name','when','tags','become','become_user','register','loop','with_items',
                'notify','changed_when','failed_when','vars','no_log','ignore_errors',
                'delegate_to','run_once','until','retries','delay','args','environment',
                'block','rescue','always','listen','check_mode','diff','any_errors_fatal',
                'loop_control','condition','set_fact','include_tasks','import_tasks',
            }
            for mod in mods:
                if not isinstance(mod, str):
                    continue
                # E4 command/shell 需要 changed_when
                if mod in ('command','shell','ansible.builtin.command','ansible.builtin.shell'):
                    if 'changed_when' not in keys and 'creates' not in str(node.get(mod, '')):
                        warn('E4', rel, f"任務「{node.get('name','(未命名)')}」用 {mod} 但沒有 changed_when")
                # E5 FQCN
                if mod in ('apt','copy','template','file','service','systemd','user','group',
                           'git','stat','find','lineinfile','uri','get_url','unarchive',
                           'command','shell','set_fact','assert','debug','cron','pip'):
                    warn('E5', rel, f"模組 {mod} 未使用 FQCN（建議 ansible.builtin.{mod}）")
            for k in ('block','rescue','always'):
                if k in node: walk(node[k])
        return
    for d in docs:
        if isinstance(d, list):
            for play in d:
                if isinstance(play, dict):
                    for sec in ('pre_tasks','tasks','post_tasks','handlers'):
                        if sec in play: walk(play[sec])
                    if 'roles' in play: pass
        walk(d)

# ── E6 變數引用 ────────────────────────────────────────────────────
used = set()
VAR_RE = re.compile(r'\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*)')
for f in yml_files + j2_files:
    for m in VAR_RE.finditer(f.read_text()):
        used.add(m.group(1))
FILTERS = {'true','false','none','not','and','or','if','else','endif','for','endfor','in','is'}
undef = sorted(v for v in used - defined - BUILTIN - FILTERS if not v.startswith('_'))
for v in undef:
    warn('E6', pathlib.Path('(多處)'), f'變數 {v} 在 defaults/group_vars 中找不到定義')

# ── E7 Jinja2 括號 ─────────────────────────────────────────────────
for f in yml_files + j2_files:
    t = f.read_text()
    if t.count('{{') != t.count('}}'):
        err('E7', f.relative_to(ROOT.parent), f'Jinja2 括號不成對（{{{{ ×{t.count("{{")}, }}}} ×{t.count("}}")}）')

# ── 輸出 ───────────────────────────────────────────────────────────
print(f'\n{DIM}掃描 {len(yml_files)} 個 YAML、{len(j2_files)} 個 Jinja2 模板，成功剖析 {parsed}{RST}')
if errors:
    print(f'\n{RED}錯誤 {len(errors)}{RST}')
    for c, f, m in errors: print(f'  {RED}{c}{RST} {f}: {m}')
if warns:
    from collections import Counter
    cnt = Counter(c for c, _, _ in warns)
    print(f'\n{YLW}警告 {len(warns)}{RST} （{", ".join(f"{k}×{v}" for k, v in sorted(cnt.items()))}）')
    for c, f, m in warns[:40]: print(f'  {YLW}{c}{RST} {f}: {m}')
    if len(warns) > 40: print(f'  {DIM}… 另有 {len(warns)-40} 筆{RST}')
if not errors and not warns:
    print(f'\n{GRN}✔ 靜態檢查全數通過{RST}')
print(f'\n{DIM}提醒：這不等於 ansible-playbook --syntax-check。'
      f'ansible 可用後請跑真正的檢查。{RST}')
sys.exit(1 if errors else 0)
