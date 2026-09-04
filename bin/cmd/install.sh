#!/usr/bin/env bash
# cx install / cx uninstall — 讓 cx 全域可用 + 註冊 bash 補全。
#
# 採用 symlink 到 ~/.local/bin 而非改 PATH，理由：
#   - 冪等（重跑不會累積）
#   - 可逆（uninstall 只需刪 symlink）
#   - 不動使用者的 rc 檔（除非補全需要，且那段有明確標記與確認）

CX_BIN_DIR="${CX_BIN_DIR:-$HOME/.local/bin}"
CX_COMP_DIR="${CX_COMP_DIR:-$HOME/.local/share/bash-completion/completions}"
CX_RC_BEGIN='# >>> cx completion >>>'
CX_RC_END='# <<< cx completion <<<'

cmd_install_main() {
    local do_rc=0
    while (( $# )); do
        case $1 in
            --rc)      do_rc=1; shift ;;
            -h|--help) printf '用法：cx install [--rc]\n  --rc  另外在 ~/.bashrc 加入補全載入（僅在自動偵測失效時需要）\n' >&2; return 0 ;;
            *)         cx_die "$EX_USAGE" "未知參數：$1" ;;
        esac
    done

    cx_step "安裝 cx"
    mkdir -p "$CX_BIN_DIR" "$CX_COMP_DIR"

    # 1) 主程式 symlink
    local link="$CX_BIN_DIR/cx"
    if [[ -L $link && $(readlink -f "$link") == "$(readlink -f "$CX_ROOT/cx")" ]]; then
        cx_ok "已連結" "$link"
    elif [[ -e $link && ! -L $link ]]; then
        cx_die "$EX_PRECOND" "$link 已存在且不是 symlink，請自行處理"
    else
        cx_run ln -sfn "$CX_ROOT/cx" "$link"
        cx_ok "已建立 symlink：$link → $CX_ROOT/cx"
    fi

    # 2) 補全
    local comp="$CX_COMP_DIR/cx"
    cx_run ln -sfn "$CX_ROOT/bin/completion/cx.bash" "$comp"
    cx_ok "補全已註冊：$comp"

    # 3) PATH 檢查
    case ":$PATH:" in
        *":$CX_BIN_DIR:"*) cx_ok "PATH 已含 $CX_BIN_DIR" ;;
        *) cx_warn "PATH 不含 $CX_BIN_DIR"
           cx_dim "  加入： export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
    esac

    # 4) 選用：寫進 rc（僅在使用者明確要求時）
    if (( do_rc )); then
        local rc="$HOME/.bashrc"
        if grep -qF "$CX_RC_BEGIN" "$rc" 2>/dev/null; then
            cx_ok "~/.bashrc 已有 cx 區塊"
        else
            cx_confirm "寫入 ~/.bashrc" \
"將在 $rc 末尾加入：

$CX_RC_BEGIN
[ -f $CX_ROOT/bin/completion/cx.bash ] && . $CX_ROOT/bin/completion/cx.bash
$CX_RC_END

繼續嗎？" || return "$EX_ABORT"
            # 同上：dry-run 之下 `>>` 一樣會真的寫進去。
            # 重導在命令執行「之前」就套用，cx_run 包不住它。
            if (( CX_DRY_RUN )); then
                cx_dim "[dry-run] 會在 $rc 末尾追加 cx 區塊（3 行）"
            else
                {
                    printf '\n%s\n' "$CX_RC_BEGIN"
                    printf '[ -f %s ] && . %s\n' \
                        "$CX_ROOT/bin/completion/cx.bash" "$CX_ROOT/bin/completion/cx.bash"
                    printf '%s\n' "$CX_RC_END"
                } >> "$rc"
            fi
            cx_ok "已寫入 $rc"
        fi
    fi

    cx_info "重開 shell 或執行： . $CX_ROOT/bin/completion/cx.bash"
    cx_ok "完成。現在可以在任何目錄直接輸入 cx"
}

cmd_uninstall_main() {
    local do_rc=0
    while (( $# )); do
        case $1 in
            --rc) do_rc=1; shift ;;
            -h|--help) printf '用法：cx uninstall [--rc]\n' >&2; return 0 ;;
            *) cx_die "$EX_USAGE" "未知參數：$1" ;;
        esac
    done

    # 專案規則：任何刪除都要確認
    cx_confirm --danger "移除 cx 安裝" \
"將移除：
  $CX_BIN_DIR/cx
  $CX_COMP_DIR/cx
$( (( do_rc )) && printf '  ~/.bashrc 中的 cx 區塊（會先備份為 .bashrc.cx.bak）' )

專案本身不會被刪除。繼續嗎？" || return "$EX_ABORT"

    cx_step "移除"
    local f
    for f in "$CX_BIN_DIR/cx" "$CX_COMP_DIR/cx"; do
        if [[ -L $f ]]; then cx_run rm -f "$f"; cx_ok "已移除 $f"
        elif [[ -e $f ]]; then cx_warn "$f 不是 symlink，保留不動"
        else cx_dim "$f 不存在"; fi
    done

    if (( do_rc )); then
        local rc="$HOME/.bashrc"
        if grep -qF "$CX_RC_BEGIN" "$rc" 2>/dev/null; then
            # ⚠ 這一整段都必須受 --dry-run 保護，不能只保護 cp。
            #
            # 原本是：
            #   cx_run cp -p -- "$rc" "$rc.cx.bak"
            #   awk … "$rc.cx.bak" > "$rc"
            # 前者走 cx_run（dry-run 會跳過），後者的 `>` 重導卻是無條件執行的。
            # 於是 `cx --dry-run uninstall --rc` 的實際效果是：
            #   1. 備份沒有建立
            #   2. `>` 立刻把 ~/.bashrc 截成 0 bytes
            #   3. awk 讀不到不存在的 .cx.bak，什麼也沒寫回去
            # 使用者的 ~/.bashrc 就這樣沒了，而且沒有任何備份。
            # 實測（2026-09-04，用假的 HOME）：80 bytes → 0 bytes。
            #
            # dry-run 的契約是「只印出要做什麼，不改變任何狀態」，
            # 而 shell 的重導在命令執行「之前」就會先截斷檔案 ——
            # 任何 `> 檔案` 都不能出現在 cx_run 之外。
            if (( CX_DRY_RUN )); then
                cx_dim "[dry-run] cp -p -- $rc $rc.cx.bak"
                cx_dim "[dry-run] awk（移除 cx 區塊）$rc.cx.bak > $rc"
                cx_ok "已移除 ~/.bashrc 的 cx 區塊（dry-run，未實際變更）"
            else
                cp -p -- "$rc" "$rc.cx.bak" \
                    || cx_die "$EX_FAIL" "無法備份 $rc —— 中止，不會改動它"
                # 先寫暫存檔再覆蓋：awk 失敗時 ~/.bashrc 完全沒被碰過。
                # 用 awk 精確錨定，不用 sed 正規式插值
                #（標記字串若含正規式元字元，sed 會刪錯範圍）
                local tmp_rc
                tmp_rc=$(mktemp) || cx_die "$EX_FAIL" "無法建立暫存檔"
                if awk -v b="$CX_RC_BEGIN" -v e="$CX_RC_END" \
                       '$0==b{s=1;next} $0==e{s=0;next} !s' "$rc.cx.bak" > "$tmp_rc"; then
                    cat "$tmp_rc" > "$rc"
                    rm -f "$tmp_rc"
                    cx_ok "已移除 ~/.bashrc 的 cx 區塊（備份：$rc.cx.bak）"
                else
                    rm -f "$tmp_rc"
                    cx_die "$EX_FAIL" "awk 處理失敗 —— $rc 未被更動，備份在 $rc.cx.bak"
                fi
            fi
        else
            cx_dim "~/.bashrc 沒有 cx 區塊"
        fi
    fi
    cx_ok "完成"
}
