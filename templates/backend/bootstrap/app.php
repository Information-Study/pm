<?php

use Illuminate\Foundation\Application;
use Illuminate\Foundation\Configuration\Exceptions;
use Illuminate\Foundation\Configuration\Middleware;
use Illuminate\Http\Request;

return Application::configure(basePath: dirname(__DIR__))
    ->withRouting(
        web: __DIR__.'/../routes/web.php',
        api: __DIR__.'/../routes/api.php',
        commands: __DIR__.'/../routes/console.php',
        health: '/up',
    )
    ->withMiddleware(function (Middleware $middleware): void {
        // ── 反向代理 ────────────────────────────────────────────────────
        // 這個應用「永遠」在反向代理後面，兩條部署路線都是：
        //   Docker   ZAP/瀏覽器 → (waf) → edge nginx → app
        //   Ansible  瀏覽器 → MyGuard nginx + ModSecurity → php-fpm
        // 不信任 X-Forwarded-* 的話：
        //   * request()->ip() 全部是 proxy 的容器 IP → rate limit 與稽核紀錄失真
        //   * request()->isSecure() 永遠 false → 產生的絕對網址是 http://
        //     （TLS 終結在最前面那層），Sanctum 的 secure cookie 也會判斷錯誤
        //
        // 只信任私有網段而不是 '*'：app 容器沒有對外發布任何埠，
        // 唯一進得來的是同網段的 edge / waf，所以這個範圍已經足夠緊。
        $middleware->trustProxies(at: [
            '10.0.0.0/8',
            '172.16.0.0/12',
            '192.168.0.0/16',
            '127.0.0.1',
            '::1',
        ]);

        // ── 未認證的訪客要導去哪裡 ────────────────────────────────────────
        // 不設這個的話，Laravel 的 Authenticate middleware 會呼叫 route('login')，
        // 而這個專案沒有名為 login 的路由 → RouteNotFoundException → HTTP 500。
        //
        // 症狀特別容易誤判：帶 Accept: application/json 時是正確的 401，
        // 用瀏覽器直接開同一個網址卻是 500，看起來像「API 壞了」，
        // 其實只是找不到重導目標。
        //
        // 回傳 null 代表「不要重導，直接丟 401」——
        // 對 API 請求這才是正確行為。其餘情況導到前端的登入頁
        // （edge 會把 / 轉給 Nuxt，所以 /login 是前端的路由）。
        $middleware->redirectGuestsTo(
            fn (Request $request) => $request->expectsJson() || $request->is('api/*')
                ? null
                : '/login'
        );
    })
    ->withExceptions(function (Exceptions $exceptions): void {
        $exceptions->shouldRenderJsonWhen(
            fn (Request $request) => $request->is('api/*') || $request->expectsJson(),
        );
    })->create();
