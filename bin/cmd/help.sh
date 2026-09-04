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

── 第一階段：建立與開發 ─────────────────────────────────────────────────────
  setup             一鍵初始化（.env、目錄、push guard，並盤點工具鏈）
    setup tools [名稱...]   免 root 安裝 composer / node / ansible / trivy /
                            gitleaks / semgrep 到 ~/.local（每個都核對 SHA256）
    setup deps              backend 的 composer install + frontend 的 npm ci
    setup env|dirs|guard     只做其中一項
  doctor            檢查工具鏈、Docker daemon、埠、子模組、執行位元

  dev up -d --build 起開發環境（bind mount + HMR + xdebug + phpMyAdmin）
  dev down [-v]     關閉（-v 連資料庫一起刪，會要求確認）
  dev ps|logs|sh|restart|build|config|dc
  art <參數>        php artisan
  composer <參數>   composer（在 backend/）
  npm <參數>        npm（在 frontend/）
  db status|shell|migrate|fresh|seed|dump|restore|admin|wait

── 第二階段：測試與掃描 ─────────────────────────────────────────────────────
  test up -d        起測試環境（不可變映像 + ModSecurity WAF）
  test back|front|all|coverage|larastan
                    跑測試套件（back 走 sqlite :memory:，不需要 MySQL）

  scan code         ① Quality  Larastan + SonarQube scanner
  scan sast         ② SAST     Semgrep
  scan sca          ③ SCA      Trivy + composer audit + npm audit
  scan dast         ④ DAST     OWASP ZAP（DetectionOnly 與 On 各跑一次做對照）
  scan secrets      gitleaks 全歷史祕密掃描
  scan all          依序執行     --runner docker|native|auto
  sonar up|down|status|token|url|logs|wait
                    常駐 SonarQube（獨立 project pm_devsecops）

  verify [範圍...]  跑 docs/docker-verification.md 的驗收清單並產出報告
                    範圍：static / runtime / app / ansible / all

── 第三階段：部署 ───────────────────────────────────────────────────────────
  prod up -d --build   起正式環境的容器（只發布 80）
  deploy syntax     ansible-playbook --syntax-check（三個 playbook）
  deploy lint       ansible-lint（production profile）+ yamllint
  deploy check [限制]  --check --diff 乾跑
  deploy ping [限制]   確認 SSH 與 become
  deploy apply [限制]  ⚠ 真的部署（會列出目標主機並要求確認）
  deploy app [限制]    只跑應用層（不碰系統層）
  deploy rollback      互動式回滾
  deploy galaxy     安裝 requirements.yml 的 collections

── Git ──────────────────────────────────────────────────────────────────────
  git status                  三個 repo 的分支 / 變更 / 上游 / 領先落後
  git fetch                   三個 repo 一起 fetch --prune（唯讀）
  git pull                    三個 repo 一起更新（主庫先、子模組後，只快轉）
  git sync                    子模組 checkout 追蹤分支
  git commit [-m <訊息>]      提交（子模組先、主庫 gitlink 後）
  git branch list|new|switch|delete <名稱>
  git remote-init             用 gh 建立 Information-Study 的三個 public repo
  git push                    推送（白名單 + 祕密掃描 + 子模組順序）
  git guard install|status|remove

── 其他 ─────────────────────────────────────────────────────────────────────
  tui               互動選單（預設動詞）
  lint [目錄]       Ansible 靜態檢查（沒裝 ansible 時的替代品）
  fresh             清理與重建（備份 → 驗證 → 確認閘門 → 刪除 → 重建）
  install [--rc]    建立 ~/.local/bin/cx symlink + 註冊 bash 補全
  uninstall         移除（需確認）

尚未實作
  fresh --rollback                          見 claude.md §12
  fresh --mode carryover|scaffold 的重建階段  見 claude.md §12

三個模式可以同時運行：不同的 compose project（-p pm_dev|pm_test|pm_prod）隔離
容器／網路／volume，不同的 host 埠段（docker/env/<mode>.env）隔離埠。
-p 不隔離 host 埠 —— 只做前者不做後者，第二個模式會 port is already allocated。

驗收狀態見 docs/docker-verification.md 與 reports/verify/。
未驗證項目清單見 claude.md §12。
TXT
}
