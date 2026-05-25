import { test, expect } from "@playwright/test";

test.describe("Smoke tests", () => {
  test("should load the homepage", async ({ page }) => {
    await page.goto("/");
    await expect(page).toHaveTitle(/Claude Code Buddy/);
  });

  test("should have navigation links", async ({ page }) => {
    await page.goto("/");
    const uploadLink = page.getByRole("link", { name: /upload/i });
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
