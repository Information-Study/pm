#!/usr/bin/env bash
# cx setup —— 把一個剛 clone 下來的工作區變成可以動的專案。
#
# 這是「透過單一工具 cx 建立整個專案」的第一步。設計原則：
#   * 全部免 root。需要 sudo 的東西一律只印出指令，不代跑（紅線 2 的精神）。
#   * 冪等。跑第二次不會覆蓋已經存在的 .env，也不會重裝已經對版的工具。
#   * 每個下載都核對 SHA256。沒有校驗碼就警告。

_setup_usage() {
    cat >&2 <<'TXT'
cx setup [子指令]

  (無參數) / all   env + dirs + guard，最後報告缺哪些工具
  env              從 .env.example 產生 .env（隨機密碼、填入你的 UID/GID）
  dirs             建立 reports/ 與 .cx/ 的葉目錄（必須由你的身分建立，不能讓 Docker 建）
  guard            安裝三個 repo 的 pre-push 白名單 hook
  tools [名稱...]  安裝原生工具鏈到 ~/.local（免 root）
                   可選：composer node ansible trivy gitleaks semgrep
                   省略名稱 = 裝全部缺少的
  deps             安裝專案相依（backend 的 composer install、frontend 的 npm ci）

為什麼需要 tools：Docker 可用時大部分工作可以在容器內完成，但
  * cx lint / cx deploy 需要 host 上的 ansible
  * cx scan 的 native runner 需要 trivy / gitleaks / semgrep
  * IDE 的自動完成需要 host 上有 vendor/ 與 node_modules/
TXT
}

# ── env ─────────────────────────────────────────────────────────────────────
_setup_gen_secret() {
    # 刻意限制在 A-Za-z0-9。base64 會產生 / 與 +，而 & 是 sed 的整段回填 ——
    # 只要有任何一段流程用 sed 套密碼，密碼就會被靜默竄改，
    # 一小時後才以 Access denied 現形。限制字元集是最省事的免疫方式。
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
}

_setup_env() {
    local tpl="$CX_ROOT/.env.example" out="$CX_ROOT/.env"
    [[ -f $tpl ]] || cx_die "$EX_PRECOND" "缺少 $tpl"

    if [[ -f $out ]]; then
        cx_ok ".env 已存在 —— 不覆蓋（要重新產生請先自己備份並刪除）"
        local k
        for k in MYSQL_ROOT_PASSWORD DB_PASSWORD APP_UID APP_GID; do
            grep -qE "^${k}=.+" "$out" || cx_warn ".env 缺少或未填 $k"
        done
        grep -qE '^(MYSQL_ROOT_PASSWORD|DB_PASSWORD)=__CHANGE_ME__' "$out" \
            && cx_warn ".env 仍有 __CHANGE_ME__ 佔位字串"
        return 0
    fi

    cx_info "從 .env.example 產生 .env"
    if (( CX_DRY_RUN )); then
        cx_dim "[dry-run] 會寫入 $out"
        return 0
    fi

    local root_pw app_pw uid gid line
    root_pw=$(_setup_gen_secret)
    app_pw=$(_setup_gen_secret)
    uid=$(id -u)
    gid=$(id -g)

    : > "$out"
    chmod 600 "$out"
    # bash 的 ${v//a/b} 是字面替換、不吃元字元 —— 這是刻意不用 sed 的原因。
    while IFS= read -r line || [[ -n $line ]]; do
        case $line in
            'MYSQL_ROOT_PASSWORD=__CHANGE_ME__') line="MYSQL_ROOT_PASSWORD=$root_pw" ;;
            'DB_PASSWORD=__CHANGE_ME__')         line="DB_PASSWORD=$app_pw" ;;
            'APP_UID=1000')                      line="APP_UID=$uid" ;;
            'APP_GID=1000')                      line="APP_GID=$gid" ;;
        esac
        printf '%s\n' "$line" >> "$out"
    done < "$tpl"

    cx_ok "已產生 .env（0600，含隨機密碼，APP_UID=$uid APP_GID=$gid）"
    cx_dim "  .env 已被 .gitignore 排除。這個 repo 是 public，不要 commit 它。"
}

# ── dirs ────────────────────────────────────────────────────────────────────
_setup_dirs() {
    cx_ensure_host_dirs \
        "$CX_ROOT/reports/quality" \
        "$CX_ROOT/reports/sast" \
        "$CX_ROOT/reports/sca" \
        "$CX_ROOT/reports/dast/no-waf" \
        "$CX_ROOT/reports/dast/detect" \
        "$CX_ROOT/reports/dast/blocking" \
        "$CX_ROOT/reports/dast/compare" \
        "$CX_ROOT/reports/waf" \
        "$CX_ROOT/.cx/cache/trivy" \
        "$CX_ROOT/.cx/cache/semgrep" \
        "$CX_ROOT/.cx/cache/phpstan" \
        "$CX_ROOT/.cx/toolchain"
    cx_ok "reports/ 與 .cx/ 的葉目錄已就緒（擁有者：$(id -un)）"
    cx_dim "  這些目錄必須由你建立。讓 Docker 自動建立會是 root:root 0755，"
    cx_dim "  之後以 uid 1000 執行的 Trivy / Semgrep / PHPStan / ZAP 全部 EACCES。"
}

# ── tools ───────────────────────────────────────────────────────────────────
CX_LOCAL_BIN="${CX_LOCAL_BIN:-$HOME/.local/bin}"

_setup_fetch() {
    # _setup_fetch <url> <輸出檔>
    # -4：本機的 IPv6 是壞的，不加會在某些主機上卡到 timeout。
    cx_run curl -4 -fsSL --retry 3 --retry-delay 2 -o "$2" "$1"
}

_setup_verify_sha() {
    # _setup_verify_sha <檔案> <預期sha256>
    local got
    got=$(sha256sum "$1" | cut -d' ' -f1)
    [[ $got == "$2" ]] && return 0
    cx_error "SHA256 不符：$1"
    cx_dim "  預期 $2"
    cx_dim "  實得 $got"
    return 1
}

_setup_tool_composer() {
    if cx_have composer; then
        cx_ok "composer 已存在：$(composer --version 2>/dev/null | head -1)"
        return 0
    fi
    cx_need php "composer 是 PHP 程式，沒有 php 就裝不起來"
    cx_info "安裝 composer"
    local tmp ver sha
    tmp=$(mktemp -d) || return 1
    trap 'rm -rf "${tmp:-}"' RETURN

    # 先整份抓下來再過濾。直接 curl | grep -m1 會讓 grep 在第一筆之後關閉
    # 管線，curl 於是印出 "curl: Failed writing body" —— 那不是錯誤，但看起來像。
    local rel
    rel=$(curl -4 -fsSL https://api.github.com/repos/composer/composer/releases/latest) || return 1
    # cut -d 雙引號 -f4 取值，不用 sed —— 這裡要穿過多層引號，反斜線很容易在途中被吃掉。
    ver=$(printf '%s' "$rel" | grep -m1 '"tag_name"' | cut -d'"' -f4)
    [[ -n $ver ]] || { cx_error "取不到 composer 最新版號"; return 1; }
    cx_info "composer $ver"

    _setup_fetch "https://github.com/composer/composer/releases/download/${ver}/composer.phar" "$tmp/composer.phar" || return 1
    # 校驗碼來自 getcomposer.org（與 binary 不同來源，交叉驗證才有意義）。
    sha=$(curl -4 -fsSL "https://getcomposer.org/download/${ver}/composer.phar.sha256sum" 2>/dev/null | cut -d' ' -f1)
    if [[ -n $sha ]]; then
        _setup_verify_sha "$tmp/composer.phar" "$sha" || return 1
        cx_ok "SHA256 核對通過"
    else
        cx_warn "取不到官方 SHA256，改用 phar 自我驗證"
        php "$tmp/composer.phar" --version >/dev/null || { cx_error "composer.phar 無法執行"; return 1; }
    fi
    cx_run install -Dm 0755 "$tmp/composer.phar" "$CX_LOCAL_BIN/composer" || return 1
    cx_ok "composer → $CX_LOCAL_BIN/composer"
}

_setup_tool_node() {
    if cx_have node; then
        cx_ok "node 已存在：$(node --version)"
        return 0
    fi
    # 24 是 Active LTS（維護到 2028-04-30）。26 在 2026-10 之前還是 Current，不採用。
    local ver=${CX_NODE_VERSION:-v24.20.0}
    local arch tmp want b
    case $(uname -m) in
        x86_64)  arch=linux-x64 ;;
        aarch64) arch=linux-arm64 ;;
        *) cx_error "不支援的架構：$(uname -m)"; return 1 ;;
    esac
    cx_info "安裝 node $ver（$arch）"
    tmp=$(mktemp -d) || return 1
    trap 'rm -rf "${tmp:-}"' RETURN

    _setup_fetch "https://nodejs.org/dist/$ver/node-$ver-$arch.tar.xz" "$tmp/node.tar.xz" || return 1
    _setup_fetch "https://nodejs.org/dist/$ver/SHASUMS256.txt" "$tmp/SHASUMS256.txt" || return 1
    want=$(grep " node-$ver-$arch.tar.xz\$" "$tmp/SHASUMS256.txt" | cut -d' ' -f1)
    [[ -n $want ]] || { cx_error "SHASUMS256.txt 裡找不到 node-$ver-$arch.tar.xz"; return 1; }
    _setup_verify_sha "$tmp/node.tar.xz" "$want" || return 1
    cx_ok "SHA256 核對通過"

    cx_run mkdir -p "$HOME/.local/node" "$CX_LOCAL_BIN"
    cx_run tar -xJf "$tmp/node.tar.xz" -C "$HOME/.local/node" --strip-components=1 || return 1
    for b in node npm npx; do
        cx_run ln -sf "$HOME/.local/node/bin/$b" "$CX_LOCAL_BIN/$b"
    done
    cx_ok "node → $HOME/.local/node（node/npm/npx 已連到 $CX_LOCAL_BIN）"
}

# python 系工具（ansible / semgrep）共用一個 venv。
CX_VENV="${CX_VENV:-$HOME/.local/share/cx-venv}"

_setup_ensure_venv() {
    [[ -x $CX_VENV/bin/pip ]] && return 0
    cx_need python3
    cx_info "建立 python venv：$CX_VENV"
    # 這台機器的 python 沒有 ensurepip（Ubuntu 把它拆成 python3-venv 套件，
    # 而裝那個套件需要 sudo）。所以先建 --without-pip 的 venv，
    # 再用 get-pip.py 把 pip 塞進去 —— 全程免 root。
    cx_run python3 -m venv --without-pip "$CX_VENV" || return 1
    local tmp
    tmp=$(mktemp -d) || return 1
    trap 'rm -rf "${tmp:-}"' RETURN
    _setup_fetch https://bootstrap.pypa.io/get-pip.py "$tmp/get-pip.py" || return 1
    cx_run "$CX_VENV/bin/python" "$tmp/get-pip.py" --no-warn-script-location >/dev/null || return 1
    cx_ok "venv 就緒"
}

_setup_link_venv_bin() {
    local b
    cx_run mkdir -p "$CX_LOCAL_BIN"
    for b in "$@"; do
        [[ -x $CX_VENV/bin/$b ]] || continue
        cx_run ln -sf "$CX_VENV/bin/$b" "$CX_LOCAL_BIN/$b"
    done
}

_setup_tool_ansible() {
    if cx_have ansible-playbook; then
        cx_ok "ansible 已存在：$(ansible-playbook --version 2>/dev/null | head -1)"
        return 0
    fi
    _setup_ensure_venv || return 1
    cx_info "安裝 ansible-core / ansible-lint / yamllint"
    cx_run "$CX_VENV/bin/pip" install --quiet --upgrade \
        "ansible-core>=2.17" ansible-lint yamllint || return 1
    _setup_link_venv_bin ansible ansible-playbook ansible-galaxy ansible-vault \
                         ansible-inventory ansible-doc ansible-lint yamllint
    cx_ok "ansible → $CX_VENV（可執行檔已連到 $CX_LOCAL_BIN）"
    cx_dim "  這解除了 claude.md §12.5 的最大阻擋：現在可以真的跑 --syntax-check 與 ansible-lint"
}

_setup_tool_semgrep() {
    if cx_have semgrep; then
        cx_ok "semgrep 已存在：$(semgrep --version 2>/dev/null)"
        return 0
    fi
    _setup_ensure_venv || return 1
    cx_info "安裝 semgrep"
    cx_run "$CX_VENV/bin/pip" install --quiet --upgrade semgrep || return 1
    _setup_link_venv_bin semgrep
    cx_ok "semgrep → $CX_LOCAL_BIN/semgrep"
}

_setup_gh_release_tarball() {
    # _setup_gh_release_tarball <owner/repo> <資產樣式> <校驗檔樣式> <執行檔名>
    local repo=$1 asset_re=$2 sums_re=$3 binname=$4
    local tmp json url sums_url want
    tmp=$(mktemp -d) || return 1
    trap 'rm -rf "${tmp:-}"' RETURN

    json=$(curl -4 -fsSL "https://api.github.com/repos/$repo/releases/latest") || return 1
    url=$(printf '%s' "$json" | grep -oE '"browser_download_url": *"[^"]+"' \
          | cut -d'"' -f4 | grep -E "$asset_re" | head -1)
    sums_url=$(printf '%s' "$json" | grep -oE '"browser_download_url": *"[^"]+"' \
          | cut -d'"' -f4 | grep -E "$sums_re" | head -1)
    [[ -n $url ]] || { cx_error "$repo：找不到符合 $asset_re 的資產"; return 1; }

    _setup_fetch "$url" "$tmp/a.tar.gz" || return 1
    if [[ -n $sums_url ]]; then
        _setup_fetch "$sums_url" "$tmp/sums.txt" || return 1
        want=$(grep -F "$(basename "$url")" "$tmp/sums.txt" | head -1 | cut -d' ' -f1)
        if [[ -n $want ]]; then
            _setup_verify_sha "$tmp/a.tar.gz" "$want" || return 1
            cx_ok "SHA256 核對通過"
        else
            cx_warn "校驗檔裡找不到 $(basename "$url") 的條目"
        fi
    else
        cx_warn "$repo 沒有提供校驗檔"
    fi

    cx_run tar -xzf "$tmp/a.tar.gz" -C "$tmp" || return 1
    [[ -f $tmp/$binname ]] || { cx_error "壓縮檔裡沒有 $binname"; return 1; }
    cx_run install -Dm 0755 "$tmp/$binname" "$CX_LOCAL_BIN/$binname" || return 1
    cx_ok "$binname → $CX_LOCAL_BIN/$binname"
}

_setup_tool_trivy() {
    cx_have trivy && { cx_ok "trivy 已存在：$(trivy --version 2>/dev/null | head -1)"; return 0; }
    cx_info "安裝 trivy"
    _setup_gh_release_tarball aquasecurity/trivy 'Linux-64bit\.tar\.gz$' 'checksums\.txt$' trivy
}

_setup_tool_gitleaks() {
    cx_have gitleaks && { cx_ok "gitleaks 已存在：$(gitleaks version 2>/dev/null)"; return 0; }
    cx_info "安裝 gitleaks"
    _setup_gh_release_tarball gitleaks/gitleaks 'linux_x64\.tar\.gz$' 'checksums\.txt$' gitleaks
}

CX_SETUP_TOOLS='composer node ansible trivy gitleaks semgrep'

_setup_tools() {
    local -a want=("$@")
    local t rc=0
    (( ${#want[@]} )) || read -r -a want <<< "$CX_SETUP_TOOLS"

    for t in "${want[@]}"; do
        case " $CX_SETUP_TOOLS " in
            *" $t "*) : ;;
            *) cx_error "未知的工具：$t（可用：$CX_SETUP_TOOLS）"; return "$EX_USAGE" ;;
        esac
    done

    for t in "${want[@]}"; do
        cx_step "$t"
        # 一個工具裝失敗不該讓其他工具都不裝。用真正的子行程隔離：
        # `f || true` 會讓整個函式本體的 errexit 失效（實測 bash 5.3.9），
        # 包 subshell 也救不回來。
        if ! ( "_setup_tool_$t" ); then
            cx_error "$t 安裝失敗"
            rc=1
        fi
    done

    if [[ ":$PATH:" != *":$CX_LOCAL_BIN:"* ]]; then
        cx_warn "$CX_LOCAL_BIN 不在 PATH 裡"
        cx_dim "  把這一行加進 ~/.bashrc 之後重開 shell："
        cx_dim '    export PATH="$HOME/.local/bin:$PATH"'
    fi
    return "$rc"
}

# ── deps ────────────────────────────────────────────────────────────────────
_setup_deps() {
    local rc=0
    if [[ -f $CX_ROOT/backend/composer.json ]]; then
        cx_step "backend：composer install"
        if cx_have composer; then
            # 不加 --no-dev：host 上的 vendor 是給 IDE 與 cx scan code（larastan）用的。
            ( cd "$CX_ROOT/backend" && cx_run composer install --no-interaction --prefer-dist ) || rc=1
        else
            cx_warn "沒有 composer —— 先跑 cx setup tools composer"
            rc=1
        fi
    fi
    if [[ -f $CX_ROOT/backend/package.json ]]; then
        cx_step "backend：npm ci + vite build（Laravel 端的 blade 資產）"
        # backend 有自己的 package.json（Vite + Tailwind）。
        # welcome.blade.php 用 @vite(...) 引用建置結果，沒有 public/build/manifest.json
        # 就會丟 ViteManifestNotFoundException。
        # 舊專案的 init.sh 呼叫一個從來不存在的 npm-php service 來做這件事（缺陷 D3），
        # 所以後端資產在舊專案裡其實從來沒被建置過。
        if cx_have npm; then
            ( cd "$CX_ROOT/backend" \
              && cx_run npm ci --no-audit --no-fund \
              && cx_run npm run build ) || rc=1
        else
            cx_warn "沒有 npm —— 先跑 cx setup tools node"
            rc=1
        fi
    fi
    if [[ -f $CX_ROOT/frontend/package.json ]]; then
        cx_step "frontend：npm ci"
        if cx_have npm; then
            ( cd "$CX_ROOT/frontend" && cx_run npm ci --no-audit --no-fund ) || rc=1
        else
            cx_warn "沒有 npm —— 先跑 cx setup tools node"
            rc=1
        fi
    fi
    return "$rc"
}

# ── guard ───────────────────────────────────────────────────────────────────
_setup_guard() {
    # shellcheck source=/dev/null
    . "$CX_ROOT/bin/lib/guard.sh"
    cx_guard_install
}

# ── all ─────────────────────────────────────────────────────────────────────
_setup_all() {
    local t
    local -a missing=()

    cx_step "環境檔"
    _setup_env
    cx_step "目錄"
    _setup_dirs
    cx_step "push guard"
    _setup_guard || cx_warn "push guard 安裝未完成（三個 repo 都要是 git repo）"

    if cx_have ansible-galaxy && [[ -f $CX_ROOT/ansible/requirements.yml ]]; then
        cx_step "Ansible collections"
        # ansible/collections/ 不進版控（那是上游程式碼），所以全新 clone 上
        # 一定要先裝一次，否則 cx deploy syntax 會失敗在
        # "couldn't resolve module/action 'community.general.timezone'"。
        if ( cd "$CX_ROOT/ansible" && cx_run ansible-galaxy collection install              -r requirements.yml >/dev/null 2>&1 ); then
            cx_ok "collections 已就緒"
        else
            cx_warn "collection 安裝失敗 —— 手動跑 cx deploy galaxy 看訊息"
        fi
    fi

    cx_step "工具鏈盤點"
    for t in $CX_SETUP_TOOLS; do
        case $t in
            ansible) cx_have ansible-playbook || missing+=("$t") ;;
            *)       cx_have "$t"             || missing+=("$t") ;;
        esac
    done
    if (( ${#missing[@]} )); then
        cx_warn "缺少：${missing[*]}"
        cx_dim "  安裝：cx setup tools ${missing[*]}"
    else
        cx_ok "原生工具鏈齊全"
    fi

    if cx_docker_ok; then
        cx_ok "Docker 可用 —— 接著可以跑 cx dev up -d --build"
    else
        cx_warn "Docker 不可用 —— cx dev/test/prod 都會被擋下"
        cx_dim "  sudo usermod -aG docker \$USER 之後需要 wsl --shutdown（Windows 端）再重開"
    fi

    cx_step "下一步"
    cx_dim "  cx doctor              確認還缺什麼"
    cx_dim "  cx setup deps          裝 backend/vendor 與 frontend/node_modules"
    cx_dim "  cx dev up -d --build   起開發環境"
}

cmd_setup_main() {
    local sub=${1:-all}
    [[ $# -gt 0 ]] && shift
    case $sub in
        -h|--help|help) _setup_usage ;;
        all)     cx_lock setup; _setup_all ;;
        env)     _setup_env ;;
        dirs)    _setup_dirs ;;
        guard)   _setup_guard ;;
        tools)   cx_lock setup; _setup_tools "$@" ;;
        deps)    cx_lock setup; _setup_deps ;;
        *) cx_error "未知的子指令：$sub"; _setup_usage; return "$EX_USAGE" ;;
    esac
}
