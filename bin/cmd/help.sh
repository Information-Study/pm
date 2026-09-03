#!/usr/bin/env bash
cmd_help_main() {
    cat >&2 <<'TXT'
cx — pm 專案統一入口

用法：cx [全域旗標] <動詞> [參數...]

全域旗標
  --root <path>     指定專案根目錄（預設向上搜尋 .cxroot）
  --mode <m>        dev | test | prod（預設 dev）
  --ui <u>          whiptail | dialog | plain
  --dry-run         只印出指令，不執行
  --yes, -y         略過互動確認（非互動環境專用，請謹慎）

環境
  doctor            檢查工具鏈、Docker daemon、埠、子模組狀態
  fresh             清理與重建（備份 → 驗證 → 確認閘門 → 刪除 → 重建）
    --mode backup-only   只備份，不刪任何東西
    --mode carryover     重建後把業務碼搬回（預設）
    --mode scaffold      純淨重建（需輸入 NO CARRYOVER）
    --rollback [--from <dir>]   從封存還原

Git
  git status|sync|save        日常操作（自動處理子模組先後）
  git remote-init             用 gh 建立 Information-Study 的三個 public repo
  git push                    推送（白名單 + 祕密掃描 + 子模組順序）
  git guard install|status|remove

其他動詞（Docker / 掃描 / 部署）尚未實作，見 docs/。
TXT
}
