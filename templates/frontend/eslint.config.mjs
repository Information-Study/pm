// ESLint 9+ 的 flat config。
//
// 分工（與 Prettier 的界線是硬的）：
//   ESLint   抓「會出錯的東西」—— 未使用的變數、用了沒定義的東西、
//            Vue 的錯誤用法（v-for 沒有 key、元件命名…）
//   Prettier 只管排版
// 所以這裡**不開任何排版類規則**，兩者不會互相打架，也不需要
// eslint-config-prettier 去關掉一堆規則。
//
// ./.nuxt/eslint.config.mjs 由 @nuxt/eslint 模組在 `nuxt prepare` 時產生
//（package.json 的 postinstall 會跑）。它帶著 Nuxt 的 auto-import 全域
// （defineNuxtConfig、useRuntimeConfig、useState…）與 Vue／TypeScript 的
// 建議規則。少了它，整份專案會被報成 no-undef。
import withNuxt from './.nuxt/eslint.config.mjs'

export default withNuxt({
    rules: {
        // 前端目前沒有正式的日誌管道，console.warn/error 是刻意保留的；
        // console.log 則是忘了刪的除錯痕跡 —— 只擋後者。
        'no-console': ['warn', { allow: ['warn', 'error'] }],
        // _ 開頭代表「知道沒用到，故意留著」（解構時常見）。
        '@typescript-eslint/no-unused-vars': [
            'error',
            {
                argsIgnorePattern: '^_',
                varsIgnorePattern: '^_',
                caughtErrorsIgnorePattern: '^_',
            },
        ],
    },
})
