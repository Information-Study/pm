<?php

namespace Tests;

use Illuminate\Contracts\Foundation\Application;
use Illuminate\Support\Env;

/**
 * 測試資料庫的硬性防護。
 *
 * ── 為什麼需要這個 ────────────────────────────────────────────────────────
 *
 * phpunit.xml 用 <env force="true"> 把 DB_CONNECTION 釘成 sqlite、
 * DB_DATABASE 釘成 :memory:。**在容器裡那是無效的**，實測確認：
 *
 *   容器內 $_SERVER['DB_CONNECTION'] = 'mysql'   （compose 的 environment: 設的）
 *   vendor/vlucas/phpdotenv/.../RepositoryBuilder.php
 *       ServerConstAdapter 排在 EnvConstAdapter **之前**
 *   PHPUnit 的 force 只寫 putenv() 與 $_ENV，不寫 $_SERVER
 *   → Laravel 解析到 mysql
 *
 * 也就是說，在容器裡裸跑 `php artisan test`、`composer test` 或
 * `vendor/bin/phpunit`，測試會打到**真正的開發資料庫**，
 * 而任何用 RefreshDatabase 的測試會把它清空。
 *
 * 唯一擋著這件事的是 bin/cmd/test.sh 的 `docker exec -e ...`，
 * 也就是「只有經過 cx test 才安全」。這個類別把防護搬到應用層，
 * 讓所有進入點都受保護。
 *
 * ── 兩層 ──────────────────────────────────────────────────────────────────
 *
 *   assertProcessEnv()      tests/bootstrap.php 呼叫，最早的攔截點。
 *                           涵蓋不 boot Laravel 的測試（Unit/ 底下那些直接
 *                           繼承 PHPUnit\Framework\TestCase 的）。
 *                           實測 PHPUnit 的 Application.php：PhpHandler
 *                           （處理 <env force>）跑在 BootstrapLoader 之前，
 *                           所以這裡同時看得到「宣告的意圖」與「實際的贏家」。
 *
 *   assertResolvedConfig()  TestCase::createApplication() 呼叫。
 *                           ⚠ 不是 setUp()。setUpTheTestEnvironment() 的順序是
 *                             refreshApplication()  → createApplication()
 *                             setUpTraits()         → RefreshDatabase 在這裡清庫
 *                           放在 parent::setUp() 之後的檢查會在資料庫**已經被
 *                           清掉之後**才跑，那不是防護，是驗屍。
 *                           這一層看得到 Layer A 看不到的東西：
 *                           bootstrap/cache/config.php（config:cache 的產物）
 *                           會把 database.default 釘死並完全繞過 env()。
 *
 * ── 判準 ──────────────────────────────────────────────────────────────────
 *
 * 不是「DB_CONNECTION 必須是 sqlite」，而是「這次會真的連上的那個資料庫，
 * 是不是宣告過的測試目標」。白名單，不是黑名單。
 */
final class DatabaseSafetyGuard
{
    /** 與 bin/lib/common.sh 的 EX_PRECOND 同號，讓 shell 與 PHP 兩邊詞彙一致。 */
    public const EXIT_CODE = 3;

    /** 顯式放行清單的環境變數名。格式：driver://host/database，逗號分隔。 */
    public const ALLOW_VAR = 'PM_TEST_DB_ALLOW';

    /** Layer A —— 從行程環境判斷。tests/bootstrap.php 呼叫。 */
    public static function assertProcessEnv(): void
    {
        $target = self::resolveFromEnv();

        if (! self::isTestingEnv()) {
            self::abort(
                'APP_ENV 不是 testing（解析結果：'.self::describe(Env::get('APP_ENV')).'）',
                $target,
                '這一條不可被 '.self::ALLOW_VAR." 覆寫 —— 它擋的是同一類 bug 的上一層：\n"
                .'  compose 的 environment: 透過 $_SERVER 蓋掉了 phpunit.xml 的 APP_ENV=testing。'
            );
        }

        if (! self::isAllowed($target)) {
            self::abort('測試會連到一個不是測試目標的資料庫', $target);
        }
    }

    /** Layer B —— 從 boot 完的 app 判斷最終解析結果。TestCase::createApplication() 呼叫。 */
    public static function assertResolvedConfig(Application $app): void
    {
        $config = $app->make('config');
        $name = (string) $config->get('database.default');
        $conn = (array) $config->get("database.connections.{$name}", []);

        $target = [
            'driver' => (string) ($conn['driver'] ?? $name),
            'host' => (string) ($conn['host'] ?? ''),
            'database' => (string) ($conn['database'] ?? ''),
            'source' => 'config()（已套用 .env 與 bootstrap/cache/config.php）',
        ];

        // url 會覆蓋 driver/host/database，且優先權最高。
        $url = (string) ($conn['url'] ?? '');
        if ($url !== '') {
            $target = self::parseUrl($url) + ['source' => 'config() 的 url'];
        }

        if ((string) $config->get('app.env') !== 'testing') {
            self::abort(
                'app.env 不是 testing（解析結果：'.self::describe($config->get('app.env')).'）',
                $target,
                "如果 APP_ENV 看起來是對的，檢查 bootstrap/cache/config.php ——\n"
                .'  config:cache 的產物會把值釘死並完全繞過 env()。跑 php artisan config:clear。'
            );
        }

        if (! self::isAllowed($target)) {
            self::abort(
                '應用 boot 完之後解析到的資料庫不是測試目標',
                $target,
                "Layer A（bootstrap）放行了但這一層擋下來，代表差異來自環境變數以外的地方：\n"
                .'  最可能是 bootstrap/cache/config.php。跑 php artisan config:clear。'
            );
        }
    }

    // ── 解析 ──────────────────────────────────────────────────────────────

    /**
     * 用 Illuminate\Support\Env::get() 解析，不自己重寫 $_SERVER-優先的順序。
     * 用真正做決定的那段程式碼，這個防護就結構上不可能與 Laravel 意見不同。
     *
     * @return array{driver:string,host:string,database:string,source:string}
     */
    private static function resolveFromEnv(): array
    {
        // DB_URL 非空時它贏 —— config/database.php 每個連線都有 'url' => env('DB_URL')，
        // 而 ConfigurationUrlParser 會用它覆寫 driver/host/database。
        // 空字串是安全的：parseConfiguration() 有 `if (! $url) return $config;`。
        $url = Env::get('DB_URL');
        if (is_string($url) && trim($url) !== '') {
            return self::parseUrl($url) + ['source' => 'DB_URL'];
        }

        $driver = (string) (Env::get('DB_CONNECTION') ?? '');
        $host = (string) (Env::get('DB_HOST') ?? '');
        $database = (string) (Env::get('DB_DATABASE') ?? '');

        // DB_SOCKET 非空 + 非 sqlite → DB_HOST 失去意義，主機判斷會被繞過。
        $socket = (string) (Env::get('DB_SOCKET') ?? '');
        if ($socket !== '' && $driver !== 'sqlite') {
            $host = 'unix:'.$socket;
        }

        return compact('driver', 'host', 'database') + ['source' => 'DB_CONNECTION/DB_HOST/DB_DATABASE'];
    }

    /** @return array{driver:string,host:string,database:string} */
    private static function parseUrl(string $url): array
    {
        $parts = parse_url($url);
        if ($parts === false || ! isset($parts['scheme'])) {
            // 解析不出來的目標就是未知的目標 —— 未知一律當成不安全。
            self::abort('DB_URL 解析失敗，無法判斷會連到哪裡', [
                'driver' => '?', 'host' => '?', 'database' => '?', 'source' => 'DB_URL（無法解析）',
            ]);
        }

        return [
            'driver' => (string) $parts['scheme'],
            'host' => (string) ($parts['host'] ?? ''),
            'database' => ltrim((string) ($parts['path'] ?? ''), '/'),
        ];
    }

    private static function isTestingEnv(): bool
    {
        return (string) (Env::get('APP_ENV') ?? '') === 'testing';
    }

    // ── 判定 ──────────────────────────────────────────────────────────────

    /** @param array{driver:string,host:string,database:string,source?:string} $t */
    private static function isAllowed(array $t): bool
    {
        if (self::isSafeSqlite($t)) {
            return true;
        }

        // 顯式放行：必須帶值，不能是布林開關。
        // PM_TEST_DB_ALLOW=1 會被某人寫進 ~/.bashrc 然後永遠忘記；
        // 要求指名資料庫，代表「放行開發庫」得真的寫出 mysql://mysql/pm ——
        // 那是 greppable、reviewable、而且 cx verify 檢查得到的。
        $allow = (string) (Env::get(self::ALLOW_VAR) ?? '');
        if ($allow === '') {
            return false;
        }

        foreach (explode(',', $allow) as $entry) {
            $entry = trim($entry);
            if ($entry === '') {
                continue;
            }
            $want = self::parseUrl($entry);
            if ($want['driver'] === $t['driver']
                && $want['host'] === $t['host']
                && $want['database'] === $t['database']) {
                return true;
            }
        }

        return false;
    }

    /** @param array{driver:string,database:string} $t */
    private static function isSafeSqlite(array $t): bool
    {
        if ($t['driver'] !== 'sqlite') {
            return false;
        }
        if ($t['database'] === ':memory:') {
            return true;
        }
        // 檔案型 sqlite 只放行 database/ 底下、副檔名 .sqlite 的路徑。
        // 這是為了讓「需要保留資料的除錯」有一條路，而不必關掉整個防護。
        $base = basename($t['database']);

        return str_ends_with($base, '.sqlite') && str_contains($t['database'], 'database/');
    }

    // ── 診斷 ──────────────────────────────────────────────────────────────

    /**
     * @param  array{driver:string,host:string,database:string,source?:string}  $t
     * @return never
     */
    private static function abort(string $why, array $t, string $extra = ''): void
    {
        $lines = [
            '',
            '  ✘ 測試資料庫防護：拒絕執行',
            '',
            "    原因：{$why}",
            '',
            '    這次會連到：',
            "      driver   : {$t['driver']}",
            "      host     : {$t['host']}",
            "      database : {$t['database']}",
            '      判定來源 : '.($t['source'] ?? '?'),
            '',
        ];

        // 並列印出三個來源，讓人「看見」force="true" 為什麼輸了。
        $lines[] = '    環境變數的三個來源（Laravel 讀取順序：$_SERVER → $_ENV → getenv）：';
        $lines[] = sprintf('      %-16s %-22s %-22s %s', '', '$_SERVER', '$_ENV', 'getenv()');
        foreach (['APP_ENV', 'DB_CONNECTION', 'DB_HOST', 'DB_DATABASE', 'DB_URL'] as $k) {
            $lines[] = sprintf(
                '      %-16s %-22s %-22s %s',
                $k,
                self::describe($_SERVER[$k] ?? null),
                self::describe($_ENV[$k] ?? null),
                self::describe(getenv($k) === false ? null : getenv($k))
            );
        }
        $lines[] = '';
        $lines[] = '    如果 $_SERVER 與 $_ENV 不一致，那就是 phpunit.xml 的 force="true" 輸掉的原因：';
        $lines[] = '      PHPUnit 的 force 只寫 putenv() 與 $_ENV，而 Laravel 的 Dotenv 先讀 $_SERVER。';
        $lines[] = '';
        $lines[] = '    正確的跑法（會把六個變數以 -e / env 前綴傳進去）：';
        $lines[] = '      cx test back                    # 容器';
        $lines[] = '      cx --runner native test back    # 原生';
        $lines[] = '';
        $lines[] = '    真的要對別的資料庫跑測試時，指名它（不是關掉防護）：';
        $lines[] = '      '.self::ALLOW_VAR.'=mysql://mysql-test/pm_test';
        if ($extra !== '') {
            $lines[] = '';
            foreach (explode("\n", $extra) as $l) {
                $lines[] = '    '.$l;
            }
        }
        $lines[] = '';

        fwrite(STDERR, implode(PHP_EOL, $lines).PHP_EOL);
        exit(self::EXIT_CODE);
    }

    private static function describe(mixed $v): string
    {
        if ($v === null) {
            return '(unset)';
        }
        if ($v === '') {
            return '(empty)';
        }

        return is_scalar($v) ? (string) $v : gettype($v);
    }
}
