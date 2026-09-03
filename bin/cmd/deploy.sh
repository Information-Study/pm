#!/usr/bin/env bash
# cx deploy —— Ansible 原生部署（Phase 5）。
#
# 這是 cx 的第三個階段：開發（dev 容器）→ 測試（test 容器 + 四道防線）→ 部署（本檔）。
#
# 所有動作都在 $CX_ROOT/ansible 底下執行 —— ansible.cfg 的 roles_path /
# inventory / collections_path 都是相對路徑，從別的目錄跑會全部找不到。
#
# 安全預設：
#   * 預設是 --check --diff（乾跑）。真的要動機器必須明確打 apply。
#   * apply 一定會先確認，並列出目標主機。
#   * 任何 rollback / prune 都走 playbook 自己的 gate，cx 不繞過。

_deploy_usage() {
    cat >&2 <<'TXT'
cx deploy <子指令> [參數...]

靜態檢查（不需要目標主機）
  syntax            ansible-playbook --syntax-check（三個 playbook 全跑）
  lint              ansible-lint（production profile）+ yamllint
  check [限制]      --check --diff 乾跑，預設 --limit staging

連線
  ping [限制]       ansible -m ping，確認 SSH 與 become 可用
  facts <主機>      印出目標主機的 facts（除錯用）

實際部署
  apply [限制]      真的執行 site.yml（會要求確認）
  app [限制]        只跑應用層（playbooks/deploy-only.yml，不碰系統層）
  rollback [限制]   playbooks/rollback.yml（互動式，需輸入 yes）

其他
  galaxy            安裝 requirements.yml 的 collections
  vars              印出合併後的變數（--limit 的第一台主機）

範例
  cx deploy syntax
  cx deploy lint
  cx deploy check staging
  cx deploy apply staging
  cx deploy app production
  cx deploy rollback staging

⚠ inventory/hosts.yml 不進版控（.gitignore）。第一次使用：
    cp ansible/inventory/hosts.yml.example ansible/inventory/hosts.yml
    cp ansible/inventory/group_vars/staging.yml.example ansible/inventory/group_vars/staging.yml
  然後填 app_domain、certbot_email，並用 ansible-vault 建立 vault.yml。
  完整步驟見 ansible/README.md。
TXT
}

_deploy_need_ansible() {
    cx_have ansible-playbook && return 0
    cx_error "找不到 ansible-playbook"
    cx_dim "  安裝：cx setup tools ansible"
    cx_dim "  （會裝進 ~/.local/share/cx-venv，免 root）"
    exit "$EX_PRECOND"
}

# ansible.cfg 裡的 inventory 指向 inventory/hosts.yml，那個檔不進版控。
# 靜態檢查（syntax / lint）本身不需要真的 inventory，但 ansible 沒有 inventory
# 會直接 [ERROR]: No inventory was parsed 然後結束。
#
# 不能直接把 hosts.yml.example 當 inventory：ansible 用「副檔名」挑解析器，
#   .example → 走 ini plugin → "Invalid host pattern '---'"
# 所以要複製成一個叫 hosts.yml 的暫存檔。
_deploy_stub_inventory() {
    local d
    d=$(mktemp -d) || return 1
    if [[ -f $CX_ROOT/ansible/inventory/hosts.yml ]]; then
        cp "$CX_ROOT/ansible/inventory/hosts.yml" "$d/hosts.yml"
    elif [[ -f $CX_ROOT/ansible/inventory/hosts.yml.example ]]; then
        cp "$CX_ROOT/ansible/inventory/hosts.yml.example" "$d/hosts.yml"
    else
        rm -rf "$d"
        return 1
    fi
    printf '%s\n' "$d"
}

_deploy_real_inventory() {
    [[ -f $CX_ROOT/ansible/inventory/hosts.yml ]] && return 0
    cx_error "缺少 ansible/inventory/hosts.yml"
    cx_dim "  cp ansible/inventory/hosts.yml.example ansible/inventory/hosts.yml"
    cx_dim "  然後填入真實主機。這個檔刻意不進版控（含主機位址與帳號）。"
    exit "$EX_PRECOND"
}

CX_DEPLOY_PLAYBOOKS='site.yml playbooks/deploy-only.yml playbooks/rollback.yml'

_deploy_syntax() {
    _deploy_need_ansible
    local d rc=0 pb
    d=$(_deploy_stub_inventory) || cx_die "$EX_PRECOND" "找不到任何 inventory（連 .example 都沒有）"
    cx_step "ansible-playbook --syntax-check"
    for pb in $CX_DEPLOY_PLAYBOOKS; do
        if ( cd "$CX_ROOT/ansible" && ANSIBLE_DEPRECATION_WARNINGS=False \
             cx_run ansible-playbook "$pb" --syntax-check -i "$d/hosts.yml" >/dev/null ); then
            cx_ok "$pb"
        else
            cx_error "$pb"
            rc=1
        fi
    done
    rm -rf "$d"
    (( rc )) && cx_dim "  重跑並看完整錯誤：cd ansible && ansible-playbook site.yml --syntax-check -i inventory/hosts.yml"
    return "$rc"
}

_deploy_lint() {
    local d rc=0
    d=$(_deploy_stub_inventory) || cx_die "$EX_PRECOND" "找不到任何 inventory"

    if cx_have ansible-lint; then
        cx_step "ansible-lint（設定：ansible/.ansible-lint，profile=production）"
        if ( cd "$CX_ROOT/ansible" && ANSIBLE_INVENTORY="$d/hosts.yml" \
             ANSIBLE_DEPRECATION_WARNINGS=False cx_run ansible-lint --nocolor ); then
            cx_ok "ansible-lint 無 finding"
        else
            cx_error "ansible-lint 有 finding"
            rc=1
        fi
    else
        cx_warn "沒有 ansible-lint —— 改跑 bin/lib/ansible_lint.py 的替代檢查"
        cx_dim "  安裝真正的：cx setup tools ansible"
        rm -rf "$d"
        cmd_lint_main 2>/dev/null || {
            # lint.sh 尚未被 source 進來時自己載一次
            # shellcheck source=/dev/null
            . "$CX_ROOT/bin/cmd/lint.sh"
            cmd_lint_main
        }
        return
    fi

    if cx_have yamllint; then
        cx_step "yamllint（設定：ansible/.yamllint）"
        if ( cd "$CX_ROOT/ansible" && cx_run yamllint . ); then
            cx_ok "yamllint 無 finding"
        else
            cx_error "yamllint 有 finding"
            rc=1
        fi
    fi
    rm -rf "$d"
    return "$rc"
}

_deploy_galaxy() {
    _deploy_need_ansible
    cx_need ansible-galaxy
    cx_step "安裝 collections（ansible/requirements.yml）"
    ( cd "$CX_ROOT/ansible" && cx_run ansible-galaxy collection install -r requirements.yml )
}

# 把 [限制] 轉成 --limit 參數。空的就不加（等於全部主機，apply 時會特別警告）。
_deploy_limit_args() {
    [[ -n ${1:-} ]] && printf -- '--limit\n%s\n' "$1"
}

_deploy_hosts_preview() {
    local limit=$1
    ( cd "$CX_ROOT/ansible" && ansible ${limit:+--limit "$limit"} \
        --list-hosts pm_servers 2>/dev/null | tail -n +2 | tr -d ' ' | tr '\n' ' ' )
}

_deploy_ping() {
    _deploy_need_ansible
    _deploy_real_inventory
    local limit=${1:-}
    cx_step "ansible -m ping${limit:+（--limit $limit）}"
    ( cd "$CX_ROOT/ansible" && cx_run ansible pm_servers ${limit:+--limit "$limit"} -m ping )
}

_deploy_facts() {
    _deploy_need_ansible
    _deploy_real_inventory
    [[ -n ${1:-} ]] || cx_die "$EX_USAGE" "cx deploy facts 需要主機名稱"
    ( cd "$CX_ROOT/ansible" && cx_run ansible "$1" -m setup )
}

_deploy_vars() {
    _deploy_need_ansible
    _deploy_real_inventory
    local limit=${1:-staging}
    ( cd "$CX_ROOT/ansible" && cx_run ansible-inventory --list --yaml --limit "$limit" )
}

_deploy_check() {
    _deploy_need_ansible
    _deploy_real_inventory
    local limit=${1:-staging}
    cx_step "site.yml --check --diff --limit $limit（乾跑，不改任何東西）"
    cx_dim "  --check 不是萬能：command/shell 在 check 模式會被 skip，"
    cx_dim "  所以「乾跑通過」不等於「實際跑一定會過」。"
    ( cd "$CX_ROOT/ansible" && cx_run ansible-playbook site.yml --check --diff --limit "$limit" )
}

_deploy_apply() {
    _deploy_need_ansible
    _deploy_real_inventory
    local limit=${1:-} pb=${2:-site.yml} hosts
    hosts=$(_deploy_hosts_preview "$limit")

    if [[ -z $limit ]]; then
        cx_warn "沒有指定限制範圍 —— 會對 inventory 裡的**所有**主機執行"
    fi
    [[ -n $hosts ]] || cx_die "$EX_PRECOND" "解析不出任何目標主機（--limit ${limit:-<無>}）"

    cx_confirm --danger "在真實主機上執行 $pb" \
"playbook：$pb
限制    ：${limit:-<全部>}
目標主機：$hosts

這會實際修改上列主機：安裝套件、改系統設定、部署程式碼、可能執行資料庫 migration。

先跑過 cx deploy check ${limit:-staging} 了嗎？

確定要繼續？" || return "$EX_ABORT"

    cx_step "$pb${limit:+ --limit $limit}"
    ( cd "$CX_ROOT/ansible" && cx_run ansible-playbook "$pb" ${limit:+--limit "$limit"} )
}

_deploy_rollback() {
    _deploy_need_ansible
    _deploy_real_inventory
    local limit=${1:-}
    cx_step "playbooks/rollback.yml${limit:+ --limit $limit}"
    cx_dim "  rollback.yml 自己有四道 gate 與一個「輸入 yes」的確認，cx 不繞過它們。"
    cx_dim "  不給 rollback_to 時它只列出可用的 release，不做任何事。"
    ( cd "$CX_ROOT/ansible" && cx_run ansible-playbook playbooks/rollback.yml \
        ${limit:+--limit "$limit"} "${@:2}" )
}

cmd_deploy_main() {
    local sub=${1:-}
    [[ $# -gt 0 ]] && shift
    case $sub in
        ''|-h|--help|help) _deploy_usage ;;
        syntax)   _deploy_syntax ;;
        lint)     _deploy_lint ;;
        galaxy)   _deploy_galaxy ;;
        ping)     _deploy_ping "${1:-}" ;;
        facts)    _deploy_facts "${1:-}" ;;
        vars)     _deploy_vars "${1:-}" ;;
        check)    _deploy_check "${1:-staging}" ;;
        apply)    cx_lock deploy; _deploy_apply "${1:-}" site.yml ;;
        app)      cx_lock deploy; _deploy_apply "${1:-}" playbooks/deploy-only.yml ;;
        rollback) cx_lock deploy; _deploy_rollback "$@" ;;
        *) cx_error "未知的子指令：$sub"; _deploy_usage; return "$EX_USAGE" ;;
    esac
}
