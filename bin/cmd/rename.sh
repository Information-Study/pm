#!/usr/bin/env bash
# cx rename — 把整個範本改成新的專案名稱。
#
# 為什麼需要這個動詞：`cx` 的 shell / Python 層是**乾淨**的（專案身分一律從
# .cxroot 的 CX_PROJECT_NAME 推導，見 cx_project / cx_project_for），
# 但有四個地方是硬編碼或第二事實來源：
#
#   .env 的 PROJECT_SLUG / IMAGE_PREFIX
#       `_setup_env` 只在**產生** .env 時寫入；檔案已存在就早退，
#       從不回頭核對。所以只改 .cxroot 的話，compose 專案前綴仍是舊的
#       —— 網路還叫 pm_dev_net，而且沒有任何地方會說出來。
#   sonar-project.properties 的 projectKey / projectName
#   ansible/inventory/group_vars/all/main.yml 的 app_name / app_slug /
#       db_name / db_user / 三個 repo URL
#   ansible/site.yml 的 hosts 群組名 ←→ bin/cmd/deploy.sh 的 --list-hosts
#       這兩個必須彼此一致，否則 cx deploy ping 會找不到任何主機。
#
# 刻意**不碰 .git**：改名不該動版本歷史，remote 要不要改是另一個決定
#（而且這個專案禁止任何自動的 remote 操作）。
#
# 檢查比自動化重要：cx verify cli 的 TPL-* 四項會在每次驗收時比對上面這些點，
# 就算有人手動改名改到一半也抓得到。這個動詞只是讓「全部改對」變得容易。

# 名稱會被拼成：compose 專案前綴、docker 網路名、映像前綴、MySQL 資料庫名與
# 帳號名、Ansible 的群組名。取交集之後的合法字元集比想像中窄：
#   MySQL 帳號名上限 32 字元；docker compose 專案名只吃小寫英數與 - _
#   Ansible 群組名不能有 -（會被當成運算子），所以群組名一律用底線。
readonly _RENAME_RE='^[a-z][a-z0-9_-]{1,30}$'

_rename_usage() {
    cat >&2 <<EOF
用法：cx rename <新名稱>

  把整個範本從目前的專案名改成 <新名稱>。會列出所有變更點並要求確認。

  名稱規則：小寫開頭，只能有小寫英數與 - _，2..31 字元。
            （交集自 compose 專案名、docker 網路名、MySQL 帳號名 32 字元上限、
              以及 Ansible 群組名不能含 - 的限制）

  --dry-run 時只列出變更點，不動任何檔案：
      cx --dry-run rename shop

  改完之後要做的事會在最後印出來（重建映像、重跑 cx setup guard…）。

  **不會**動 .git，也不會碰任何 remote。
EOF
}

# 印出一行變更計畫。回傳 0 代表這個檔案真的需要改。
_rename_plan_file() {                   # _rename_plan_file <檔案> <old> <new> <sed 樣式...>
    local f=$1 n
    [[ -f $CX_ROOT/$f ]] || { printf '  %-46s %s\n' "$f" "（不存在，略過）" >&2; return 1; }
    shift 3
    n=$(sed -n "$(printf '%s;' "$@")" "$CX_ROOT/$f" 2>/dev/null | grep -c . || true)
    if (( n )); then
        printf '  %-46s %s\n' "$f" "$n 處" >&2
        return 0
    fi
    printf '  %-46s %s\n' "$f" "（無須變更）" >&2
    return 1
}

cmd_rename_main() {
    local new=${1:-}
    case $new in
        # 明確要說明 → 0；忘了給參數 → EX_USAGE。全庫其他動詞都是這個慣例
        # （bin/test/00_dispatch.bats 的「每個動詞的 --help」正是在守這件事）。
        -h|--help) _rename_usage; return "$EX_OK" ;;
        '')        _rename_usage; return "$EX_USAGE" ;;
    esac
    shift
    (( $# == 0 )) || { cx_error "多餘的參數：$*"; _rename_usage; return "$EX_USAGE"; }

    local old
    old=$(cx_project)
    [[ -n $old ]] || cx_die "$EX_PRECOND" "讀不到目前的專案名（.cxroot 的 CX_PROJECT_NAME）"

    [[ $new =~ $_RENAME_RE ]] || cx_die "$EX_USAGE" \
        "新名稱「$new」不合法 —— 需符合 $_RENAME_RE
    它會被拼成 compose 專案名、docker 網路名、映像前綴、MySQL 帳號名與 Ansible 群組名。"

    [[ $new != "$old" ]] || cx_die "$EX_USAGE" "新名稱與目前的名稱相同（$old）"

    cx_step "改名：$old → $new"

    # 群組名不能有 -（Ansible 會當成運算子），所以一律轉底線。
    local old_grp="${old//-/_}_servers" new_grp="${new//-/_}_servers"

    cx_info "將變更的檔案："
    local -a targets=()
    _rename_plan_file .cxroot "$old" "$new" \
        "/^CX_PROJECT_NAME=$old\$/p" "/^CX_REPO_MAIN=$old\$/p" \
        "/^CX_REPO_BACKEND=$old-/p" "/^CX_REPO_FRONTEND=$old-/p" && targets+=(.cxroot)
    _rename_plan_file .env "$old" "$new" \
        "/^PROJECT_SLUG=$old\$/p" "/^IMAGE_PREFIX=$old\$/p" \
        "/^DB_DATABASE=$old\$/p" "/^DB_USERNAME=$old\$/p" && targets+=(.env)
    _rename_plan_file .env.example "$old" "$new" \
        "/^PROJECT_SLUG=$old\$/p" "/^IMAGE_PREFIX=$old\$/p" \
        "/^DB_DATABASE=$old\$/p" "/^DB_USERNAME=$old\$/p" && targets+=(.env.example)
    _rename_plan_file sonar-project.properties "$old" "$new" \
        "/^sonar.projectKey=$old\$/p" "/^sonar.projectName=$old\$/p" && targets+=(sonar-project.properties)
    _rename_plan_file ansible/inventory/group_vars/all/main.yml "$old" "$new" \
        "/^app_name: \"$old\"\$/p" "/^app_slug: \"$old\"\$/p" \
        "/^db_name: &db_name \"$old\"\$/p" "/^db_user: &db_user \"$old\"\$/p" \
        "/$old\(-backend\|-frontend\)\?\.git/p" \
        "/^ansible_managed:.*$old /p" && targets+=(ansible/inventory/group_vars/all/main.yml)
    _rename_plan_file ansible/site.yml "$old" "$new" \
        "/^  hosts: $old_grp\$/p" && targets+=(ansible/site.yml)
    _rename_plan_file bin/cmd/deploy.sh "$old" "$new" \
        "/$old_grp/p" && targets+=(bin/cmd/deploy.sh)

    # role 的 defaults/meta 是**被 group_vars 蓋掉**的（group_vars 優先序較高），
    # 所以留著舊名字不會讓部署跑錯 —— 但它們是第二事實來源，
    # 而「改名之後 grep 還找得到舊名字」正是下一個人會困惑的地方。
    # 一起改掉，代價只是一次 sed。
    local -a role_files=()
    while IFS= read -r f; do role_files+=("${f#"$CX_ROOT/"}"); done < <(
        grep -rlE "(app_name|app_slug|author|namespace):[[:space:]]*\"?$old\b|default\('$old'\)|name: $old \|" \
            "$CX_ROOT/ansible/roles" "$CX_ROOT/ansible/playbooks" \
            "$CX_ROOT/ansible/site.yml" 2>/dev/null | sort)
    if (( ${#role_files[@]} )); then
        printf '  %-46s %s\n' "ansible/roles/*、site.yml 的 play 名稱" "${#role_files[@]} 個檔" >&2
        targets+=(--roles)
    fi

    (( ${#targets[@]} )) || { cx_warn "沒有任何檔案需要變更"; return "$EX_OK"; }

    cx_dim "  不會動 .git、不會碰任何 remote、不會改 docker volume 裡的資料"

    if (( CX_DRY_RUN )); then
        cx_info "dry-run —— 以上都不會執行"
        return "$EX_OK"
    fi

    cx_confirm "改名：$old → $new" \
"這會改寫上列檔案裡的專案身分。

不會動 .git、不會碰任何 remote、不會刪除任何 docker volume。
舊的容器與網路（${old}_dev 等）仍會留著，要自己清。

確定要繼續？" || { cx_warn "已取消"; return "$EX_ABORT"; }

    local f
    for f in "${targets[@]}"; do
        case $f in
            .cxroot)
                cx_run sed -i -e "s|^CX_PROJECT_NAME=$old\$|CX_PROJECT_NAME=$new|" \
                              -e "s|^CX_REPO_MAIN=$old\$|CX_REPO_MAIN=$new|" \
                              -e "s|^CX_REPO_BACKEND=$old-|CX_REPO_BACKEND=$new-|" \
                              -e "s|^CX_REPO_FRONTEND=$old-|CX_REPO_FRONTEND=$new-|" \
                    "$CX_ROOT/$f" ;;
            .env|.env.example)
                # DB_DATABASE / DB_USERNAME 也要改：group_vars 的 db_name/db_user
                # 已經跟著改名了，這裡不改的話 Docker 用 $old 庫、Ansible 用 $new 庫。
                # 舊 volume 裡的 $old 資料庫不會自動搬 —— 所以最後會提醒 down -v。
                cx_run sed -i -e "s|^PROJECT_SLUG=$old\$|PROJECT_SLUG=$new|" \
                              -e "s|^IMAGE_PREFIX=$old\$|IMAGE_PREFIX=$new|" \
                              -e "s|^DB_DATABASE=$old\$|DB_DATABASE=$new|" \
                              -e "s|^DB_USERNAME=$old\$|DB_USERNAME=$new|" \
                    "$CX_ROOT/$f" ;;
            sonar-project.properties)
                cx_run sed -i -e "s|^sonar.projectKey=$old\$|sonar.projectKey=$new|" \
                              -e "s|^sonar.projectName=$old\$|sonar.projectName=$new|" \
                    "$CX_ROOT/$f" ;;
            ansible/inventory/group_vars/all/main.yml)
                cx_run sed -i -e "s|^app_name: \"$old\"|app_name: \"$new\"|" \
                              -e "s|^app_slug: \"$old\"|app_slug: \"$new\"|" \
                              -e "s|^db_name: &db_name \"$old\"\$|db_name: \&db_name \"$new\"|" \
                              -e "s|^db_user: &db_user \"$old\"\$|db_user: \&db_user \"$new\"|" \
                              -e "s|/$old\.git|/$new.git|g" \
                              -e "s|/$old-backend\.git|/$new-backend.git|g" \
                              -e "s|/$old-frontend\.git|/$new-frontend.git|g" \
                              -e "s|^\(ansible_managed:.*\)$old \(專案的\)|\1$new \2|" \
                    "$CX_ROOT/$f" ;;
            ansible/site.yml)
                cx_run sed -i -e "s|^  hosts: $old_grp\$|  hosts: $new_grp|" "$CX_ROOT/$f" ;;
            bin/cmd/deploy.sh)
                cx_run sed -i -e "s|\\b$old_grp\\b|$new_grp|g" "$CX_ROOT/$f" ;;
            --roles)
                local rf
                for rf in "${role_files[@]}"; do
                    # ⚠ 不要在 "$old" 後面加 $ 錨點 —— 這些值常帶尾端註解
                    #   （common/defaults 的 app_slug: "pm"  # 路徑、systemd unit 名…），
                    #   加了錨點就會靜默漏掉。用 \b 收邊即可。
                    cx_run sed -i \
                        -e "s|^\(\s*app_name:\s*\)\"$old\"|\1\"$new\"|" \
                        -e "s|^\(\s*app_slug:\s*\)\"$old\"|\1\"$new\"|" \
                        -e "s|^\(\s*app_slug:\s*\)$old\b|\1$new|" \
                        -e "s|^\(\s*author:\s*\)$old\b|\1$new|" \
                        -e "s|^\(\s*namespace:\s*\)$old\b|\1$new|" \
                        -e "s|default('$old')|default('$new')|g" \
                        -e "s|^- name: $old |- name: $new |" \
                        "$CX_ROOT/$rf"
                done ;;
        esac
    done

    cx_ok "已改名為 $new"
    cx_info "接下來要做的事（這個動詞刻意不自動做）："
    cx_dim "  1. 舊的容器／網路／volume 仍然叫 ${old}_dev 等等，要自己清："
    cx_dim "       cx dev down -v ・ cx test down -v ・ cx prod down -v   （會問你）"
    cx_dim "  2. 重建映像（tag 前綴變了）：cx dev up -d --build"
    cx_dim "  3. 重跑 cx setup guard（git hook 裡有專案名的白名單）"
    cx_dim "  4. inventory/hosts.yml 的群組名要改成 $new_grp"
    cx_dim "  5. cx verify cli —— TPL-* 四項應該全綠"
    cx_dim "  6. .gitmodules 仍指向 ../$old-backend.git 與 ../$old-frontend.git ——"
    cx_dim "     刻意不自動改：那些 remote 現在還存在，改了會讓既有的 checkout 壞掉。"
    cx_dim "     等新的 repo 真的建好再改，然後跑 git submodule sync"
    cx_dim "  7. .git 沒有被碰過；remote 要不要改由你決定"
}
