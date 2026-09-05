<?php

namespace Tests;

use Illuminate\Foundation\Testing\TestCase as BaseTestCase;

abstract class TestCase extends BaseTestCase
{
    /**
     * ⚠ 這一層**必須**掛在 createApplication()，不能掛在 setUp()。
     *
     * Illuminate\Foundation\Testing\Concerns\InteractsWithTestCaseLifecycle
     * ::setUpTheTestEnvironment() 的順序是：
     *
     *     refreshApplication()   → 呼叫 createApplication()   ← 這裡
     *     setUpTraits()          → RefreshDatabase 在這裡清庫
     *
     * 放在 parent::setUp() 之後的檢查會在資料庫**已經被清掉之後**才跑 ——
     * 那不是防護，是驗屍。
     *
     * 這一層看得到 bootstrap.php 那一層看不到的東西：
     * bootstrap/cache/config.php（config:cache 的產物）會把 database.default
     * 釘死並完全繞過 env()，任何環境變數層的檢查都看不見它。
     */
    public function createApplication()
    {
        $app = parent::createApplication();

        DatabaseSafetyGuard::assertResolvedConfig($app);

        return $app;
    }
}
