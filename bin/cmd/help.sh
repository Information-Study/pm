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
  git status                  三個 repo 的分支 / 變更 / 上游
  git sync                    子模組 checkout 追蹤分支
  git commit [-m <訊息>]      提交（子模組先、主庫 gitlink 後）
                              未給 -m 會引導產生 Conventional Commits 訊息
  git branch list|new|switch|delete <名稱>
                              三個 repo 同進同出
  git remote-init             用 gh 建立 Information-Study 的三個 public repo
  git push                    推送（白名單 + 祕密掃描 + 子模組順序）
  git guard install|status|remove

DevSecOps（四道防線，runner 自動偵測 docker/native）
  scan code       ① Quality  Larastan + SonarQube scanner
  scan sast       ② SAST     Semgrep
  scan sca        ③ SCA      Trivy + composer audit + npm audit
  scan dast       ④ DAST     OWASP ZAP（僅 docker）
  scan secrets    gitleaks 全歷史祕密掃描
  scan all        依序執行
    --runner docker|native|auto

開發輔助（Docker 可用時走容器，否則走本機）
  art <參數>      php artisan
  composer <參數> composer（在 backend/）
  npm <參數>      npm（在 frontend/）

安裝
  install [--rc]  建立 ~/.local/bin/cx symlink + 註冊 bash 補全
  uninstall       移除（需確認）

Ansible
  lint [目錄]     靜態檢查（ansible 未安裝時的替代品，不等於 --syntax-check）

尚未實作（文件或訊息若提到，一律以此為準）
  up down build ps logs sh   Phase 2，見 docs/docker-verification.md
  db  test  sonar            Phase 2
  deploy                     Phase 5（ansible 尚未安裝）
  fresh --rollback           見 claude.md §12
  fresh --mode carryover|scaffold 的重建階段  見 claude.md §12

未驗證項目清單見 claude.md §12。
TXT
}
