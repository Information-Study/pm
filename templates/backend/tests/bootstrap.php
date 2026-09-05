<?php

use Tests\DatabaseSafetyGuard;

/**
 * PHPUnit 的 bootstrap（phpunit.xml 的 bootstrap= 指向這裡）。
 *
 * 為什麼不是直接用 vendor/autoload.php：
 * 這是**每一個進入點都會經過**的唯一位置 —— vendor/bin/phpunit、
 * php artisan test（Collision 會 spawn phpunit 並繼承環境）、composer test、
 * 以及 cx test back 的兩條 runner。把資料庫防護放在這裡，
 * 就不會有「只有經過 cx test 才安全」的問題。
 *
 * 時序（實測 PHPUnit 的 TextUI/Application.php）：
 *   PhpHandler      處理 <php><env force="true">   ← 先
 *   BootstrapLoader 載入這個檔案                    ← 後
 * 所以這裡同時看得到「宣告的意圖」（$_ENV=sqlite）與「實際的贏家」
 * （$_SERVER=mysql），能診斷出分歧而不是用猜的。
 *
 * ⚠ 已知涵蓋範圍的洞：`phpunit --no-configuration` 或 `-c 別的.xml`
 *   不會載入這個檔案。那兩種用法繞得過 Layer A，只剩 TestCase 的 Layer B。
 */

require __DIR__.'/../vendor/autoload.php';

require_once __DIR__.'/DatabaseSafetyGuard.php';

DatabaseSafetyGuard::assertProcessEnv();
