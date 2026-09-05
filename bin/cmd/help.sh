#!/usr/bin/env bash
cmd_help_main() {
    cat >&2 <<'TXT'
cx — pm 專案統一入口

用法：cx [全域旗標] <動詞> [參數...]

全域旗標
  --root <path>     指定專案根目錄（預設向上搜尋 .cxroot）
  --mode <m>        dev | test | prod（預設 dev）
  --ui <u>          whiptail | dialog | plain
  --runner <r>      docker | native | auto（預設 auto）
                    強制用容器或原生工具鏈。被指定的那一邊不可用時硬失敗，
                    不會偷偷退回另一邊 —— 例：cx --runner native composer install
  --dry-run         只印出指令，不執行
  --yes, -y         略過互動確認（非互動環境專用，請謹慎）

── 第一階段：建立與開發 ─────────────────────────────────────────────────────
  setup             一鍵初始化（.env、目錄、collections，並盤點工具鏈）
    setup native            ★ 一行裝完整套原生工具鏈 = system + tools + deps
    setup system [名稱...]  需要 root 的系統套件（php / nginx / git / docker
                            〔含 compose v2〕/ mysql-client / php-sqlite / acl）。
                            sudo 不可用時只印指令並回傳 3，不會替你輸入密碼
    setup tools [名稱...]   免 root 安裝 composer / node〔含 npm〕/ ansible /
                            shellcheck ／
                            trivy / gitleaks / semgrep 到 ~/.local（核對 SHA256）
    setup deps              backend 的 composer install + npm ci + vite build，
                            frontend 的 npm ci
    setup env|dirs|guard    只做其中一項
                            （artisan 不必安裝 —— 它是 backend/artisan）
  doctor            檢查工具鏈、Docker daemon、埠、子模組、執行位元
  acl               用 POSIX ACL 設定檔案權限。setgid 只繼承群組、不繼承權限
                    位元，所以 php-fpm 與 deploy 建的檔會互相不能寫 ——
                    default ACL 才治本（而且 others 仍然是 0）
    acl check               唯讀驗證
    acl apply [backend|frontend]
                            整棵樹 web 可讀、storage 與 bootstrap/cache 可寫、
                            .env 只給 web 讀
    acl user add <帳號>     讓另一個開發者可以改原始碼（--ro 只讀）
    acl fix-owner           把不屬於你的檔案要回來（setfacl 需要擁有者）
    acl status|drop         檢視 / 移除

  dev up -d --build 起開發環境（bind mount + HMR + xdebug + phpMyAdmin）
  dev down [-v]     關閉（-v 連資料庫一起刪，會要求確認）
  dev ps|logs|sh|restart|build|config|dc
                    （這 9 個動作也可以不加模式直接打：cx ps / cx config …，
                     沿用 --mode，預設 dev）
  art <參數>        php artisan（容器或原生，看 --runner）
  php <參數>        直接跑 php（-v / -m / -r / 一次性腳本）
  composer <參數>   composer（在 backend/；容器或原生）
  npm <參數>        npm（在 frontend/；容器或原生）
    npm --backend <參數>  在 backend/ 執行（Laravel 端的 Vite 資產）
  db status|shell|migrate|fresh|seed|dump|restore|admin|wait
  pma [--url]       開啟 phpMyAdmin（dev 與 test 有；prod 刻意沒有）
  style [範圍]      程式碼風格，**會改檔案**：PHP 用 Pint、前端用 Prettier
                    範圍：php / js / all（預設 all）；--check 只檢查不改
                    兩個工具都已隨既有相依裝好，不需要另外安裝
  code [路徑]       用 VS Code 開啟專案（預設開專案根）

── 第二階段：測試與掃描 ─────────────────────────────────────────────────────
  test up -d        起測試環境（不可變映像 + ModSecurity WAF）
  test back|front|all|coverage|larastan
                    跑測試套件（back 走 sqlite :memory:，不需要 MySQL）

  scan code         ① Quality  Larastan + SonarQube scanner
  scan sast         ② SAST     Semgrep
  scan sca          ③ SCA      Trivy + composer audit + npm audit
  scan dast         ④ DAST     OWASP ZAP（DetectionOnly 與 On 各跑一次做對照）
  scan secrets      gitleaks 全歷史祕密掃描
  scan all          ①②③④ 再加 secrets，**全部跑完**再回傳最嚴重的那個退出碼
                    （不是遇到第一個 finding 就停）  --runner docker|native|auto
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
  deploy facts <主機>  抓一台主機的 ansible facts
  deploy vars [限制]   印出該群組合併後的變數（查「我設的值到底有沒有生效」）

── Git ──────────────────────────────────────────────────────────────────────
  git status                  三個 repo 的分支 / 變更 / 上游 / 領先落後
  git fetch                   三個 repo 一起 fetch --prune（唯讀）
  git pull                    三個 repo 一起更新（主庫先、子模組後，只快轉）
  git sync                    子模組 checkout 追蹤分支
  git commit [-m <訊息>]      提交（子模組先、主庫 gitlink 後）
  git save [-m <訊息>]        commit 的別名
  git scan-secrets            推送前的祕密掃描（gitleaks，push 會自動先跑）
  git branch list|new|switch|delete <名稱>
  git remote-init             用 gh 建立 Information-Study 的三個 public repo
  git push                    推送（白名單 + 祕密掃描 + 子模組順序）
  git guard install|status|remove   pre-push 白名單 hook（**選用**，預設未安裝）

── 其他 ─────────────────────────────────────────────────────────────────────
  tui               互動選單（預設動詞）—— 可切換模式／runner、整備環境、自訂選單
  lint [範圍] [目錄] 靜態檢查，**不改檔案**（CI 與提交前用這個）
                    範圍：ansible / php / js / sh / all（預設 all）
                    ansible 那一支是 --syntax-check 的替代品，不是等價物 ——
                    ansible 裝好之後請改用 cx deploy lint
  fresh             清理與重建（備份 → 驗證 → 確認閘門 → 刪除 → 重建 → 三 Git 初始化）
    fresh --phase preflight   只做前置檢查，完全不動任何東西
    fresh --mode backup-only  只封存
    fresh --mode scaffold     全新骨架
    fresh --mode carryover    全新骨架 + 把你的程式碼疊回去（預設）
    fresh --rollback          從封存還原（預設用 LATEST）
  install [--rc]    建立 ~/.local/bin/cx symlink + 註冊 bash 補全
  uninstall         移除（需確認）

三個模式可以同時運行：不同的 compose project（-p <專案>_dev|_test|_prod）隔離
容器／網路／volume，不同的 host 埠段（docker/env/<mode>.env）隔離埠。
-p 不隔離 host 埠 —— 只做前者不做後者，第二個模式會 port is already allocated。

驗收狀態見 docs/docker-verification.md 與 reports/verify/。
未驗證項目清單見 claude.md §12。
TXT
}
