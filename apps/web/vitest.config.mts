import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  resolve: {
    tsconfigPaths: true,
  },
  test: {
    environment: "jsdom",
    globals: true,
    exclude: ["e2e/**", "node_modules/**"],
    coverage: {
      provider: "v8",
      reporter: ["text", "text-summary", "lcov", "html"],
      include: ["src/**/*.{ts,tsx}"],
      exclude: [
        "src/**/*.d.ts",
        "src/**/__tests__/**",
        "src/**/__mocks__/**",
        "src/types.ts",
      ],
      // 回归地板（regression floor）：当前单元覆盖率基线 ~24%（statements 23.9 /
      // branches 26.2 / functions 22.2 / lines 23.9）。大组件/页面/引擎由
      // acceptance (vitest.config.ts) 与 E2E 覆盖，不在单元 config 命中范围。
      // 阈值设略低于基线以防退化，随单测补齐逐步上调（ratchet up）。
      thresholds: {
        statements: 20,
        branches: 20,
        functions: 18,
        lines: 20,
      },
    },
  },
});
