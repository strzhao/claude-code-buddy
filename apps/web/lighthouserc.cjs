/**
 * Lighthouse CI 配置 — 本地 Core Web Vitals 性能预算门禁（Dim 11 / P1）。
 *
 * 用法：
 *   pnpm --filter @stringzhao/web lhci
 *   （等价 `next build && lhci autorun`：构建 → 起 next start:3000 → 采集 → 断言）
 *
 * upload 用 filesystem（产物落本地 .lighthouseci/，不外传），符合"本地配置"取向。
 * 断言用 'error'：性能预算硬门禁（CI 中超预算即 fail）。本地调试可临时改 'warn'。
 * 注意：categories:performance 是加权综合分，CI 上有 ±5 波动；偶发误报可下调 minScore
 * 或单独改 'warn'；metric 级预算（LCP/CLS/TBT/FCP/SI）稳定，保持 'error'。
 */
module.exports = {
  ci: {
    collect: {
      startServerCommand: "npm run start",
      url: ["http://localhost:3000/", "http://localhost:3000/upload"],
      numberOfRuns: 3,
      settings: { preset: "desktop" },
    },
    assert: {
      assertions: {
        // 总分预算
        "categories:performance": ["error", { minScore: 0.8 }],
        "categories:accessibility": ["error", { minScore: 0.9 }],
        // Core Web Vitals（实验室口径）
        "largest-contentful-paint": ["error", { maxNumericValue: 2500 }],
        "cumulative-layout-shift": ["error", { maxNumericValue: 0.1 }],
        "total-blocking-time": ["error", { maxNumericValue: 300 }],
        "first-contentful-paint": ["error", { maxNumericValue: 1800 }],
        "speed-index": ["error", { maxNumericValue: 3400 }],
      },
    },
    upload: {
      target: "filesystem",
      outputDir: "./.lighthouseci",
    },
  },
};
