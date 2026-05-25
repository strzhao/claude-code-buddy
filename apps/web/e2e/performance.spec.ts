import { test, expect } from "@playwright/test";

test.describe("Performance", () => {
  test("should load homepage within acceptable time", async ({ page }) => {
    const startTime = Date.now();
    await page.goto("/");
    await page.waitForLoadState("domcontentloaded");
    const loadTime = Date.now() - startTime;

    // Homepage should load within 5 seconds (generous for dev server)
    expect(loadTime).toBeLessThan(5000);
  });

  test("should collect navigation timing metrics", async ({ page }) => {
    await page.goto("/");
    await page.waitForLoadState("load");

    const metrics = await page.evaluate(() => {
      const entries = performance.getEntriesByType("navigation") as PerformanceNavigationTiming[];
      if (entries.length === 0) return null;
      const nav = entries[0];
      return {
        domContentLoaded: nav.domContentLoadedEventEnd - nav.startTime,
        loadComplete: nav.loadEventEnd - nav.startTime,
        ttfb: nav.responseStart - nav.requestStart,
      };
    });

    expect(metrics).not.toBeNull();
    if (metrics) {
      // DOM content loaded should be under 3 seconds
      expect(metrics.domContentLoaded).toBeLessThan(3000);
    }
  });
});
