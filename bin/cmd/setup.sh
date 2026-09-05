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

  (無參數) / all   env + dirs + galaxy，最後報告缺哪些工具（guard 是選用，不含）
  env              從 .env.example 產生 .env（隨機密碼、你的 UID/GID、專案名）
  dirs             建立 reports/ 與 .cx/ 的葉目錄（必須由你的身分建立，不能讓 Docker 建）
  guard            安裝三個 repo 的 pre-push 白名單 hook（**選用**，白名單讀 .cxroot）

  native           ★ 一行裝完整套原生工具鏈 = system + tools + deps（不吃名稱）
                   順序固定 system → tools → deps（composer 的安裝器需要 php）

  system [名稱...] 需要 root 的系統套件（apt）
                   可選：php nginx git docker mysql-client php-sqlite acl
                   sudo 不可用時**只印指令**並回傳 3，不會替你輸入密碼
  tools [名稱...]  免 root 的工具鏈到 ~/.local（每個下載都核對 SHA256）
                   可選：composer node ansible trivy gitleaks semgrep
                   （npm / npx 隨 node 一起裝；ansible-lint / yamllint 隨 ansible）
  deps             專案相依：backend 的 composer install + npm ci + vite build，
                   frontend 的 npm ci
  省略名稱 = 裝全部缺少的（已存在的會安靜略過，可重複執行）

哪個工具在哪一邊
  需要 root（system）  php・nginx・git・docker（含 compose v2）・mysql-client・php-sqlite
  免 root（tools）     composer・node（含 npm）・ansible・trivy・gitleaks・semgrep
  不必安裝             artisan —— 它是 backend/artisan，隨 Laravel 一起來

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

    local root_pw app_pw app_key uid gid line slug
    root_pw=$(_setup_gen_secret)
    app_pw=$(_setup_gen_secret)
    # APP_KEY 的格式是 Laravel 規定的：base64: 前綴 + 32 bytes 的 base64。
    # 不能用 _setup_gen_secret（那是 A-Za-z0-9 的 32 字元，長度不對），
    # 也不能少了前綴 —— Encrypter 會直接把整串當成原始金鑰，長度檢查就過不了。
    app_key="base64:$(LC_ALL=C head -c 32 /dev/urandom | base64)"
    uid=$(id -u)
    gid=$(id -g)
    # 專案識別從 .cxroot 帶進 .env：compose 的網路名與映像前綴都吃這個值。
    # 少了它，複製出去改名的專案會建出 pm_dev_net、pm/app:… 跟本專案相撞。
    slug=$(cx_project)

    : > "$out"
    chmod 600 "$out"
    # bash 的 ${v//a/b} 是字面替換、不吃元字元 —— 這是刻意不用 sed 的原因。
    while IFS= read -r line || [[ -n $line ]]; do
        case $line in
            'MYSQL_ROOT_PASSWORD=__CHANGE_ME__') line="MYSQL_ROOT_PASSWORD=$root_pw" ;;
            'DB_PASSWORD=__CHANGE_ME__')         line="DB_PASSWORD=$app_pw" ;;
            'APP_KEY=__CHANGE_ME__')             line="APP_KEY=$app_key" ;;
            'APP_UID=1000')                      line="APP_UID=$uid" ;;
            'APP_GID=1000')                      line="APP_GID=$gid" ;;
            # ⚠ 比對**鍵**而不是整行字面值。原本寫的是 'PROJECT_SLUG=pm'，
            #   那等於把「範本裡目前的值」變成第二事實來源：只要有人改過
            #   .env.example（cx rename 就會改），這兩個 case 就再也比不到，
            #   而產生出來的 .env 會靜默沿用範本裡的舊值。
            #   身分只有一個來源：.cxroot（cx_project），這裡無條件覆寫。
            'PROJECT_SLUG='*)                    line="PROJECT_SLUG=$slug" ;;
            'IMAGE_PREFIX='*)                    line="IMAGE_PREFIX=$slug" ;;
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
        "$CX_ROOT/reports/dast/detect" \
        "$CX_ROOT/reports/dast/blocking" \
        "$CX_ROOT/reports/dast/compare" \
        "$CX_ROOT/reports/waf" \
        "$CX_ROOT/.cx/cache/trivy" \
        "$CX_ROOT/.cx/cache/semgrep" \
        "$CX_ROOT/.cx/cache/phpstan" \
        "$CX_ROOT/.cx/toolchain"
    # reports/verify 是 cx verify 的落點，漏了它報告會寫不出去。
    cx_ensure_host_dirs "$CX_ROOT/reports/verify" "$CX_ROOT/reports/db" "$CX_ROOT/reports/secrets"

    # reports/.gitignore 是**進版控的檔案**，不是目錄。
    # rm -rf reports 會把它一起帶走，而 cx_ensure_host_dirs 只建目錄 ——
    # 於是重建之後 reports/ 底下所有掃描產出都會變成待提交的檔案。
    # 這裡把它補回來，讓「刪掉 reports/ 再用 cx 重建」真的能還原到可用狀態，
    # 不必依賴 git checkout。
    if [[ ! -f $CX_ROOT/reports/.gitignore ]]; then
        cat > "$CX_ROOT/reports/.gitignore" <<'GITIGNORE'
# reports/ 目錄本身要進版控，內容不進。
# 這樣 fresh clone 才有這個目錄，Docker 不會以 root:root 自動建立它，
# 掃描器（uid 1000）也就不會 EACCES。
*
!.gitignore
!README.md
GITIGNORE
        cx_ok "已補回 reports/.gitignore"
    fi

    # reports/README.md 跟 .gitignore 一樣是「進版控的檔案」，rm -rf reports 會帶走它。
    # 但它是純文件，內容不該被複製一份到這支腳本裡（兩份一定會漂移）——
    # 所以從版控取回，而不是用 heredoc 重寫。
    #
    # 三個前提都要成立才做，任何一個不成立就只是提示，不當成錯誤：
    #   1) 有 git（cx fresh 會刪掉 .git，那之後這裡本來就取不回來）
    #   2) 這裡真的是 git 工作區
    #   3) 這個路徑真的被追蹤（新專案可能根本沒有這個檔）
    if [[ ! -f $CX_ROOT/reports/README.md ]]; then
        if cx_have git \
           && git -C "$CX_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
           && git -C "$CX_ROOT" ls-files --error-unmatch reports/README.md >/dev/null 2>&1 \
           && cx_run git -C "$CX_ROOT" checkout -- reports/README.md 2>/dev/null; then
            cx_ok "已從版控取回 reports/README.md"
        else
            cx_warn "reports/README.md 不見了，而且取不回來（沒有 git 或它沒被追蹤）"
            cx_dim "  這只是文件，不影響任何功能。要的話自己補一份。"
        fi
    fi

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

# ShellCheck 的 release 與其他幾個不同：資產是 .tar.xz、執行檔在一層子目錄底下、
# 而且**沒有提供校驗檔**。所以不能用 _setup_gh_release_tarball，要自己來。
_setup_tool_shellcheck() {
    cx_have shellcheck && {
        cx_ok "shellcheck 已存在：$(shellcheck --version 2>/dev/null | awk '/^version:/{print $2}')"
        return 0; }
    cx_info "安裝 shellcheck"
    local tmp json url
    tmp=$(mktemp -d) || return 1
    trap 'rm -rf "${tmp:-}"' RETURN
    json=$(curl -4 -fsSL "https://api.github.com/repos/koalaman/shellcheck/releases/latest") || return 1
    url=$(printf '%s' "$json" | grep -oE '"browser_download_url": *"[^"]+"' \
          | cut -d'"' -f4 | grep -E 'linux\.x86_64\.tar\.xz$' | head -1)
    [[ -n $url ]] || { cx_error "shellcheck：找不到 linux.x86_64 資產"; return 1; }
    _setup_fetch "$url" "$tmp/a.tar.xz" || return 1
    # 上游不出校驗檔，所以這裡沒有 SHA 核對 —— 明講，不要假裝有。
    cx_warn "shellcheck 的 release 沒有提供校驗檔，本次無 SHA256 核對"
    cx_run tar -xJf "$tmp/a.tar.xz" -C "$tmp" || return 1
    local bin; bin=$(find "$tmp" -type f -name shellcheck -perm -u+x | head -1)
    [[ -n $bin ]] || { cx_error "壓縮檔裡沒有 shellcheck"; return 1; }
    cx_run install -Dm 0755 "$bin" "$CX_LOCAL_BIN/shellcheck" || return 1
    cx_ok "shellcheck → $CX_LOCAL_BIN/shellcheck"
}

# bats-core 的 release **沒有任何 asset**（只有 GitHub 自動產生的原始碼壓縮檔），
# 所以 _setup_gh_release_tarball 不適用 —— 它會 grep browser_download_url。
#
# 版本釘死，不追 latest：測試框架自己換版是會讓一整套測試同時變紅的那種事，
# 而那時你正在查的是別的東西。
#
# ⚠ 下面那個 SHA256 是**本專案在釘版當下自己記下的**，不是上游發布的校驗值
#   （上游沒有出）。它防的是「釘版之後那個 URL 的內容被換掉」，
#   **不是**「上游 release 本身被攻陷」。不要把它當成比實際更強的保證。
CX_BATS_VERSION="${CX_BATS_VERSION:-v1.14.0}"
CX_BATS_SHA256="${CX_BATS_SHA256:-bb537b70b15b732f6d8827dd6578e3d8ce166636ce1f18ea9a074184fcce9177}"

_setup_tool_bats() {
    cx_have bats && { cx_ok "bats 已存在：$(bats --version 2>/dev/null)"; return 0; }
    cx_info "安裝 bats-core $CX_BATS_VERSION"
    local tmp url
    tmp=$(mktemp -d) || return 1
    # shellcheck disable=SC2064
    trap 'rm -rf "${tmp:-}"' RETURN
    url="https://github.com/bats-core/bats-core/archive/refs/tags/${CX_BATS_VERSION}.tar.gz"
    _setup_fetch "$url" "$tmp/bats.tar.gz" || return 1
    if [[ -n $CX_BATS_SHA256 ]]; then
        _setup_verify_sha "$tmp/bats.tar.gz" "$CX_BATS_SHA256" || return 1
        cx_ok "SHA256 核對通過（本專案的釘版紀錄）"
    fi
    cx_run tar -xzf "$tmp/bats.tar.gz" -C "$tmp" || return 1
    local src; src=$(find "$tmp" -maxdepth 1 -type d -name 'bats-core-*' | head -1)
    [[ -n $src ]] || { cx_error "壓縮檔裡找不到 bats-core-*"; return 1; }
    # bats 自己的 install.sh：免 root，裝到 ~/.local/{bin,libexec,lib}
    cx_run "$src/install.sh" "$HOME/.local" || return 1
    cx_ok "bats → $CX_LOCAL_BIN/bats"
}

CX_SETUP_TOOLS='composer node ansible trivy gitleaks semgrep shellcheck bats'

# ── 需要 root 的系統工具 ────────────────────────────────────────────────────
#
# 上面那些（composer / node / ansible / trivy / gitleaks / semgrep）全部裝在
# ~/.local，不需要 root，所以 cx 可以直接動手。
#
# php / nginx / git / docker / mysql-client 是**系統套件**，一定要 root。
# cx 對這種東西的原則是：
#   1. 絕不偷偷跑 sudo。要用 root 就明講，而且要有確認閘門。
#   2. sudo 不可用（沒密碼、非互動）時，把「你該自己貼哪一行」印出來，
#      而不是丟一個 permission denied 就結束。
# 這是紅線 2 的延伸：會改變系統狀態的動作都要看得見、可預期。
CX_SETUP_SYSTEM_TOOLS='php nginx git docker mysql-client php-sqlite acl jq'

# 工具 → apt 套件名。php 相關的要帶版本號，所以用函式而不是靜態表。
_setup_pkgs_for() {
    local t=$1 v
    v=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)
    [[ -n $v ]] || v=${CX_PHP_SERIES:-8.5}
    case $t in
        php)          printf 'php%s-cli php%s-mbstring php%s-xml php%s-curl php%s-zip php%s-intl php%s-bcmath php%s-gd php%s-mysql\n' "$v" "$v" "$v" "$v" "$v" "$v" "$v" "$v" "$v" ;;
        php-sqlite)   printf 'php%s-sqlite3\n' "$v" ;;
        nginx)        printf 'nginx\n' ;;
        git)          printf 'git\n' ;;
        mysql-client) printf 'mysql-client\n' ;;
        # cx acl 需要 setfacl/getfacl。Ansible 的 become_user 交接也要它，
        # 所以目標機的 common role 早就會裝 —— 開發機這邊本來沒有。
        acl)          printf 'acl\n' ;;
        # docs/reports.md 與 reports/README.md 的範例都用 jq 看掃描報告，
        # 但它從來不在任何安裝清單裡 —— 照文件做的人會卡在 command not found。
        jq)           printf 'jq\n' ;;
        docker)       printf 'docker.io docker-compose-v2\n' ;;
        *) return 1 ;;
    esac
}

# 這個工具「已經在」了嗎？用實際的執行檔／擴充判斷，不看套件資料庫 ——
# 使用者可能是用別的方式裝的（PPA、手動、Docker Desktop 的 WSL integration）。
_setup_system_have() {
    case $1 in
        php)          cx_have php ;;
        php-sqlite)   php -m 2>/dev/null | grep -qix pdo_sqlite ;;
        nginx)        cx_have nginx ;;
        git)          cx_have git ;;
        mysql-client) cx_have mysql ;;
        # acl 曾經漏在這裡。症狀不是「acl 裝不起來」，而是 setup system 一路
        # 把成功報成失敗：_setup_system_have acl 永遠落到 *) return 1，於是
        # 安裝後的複驗迴圈判定「裝完之後仍然不可用」→ EX_FAIL，
        # 連帶讓 cx setup native 的階段①中斷。
        acl)          cx_have setfacl && cx_have getfacl ;;
        jq)           cx_have jq ;;
        docker)       cx_have docker ;;
        *) return 1 ;;
    esac
}

# tools 與 system 是兩個清單，但使用者不會記得哪個工具在哪一邊。
# 打錯邊時要直接告訴他正確的指令，而不是丟一句「未知的工具」讓他自己猜。
_setup_hint_other_list() {
    local t=$1
    case " $CX_SETUP_TOOLS " in
        *" $t "*) cx_dim "  $t 是免 root 的工具 → cx setup tools $t"; return 0 ;;
    esac
    case " $CX_SETUP_SYSTEM_TOOLS " in
        *" $t "*) cx_dim "  $t 需要 root → cx setup system $t"; return 0 ;;
    esac
    # 常見的別名／誤解
    case $t in
        npm|node|nodejs)     cx_dim "  npm 隨 node 一起裝 → cx setup tools node" ;;
        docker-compose|compose)
                             cx_dim "  compose v2 是 docker 的一部分 → cx setup system docker" ;;
        artisan)             cx_dim "  artisan 不是要安裝的工具，它是 backend/artisan（隨 Laravel 一起來）" ;;
        mysql|mysql-cli)     cx_dim "  → cx setup system mysql-client" ;;
        ansible-lint|yamllint)
                             cx_dim "  → cx setup tools ansible（同一個 venv 一起裝）" ;;
    esac
    return 1
}

_setup_system() {
    case ${1:-} in
        -h|--help|help) _setup_usage; return 0 ;;
    esac

    cx_have apt-get || cx_die "$EX_PRECOND" \
        "只支援 Debian/Ubuntu 系（找不到 apt-get）。請自行安裝：$CX_SETUP_SYSTEM_TOOLS"

    local -a want=("$@")
    (( ${#want[@]} )) || read -r -a want <<< "$CX_SETUP_SYSTEM_TOOLS"

    local t
    for t in "${want[@]}"; do
        case " $CX_SETUP_SYSTEM_TOOLS " in
            *" $t "*) : ;;
            *) cx_error "未知的系統工具：$t（可用：$CX_SETUP_SYSTEM_TOOLS）"
               _setup_hint_other_list "$t" || true
               return "$EX_USAGE" ;;
        esac
    done

    # 已經有的就不要列進去 —— 重跑這個指令應該是安靜的（冪等）。
    local -a pkgs=() todo=()
    for t in "${want[@]}"; do
        if _setup_system_have "$t"; then
            cx_ok "$t 已存在，略過"
        else
            todo+=("$t")
            local p
            for p in $(_setup_pkgs_for "$t"); do pkgs+=("$p"); done
        fi
    done

    if (( ${#pkgs[@]} == 0 )); then
        cx_ok "系統工具都齊了，沒有東西要裝"
        return 0
    fi

    cx_step "需要 root 的系統套件"
    cx_info "工具：${todo[*]}"
    cx_info "套件：${pkgs[*]}"

    # sudo 不可用就只印指令。這不是失敗 —— 使用者自己貼上去執行是完全正常的流程，
    # 尤其在 CI 或不給 sudo 的機器上。
    if ! sudo -n true 2>/dev/null; then
        cx_warn "sudo 需要密碼或不可用 —— cx 不會替你輸入密碼"
        cx_dim "  請自行執行："
        cx_dim "    sudo apt-get update && sudo apt-get install -y ${pkgs[*]}"
        cx_dim "  裝完再跑一次 cx doctor 確認"
        return "$EX_PRECOND"
    fi

    cx_confirm --danger "以 root 安裝系統套件" \
        "將以 sudo 執行：\n\n  apt-get install -y ${pkgs[*]}\n\n這會改變系統狀態（不只是這個專案）。\n\n繼續嗎？" \
        || return "$EX_ABORT"

    cx_run sudo apt-get update || cx_die "$EX_FAIL" "apt-get update 失敗"
    cx_run sudo apt-get install -y "${pkgs[@]}" || cx_die "$EX_FAIL" "apt-get install 失敗"

    # 裝完要驗，不能只看 apt 的退出碼 —— 套件裝了不代表你要的東西就在
    #（最典型的是 php 擴充：套件裝了但 .ini 沒啟用）。
    local bad=0
    for t in "${todo[@]}"; do
        if _setup_system_have "$t"; then cx_ok "$t 已就緒"
        else cx_error "$t 裝完之後仍然不可用"; bad=1; fi
    done
    (( bad == 0 )) || return "$EX_FAIL"

    if [[ " ${todo[*]} " == *" docker "* ]]; then
        cx_warn "docker 剛裝好：要加入 docker 群組才能免 sudo 使用"
        cx_dim "  sudo usermod -aG docker \$USER"
        cx_dim "  然後 WSL 端必須 wsl --shutdown（Windows）再重開，"
        cx_dim "  usermod 只影響「之後才建立」的登入 session。"
    fi
}

_setup_tools() {
    case ${1:-} in
        -h|--help|help) _setup_usage; return 0 ;;
    esac

    local -a want=("$@")
    local t rc=0
    (( ${#want[@]} )) || read -r -a want <<< "$CX_SETUP_TOOLS"

    for t in "${want[@]}"; do
        case " $CX_SETUP_TOOLS " in
            *" $t "*) : ;;
            *) cx_error "未知的工具：$t（可用：$CX_SETUP_TOOLS）"
               _setup_hint_other_list "$t" || true
               return "$EX_USAGE" ;;
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
# 「工具在 PATH 上但那是 Windows 那支」是 WSL 專屬的坑，訊息要講清楚，
# 不能只說「沒有 npm」—— 使用者 which 得到東西，會覺得 cx 在騙人。
_setup_deps_missing() {
    local t=$1 how=$2 winp
    if winp=$(cx_win_interop_path "$t"); then
        cx_error "PATH 上的 $t 是 Windows 的：$winp"
        cx_dim "  它不能用來建置 WSL 裡的專案：CMD.EXE 不支援 UNC 路徑當工作目錄，"
        cx_dim "  症狀是 npm ci 留下一棵殘缺的 node_modules、然後 vite build 失敗。"
        cx_dim "  Linux 版裝在 ~/.local/bin，但你的 shell 沒把它排在前面："
        cx_dim '    export PATH="$HOME/.local/bin:$PATH"   # 或重開一個 login shell'
    elif [[ -e $CX_LOCAL_BIN/$t ]]; then
        # 叫使用者去「安裝一個已經裝好的東西」是最浪費時間的錯誤訊息：
        # 他會照做、看到安裝成功、然後發現 cx 還是說沒有。
        cx_error "$t 已經裝在 $CX_LOCAL_BIN/$t —— 是這個 shell 的 PATH 看不到它"
        cx_dim '    export PATH="$HOME/.local/bin:$PATH"   # 或重開一個 login shell'
    else
        cx_warn "沒有 $t —— 先跑 $how"
    fi
}

_setup_deps() {
    local rc=0
    if [[ -f $CX_ROOT/backend/composer.json ]]; then
        cx_step "backend：composer install"
        if cx_have_native composer; then
            # 不加 --no-dev：host 上的 vendor 是給 IDE 與 cx scan code（larastan）用的。
            ( cd "$CX_ROOT/backend" && cx_run composer install --no-interaction --prefer-dist ) || rc=1
        else
            _setup_deps_missing composer "cx setup tools composer"
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
        if cx_have_native npm; then
            ( cd "$CX_ROOT/backend" \
              && cx_run npm ci --no-audit --no-fund \
              && cx_run npm run build ) || rc=1
        else
            _setup_deps_missing npm "cx setup tools node"
            rc=1
        fi
    fi
    if [[ -f $CX_ROOT/frontend/package.json ]]; then
        cx_step "frontend：npm ci"
        if cx_have_native npm; then
            ( cd "$CX_ROOT/frontend" && cx_run npm ci --no-audit --no-fund ) || rc=1
        else
            _setup_deps_missing npm "cx setup tools node"
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
# 缺的東西其實已經裝在 CX_LOCAL_BIN，只是 PATH 沒有它 —— 這是最容易誤診的情況：
# 使用者會一直重跑 cx setup tools，而每次都「安裝成功」然後 cx 還是說缺。
# 回傳 0 表示「已經給出 PATH 的建議，不要再叫他去安裝」。
_setup_path_hint() {
    local t found=0
    for t in "$@"; do
        case $t in
            ansible) [[ -e $CX_LOCAL_BIN/ansible-playbook ]] && found=1 ;;
            node)    [[ -e $CX_LOCAL_BIN/node ]] && found=1 ;;
            *)       [[ -e $CX_LOCAL_BIN/$t ]]   && found=1 ;;
        esac
    done
    (( found )) || return 1
    cx_error "這些其實已經裝在 $CX_LOCAL_BIN 了 —— 是這個 shell 的 PATH 看不到它"
    cx_dim '  這次先生效： export PATH="$HOME/.local/bin:$PATH"'
    cx_dim '  永久生效：   ~/.profile 已經有這段，但它只在 login shell 生效；'
    cx_dim '               非 login shell 請把同一行加到 ~/.bashrc'
    cx_dim "  確認：        echo \$PATH | tr : '\\n' | grep '\.local/bin'"
    cx_warn "PATH 沒修好之前不要跑 cx setup deps —— 在 WSL 上 npm 會解析到"
    cx_warn "Windows 的 /mnt/c/.../npm，留下一棵殘缺的 node_modules 並讓 vite build 失敗。"
    return 0
}

_setup_all() {
    local t
    local -a missing=()

    cx_step "環境檔"
    _setup_env
    cx_step "目錄"
    _setup_dirs
    # push guard 不再由 cx setup 自動安裝（2026-09-04 起改為選用）。
    # 它會攔截所有原生 git push，需要 CX_ALLOW_PUSH=1 才放行 ——
    # 那對「想直接用 git / IDE 推送」的人是持續的阻礙。
    # 要的人自己跑： cx setup guard  或  cx git guard install
    cx_step "push guard"
    cx_dim "選用，預設不安裝。要啟用白名單攔截： cx git guard install"

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
            ansible) cx_have_native ansible-playbook || missing+=("$t") ;;
            *)       cx_have_native "$t"             || missing+=("$t") ;;
        esac
    done
    if (( ${#missing[@]} )); then
        cx_warn "缺少：${missing[*]}"
        # 「東西其實裝好了，只是這個 shell 看不到」跟「真的沒裝」要分開講，
        # 否則使用者會照著建議重裝一次，然後發現還是缺 —— 因為問題從來不是沒裝。
        if _setup_path_hint "${missing[@]}"; then
            :
        else
            cx_dim "  安裝：cx setup tools ${missing[*]}"
        fi
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

# ── native：一行把「完全不用 Docker 也能跑完」需要的東西全部裝起來 ──────────
#
# 為什麼需要這個而不是叫大家自己打三行：
#   原生工具鏈被切成 system（需要 root）與 tools（免 root）兩份清單，
#   這個切分對「誰來裝」是必要的，但對「我要把原生路徑準備好」的人是雜訊 ——
#   他要的是 php / nginx / git / docker / composer / node+npm 全部就位。
#
# 順序不能反：composer 的安裝器需要 php（_setup_tool_composer 會 cx_need php），
# 所以 system 必須先跑。system 因為缺 sudo 而只印出指令時回傳 EX_PRECOND，
# 這裡把它記下來但**繼續**跑 tools —— 免 root 的那一半仍然裝得起來，
# 沒有理由因為使用者等一下才要貼 sudo 指令就整個停掉。
_setup_native() {
    # native 不吃名稱過濾器，而且必須自己攔 --help。兩個原因都是實測踩到的：
    #
    #   1. 分派表寫的是 `native) _setup_native "$@"`，沒有攔 -h/--help。
    #      而 _setup_system 收到 --help 會印說明並 **return 0** ——
    #      對 _setup_native 來說那是成功，於是它繼續往下跑 _setup_tools（無參數
    #      ＝ 安裝全部六個工具）再跑 _setup_deps。
    #      也就是說 `cx setup native --help` 會**真的開始安裝**。
    #
    #   2. usage 曾經寫成 `native [名稱...]`，但那個過濾器是假的：名稱只會被
    #      傳給 _setup_system，_setup_tools 是裸呼叫。更糟的是兩份清單
    #      （CX_SETUP_SYSTEM_TOOLS vs CX_SETUP_TOOLS）**互斥**，
    #      所以 `cx setup native semgrep` 會在第①段就 cx_error 中止。
    #      要裝單一項目就用 cx setup system / cx setup tools，不要走 native。
    case ${1:-} in
        -h|--help|help) _setup_usage; return 0 ;;
        '') : ;;
        *)  cx_error "cx setup native 不接受參數（收到：$*）"
            cx_dim "  它是「三段一次跑完」：system → tools → deps"
            cx_dim "  要裝單一項目： cx setup system <名稱>  或  cx setup tools <名稱>"
            cx_dim "  可用清單：     cx setup system --help"
            return "$EX_USAGE" ;;
    esac

    local rc=0 sys_rc=0

    cx_step "① 需要 root 的系統套件"
    _setup_system || sys_rc=$?
    (( sys_rc == 0 )) || rc=$sys_rc

    cx_step "② 免 root 的工具鏈（~/.local）"
    _setup_tools || rc=$?

    cx_step "③ 專案相依"
    if cx_have composer && cx_have npm; then
        _setup_deps || rc=$?
    else
        cx_warn "composer / npm 還沒就緒 —— 略過 deps"
        cx_dim "  上面的步驟修好之後再跑： cx setup deps"
        rc=${rc:-1}; (( rc )) || rc=1
    fi

    cx_step "結果"
    if (( sys_rc == EX_PRECOND )); then
        cx_warn "系統套件那一段需要你自己貼上 sudo 指令（見上面 ① 的輸出）"
    fi
    if (( rc == 0 )); then
        cx_ok "原生工具鏈就緒 —— 現在 cx --runner native <動詞> 應該可以完全不用 Docker"
        cx_dim "  驗證： cx doctor（看「兩條 runner 各自的完整性」那一段）"
    else
        cx_warn "有步驟沒完成（rc=$rc）。修好之後可以只重跑缺的那一段："
        cx_dim "  cx setup system / cx setup tools / cx setup deps"
    fi
    return "$rc"
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
        system)  cx_lock setup; _setup_system "$@" ;;
        native)  cx_lock setup; _setup_native "$@" ;;
        deps)    cx_lock setup; _setup_deps ;;
        *) cx_error "未知的子指令：$sub"; _setup_usage; return "$EX_USAGE" ;;
    esac
}
