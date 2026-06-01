/**
 * Lighthouse CI 配置 — 本地 Core Web Vitals 性能预算门禁（Dim 11 / P1）。
 *
 * 用法：
 *   pnpm --filter @stringzhao/web lhci
 *   （等价 `next build && lhci autorun`：构建 → 起 next start:3000 → 采集 → 断言）
 *
 * upload 用 filesystem（产物落本地 .lighthouseci/，不外传），符合"本地配置"取向。
 * 断言用 'warn'：本地审计不硬失败，仅暴露预算回退；未来若入 CI 可改 'error' 当门禁。
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
        "categories:performance": ["warn", { minScore: 0.8 }],
        "categories:accessibility": ["warn", { minScore: 0.9 }],
        // Core Web Vitals（实验室口径）
        "largest-contentful-paint": ["warn", { maxNumericValue: 2500 }],
        "cumulative-layout-shift": ["warn", { maxNumericValue: 0.1 }],
        "total-blocking-time": ["warn", { maxNumericValue: 300 }],
        "first-contentful-paint": ["warn", { maxNumericValue: 1800 }],
        "speed-index": ["warn", { maxNumericValue: 3400 }],
      },
    },
    upload: {
      target: "filesystem",
      outputDir: "./.lighthouseci",
    },
  },
};
