import { test, expect } from "@playwright/test";

test.describe("Smoke tests", () => {
  test("should load the homepage", async ({ page }) => {
    await page.goto("/");
    await expect(page).toHaveTitle(/Claude Code Buddy/);
  });

  test("should have navigation links", async ({ page }) => {
    await page.goto("/");
    // The homepage links to the upload page (link text is Chinese, so match by
    // href rather than an English accessible name); SkinsSection + Footer both
    // render one, assert the first is visible.
    const uploadLink = page.locator('a[href="/upload"]').first();
    await expect(uploadLink).toBeVisible();
  });

  test("should navigate to upload page", async ({ page }) => {
    await page.goto("/upload");
    await expect(page.locator("body")).toBeVisible();
  });

  test("should navigate to admin page", async ({ page }) => {
    await page.goto("/admin");
    await expect(page.locator("body")).toBeVisible();
  });
});
