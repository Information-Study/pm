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
  hosts <子指令>    主機清單（ansible/inventory/hosts.yml，不進版控）
      init          建立空的 hosts.yml
      add <名稱> --ip <IP> [--user u] [--port n] [--key 路徑]
                    [--env staging|production] [--no-web] [--db|--no-db]
      rm <名稱>     移除一台
      show          列出目前的主機與群組
      check         驗證結構與 A15（可加 --ansible 讓 ansible 自己也剖析一次）
      edit          用編輯器直接開（不經過產生器，註解會保留）
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
    if [[ ! -f $CX_ROOT/ansible/inventory/hosts.yml ]]; then
        cx_error "缺少 ansible/inventory/hosts.yml"
        cx_dim "  cp ansible/inventory/hosts.yml.example ansible/inventory/hosts.yml"
        cx_dim "  然後填入真實主機。這個檔刻意不進版控（含主機位址與帳號）。"
        exit "$EX_PRECOND"
    fi
    _deploy_check_hostkeys
}

# host key 變了的話，ansible 只會把 ssh 的那一大段 MITM 警告原樣丟出來：
#
#   @@@@@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@@@@@
#   IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
#   … Host key verification failed.
#
# 而且是包在 ansible 的 UNREACHABLE! => {"msg": "…"} JSON 裡、帶著 \r\n，
# 幾乎不可能一眼看懂 —— 但真正的原因通常很平凡：目標主機被重建了。
# 換本機驗證容器的 Ubuntu 版本（docker/ansible-target/README.md 的流程）
# 每一次都會踩到。
#
# ansible.cfg 的 host_key_checking = True 是刻意保留的
#（見 docs/ansible-reference.md §2），所以正確做法不是關掉檢查，
# 而是在跑之前就講清楚並給出那一行修法。
_deploy_check_hostkeys() {
    cx_have ssh-keygen && cx_have ssh-keyscan || return 0   # 沒工具就跳過，不是錯誤
    [[ -f $HOME/.ssh/known_hosts ]] || return 0             # 沒記錄過就沒得比

    local inv="$CX_ROOT/ansible/inventory/hosts.yml"
    local -a bad=()
    local host='' port='' line stored scanned

    # 只處理 inventory 裡明寫 ansible_host + ansible_port 的項目。
    # 靠 DNS 名稱連的主機沒有固定 port 可掃，換 key 的機率也低，交給 ssh 自己報。
    while IFS= read -r line; do
        case $line in
            *ansible_host:*) host=${line#*ansible_host:}; host=${host//[[:space:]]/}; port='' ;;
            *ansible_port:*) port=${line#*ansible_port:}; port=${port//[[:space:]]/} ;;
        esac
        [[ -n $host && -n $port ]] || continue

        stored=$(ssh-keygen -F "[$host]:$port" -f "$HOME/.ssh/known_hosts" 2>/dev/null \
                 | grep -v '^#' | awk '{print $3}' | head -1)
        if [[ -n $stored ]]; then
            scanned=$(ssh-keyscan -T 5 -p "$port" "$host" 2>/dev/null \
                      | grep -v '^#' | awk '{print $3}')
            # 掃不到（主機沒起來）就不要誤報 —— 讓 ansible 去說「連不上」，
            # 那個訊息本來就清楚。只有「掃得到、但沒有一把對得上」才是真的換了 key。
            if [[ -n $scanned ]] && ! grep -Fxq "$stored" <<< "$scanned"; then
                bad+=("$host $port")
            fi
        fi
        host=''; port=''
    done < "$inv"

    (( ${#bad[@]} == 0 )) && return 0

    cx_error "known_hosts 裡的主機金鑰與目標現在的不符"
    local b h p
    for b in "${bad[@]}"; do
        read -r h p <<< "$b"; cx_dim "  [$h]:$p"
    done
    cx_dim ""
    cx_dim "  最常見的原因不是攻擊，而是**目標主機被重建了** ——"
    cx_dim "  例如換了本機驗證容器的 Ubuntu 版本（見 docker/ansible-target/README.md）。"
    cx_dim "  ansible.cfg 的 host_key_checking = True 是刻意保留的，所以要你手動確認："
    cx_dim ""
    for b in "${bad[@]}"; do
        read -r h p <<< "$b"; cx_dim "      ssh-keygen -R '[$h]:$p'"
    done
    cx_dim ""
    cx_dim "  確定那台真的是你自己的機器再執行。不是預期中的變更就先查清楚。"
    exit "$EX_PRECOND"
}

CX_DEPLOY_PLAYBOOKS='site.yml playbooks/deploy-only.yml playbooks/rollback.yml'

# requirements.yml 列的 collection 是否都裝了。
#
# 全新 clone 上一定沒有：ansible/collections/ 被 .gitignore 排除
#（那是 ansible-galaxy 下載的上游程式碼，不該進版控）。
# 沒有它的話 --syntax-check 會失敗在
#   [ERROR]: couldn't resolve module/action 'community.general.timezone'
# 那個訊息不會告訴你「跑 ansible-galaxy install」，所以要自己講。
#
# ⚠ 不能用 `ansible-galaxy collection list <名稱>` 的退出碼判斷 ——
#   實測即使 collection 不存在它也回 0。必須解析完整清單的輸出。
_deploy_collections_ok() {
    cx_have ansible-galaxy || return 1
    local installed missing=() name
    installed=$( cd "$CX_ROOT/ansible" && ansible-galaxy collection list 2>/dev/null \
                 | awk '/^[a-z0-9_]+\./ {print $1}' )
    while read -r name; do
        [[ -z $name ]] && continue
        printf '%s\n' "$installed" | grep -qx "$name" || missing+=("$name")
    done < <(awk '/^[[:space:]]*- name:/ {print $3}' "$CX_ROOT/ansible/requirements.yml" 2>/dev/null)

    (( ${#missing[@]} == 0 )) && return 0
    cx_error "缺少 collection：${missing[*]}"
    cx_dim "  安裝：cx deploy galaxy"
    cx_dim "  （ansible/collections/ 不進版控，全新 clone 上一定要先裝一次）"
    return 1
}

_deploy_syntax() {
    _deploy_need_ansible
    local d rc=0 pb
    d=$(_deploy_stub_inventory) || cx_die "$EX_PRECOND" "找不到任何 inventory（連 .example 都沒有）"
    _deploy_collections_ok || return "$EX_PRECOND"
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
        _deploy_collections_ok || return "$EX_PRECOND"
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
    local limit=${1:-}; shift || true
    cx_step "ansible -m ping${limit:+（--limit $limit）}"
    (( $# )) && cx_dim "  額外參數：$*"
    ( cd "$CX_ROOT/ansible" \
      && cx_run ansible pm_servers ${limit:+--limit "$limit"} -m ping "$@" )
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
    local limit=${1:-staging}; shift || true
    cx_step "site.yml --check --diff --limit $limit（乾跑，不改任何東西）"
    cx_dim "  --check 不是萬能：會寫入的 command/shell 在 check 模式會被 skip，"
    cx_dim "  所以「乾跑通過」不等於「實際跑一定會過」。"
    cx_dim "  （唯讀的探測已標 check_mode: false，會真的執行 —— 否則 register"
    cx_dim "    出來的變數是空的，assert 會報出指向錯誤方向的訊息。）"
    (( $# )) && cx_dim "  額外參數：$*"
    ( cd "$CX_ROOT/ansible" \
      && cx_run ansible-playbook site.yml --check --diff --limit "$limit" "$@" )
}

_deploy_apply() {
    _deploy_need_ansible
    _deploy_real_inventory
    local limit=${1:-} pb=${2:-site.yml} hosts
    # 第 3 個之後的參數原樣轉給 ansible-playbook（-e / --tags / --skip-tags …）。
    # 原本直接丟掉 —— `cx deploy check staging -e php_repo_source=distro` 會安靜地
    # 用預設值跑完，看起來像「指定沒生效」，其實是參數根本沒被傳下去。
    local -a extra=("${@:3}")
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
    ( cd "$CX_ROOT/ansible" && cx_run ansible-playbook "$pb" ${limit:+--limit "$limit"} "${extra[@]}" )
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

# [限制] 是 --limit 的值，不是旗標。cx 的全域旗標（--yes / --dry-run / --mode）
# 必須放在動詞「之前」，寫成 cx deploy apply --yes 會讓 --yes 被當成主機樣式，
# 而 ansible 對「比對不到任何主機」只印 warning、退出碼 0 ——
# 於是 apply 會安靜地什麼都不做卻回報成功。這裡直接擋下來。
_deploy_reject_flag() {
    [[ ${1:-} == -* ]] || return 0
    cx_error "「$1」看起來是旗標，不是主機樣式"
    cx_dim "  全域旗標要放在動詞之前：cx --yes deploy ${_CX_DEPLOY_SUB:-apply}"
    exit "$EX_USAGE"
}

# ── 主機清單 ────────────────────────────────────────────────────────────────
#
# hosts.yml 是 cx deploy 每一個動詞都需要、卻是**唯一沒有工具幫忙產生**的檔案。
# 原本從選單走到部署那一步會撞牆，訊息只說「缺少 ansible/inventory/hosts.yml」，
# 然後叫人離開 cx 自己去 cp 範例檔。
#
# 群組模型（來源：ansible/site.yml 的 roles 區塊）與可拆分的邊界寫在
# docs/ansible-reference.md；產生與驗證的邏輯在 bin/lib/inventory.py。
_deploy_hosts() {
    local sub=${1:-show}; shift || true
    local inv="$CX_ROOT/ansible/inventory/hosts.yml"
    local py="$CX_ROOT/bin/lib/inventory.py"

    case $sub in
        -h|--help) _deploy_usage; return 0 ;;
        edit)
            [[ -f $inv ]] || { cx_error "還沒有 $inv"; cx_dim "  先跑： cx deploy hosts init"; return "$EX_PRECOND"; }
            # 走編輯器這條路不經過產生器，所以手寫的註解會保留
            if cx_have code && [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-}${WSL_DISTRO_NAME:-} ]]; then
                cx_run code --wait "$inv"
            else
                cx_run "${EDITOR:-${VISUAL:-vi}}" "$inv"
            fi
            cx_info "存檔後驗證一次："
            cx_run python3 "$py" --path "$inv" check --ansible ;;
        show|check)
            # 唯讀查詢不要包 cx_run —— 它在 --dry-run 之下不執行，
            # 於是 `cx --dry-run deploy hosts show` 會什麼都不印。
            # 想在動手之前先看狀態的人，正是最可能加 --dry-run 的人。
            python3 "$py" --path "$inv" "$sub" "$@" ;;
        init|add|rm)
            cx_run python3 "$py" --path "$inv" "$sub" "$@" ;;
        *) cx_error "hosts: 未知子指令 $sub（init|add|rm|show|check|edit）"
           return "$EX_USAGE" ;;
    esac
}

cmd_deploy_main() {
    local sub=${1:-}
    [[ $# -gt 0 ]] && shift
    _CX_DEPLOY_SUB=$sub
    case $sub in
        ''|-h|--help|help) _deploy_usage ;;
        syntax)   _deploy_syntax ;;
        lint)     _deploy_lint ;;
        galaxy)   _deploy_galaxy ;;
        hosts)    _deploy_hosts "$@" ;;
        # 第一個參數是主機樣式（limit），**其餘原樣轉給 ansible**。
        # 原本這裡只傳 "${1:-}"，第二個之後全部被丟掉 ——
        # `cx deploy check staging -e php_repo_source=distro` 會安靜地用預設值跑完，
        # 看起來像「-e 沒生效」，其實參數根本沒離開 cx。
        # _deploy_reject_flag 仍然只檢查**第一個**位置：那裡放旗標一定是打錯了
        #（想寫 --limit），而第二個之後放旗標才是正常用法。
        ping)     _deploy_reject_flag "${1:-}"; _deploy_ping "$@" ;;
        facts)    _deploy_reject_flag "${1:-}"; _deploy_facts "${1:-}" ;;
        vars)     _deploy_reject_flag "${1:-}"; _deploy_vars "${1:-}" ;;
        check)    _deploy_reject_flag "${1:-}"; _deploy_check "${1:-staging}" "${@:2}" ;;
        apply)    _deploy_reject_flag "${1:-}"; cx_lock deploy; _deploy_apply "${1:-}" site.yml "${@:2}" ;;
        app)      _deploy_reject_flag "${1:-}"; cx_lock deploy; _deploy_apply "${1:-}" playbooks/deploy-only.yml "${@:2}" ;;
        rollback) cx_lock deploy; _deploy_rollback "$@" ;;
        *) cx_error "未知的子指令：$sub"; _deploy_usage; return "$EX_USAGE" ;;
    esac
}
