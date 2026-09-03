#!/usr/bin/env bash
# cx lint — Ansible 靜態檢查。
#
# 這是 ansible-playbook --syntax-check 與 ansible-lint 的**替代品**，不是等價物。
# 本機裝不了 ansible（無 pip、sudo 需密碼），所以只能做：
#   YAML 剖析、FQCN 檢查、紅線違規、變數引用、命令任務的 changed_when。
# ansible 一旦可用，請改跑真正的 --syntax-check，本工具只是補位。

cmd_lint_main() {
    local target="${1:-$CX_ROOT/ansible}"
    [[ -d $target ]] || cx_die "$EX_PRECOND" "找不到 $target"

    if cx_have ansible-playbook; then
        cx_warn "偵測到 ansible-playbook —— 請改用真正的檢查："
        cx_dim "  ansible-playbook $CX_ROOT/ansible/site.yml --syntax-check"
        cx_dim "  ansible-lint $CX_ROOT/ansible/"
        cx_info "以下仍執行靜態檢查作為補充"
    else
        cx_warn "ansible 未安裝 —— 這是替代性檢查，不等於 --syntax-check"
    fi

    python3 "$CX_ROOT/bin/lib/ansible_lint.py" "$target"
}
