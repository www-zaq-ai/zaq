const { test, expect, request: apiRequest } = require("@playwright/test");
const {
  gotoBackOfficeLive,
  loginToBackOffice,
  resetE2EState,
  setE2ESystemConfig,
} = require("../support/bo");

test.describe("Version update badge", () => {
  test.beforeAll(async () => {
    const req = await apiRequest.newContext();
    await resetE2EState(req);
    await req.dispose();
  });

  test("shows version and update badge with correct link attributes when enabled", async ({
    page,
    request,
  }) => {
    await resetE2EState(request);
    await setE2ESystemConfig(request, "ui.update_badge_enabled", "true");

    await loginToBackOffice(page);
    await gotoBackOfficeLive(page, "/bo/dashboard");

    const enabledVersionText = await page.locator(".sidebar-version").textContent();
    expect((enabledVersionText || "").trim()).toMatch(/^v\S+$/);

    const badgeLink = page.locator("#sidebar-version-update-badge");
    await expect(badgeLink).toBeVisible();
    await expect(badgeLink).toHaveAttribute(
      "href",
      "https://github.com/www-zaq-ai/zaq/releases"
    );
    await expect(badgeLink).toHaveAttribute("target", "_blank");
    await expect(badgeLink).toHaveAttribute("rel", "noopener noreferrer");
  });

  test("shows version and hides update badge when disabled", async ({ page, request }) => {
    await resetE2EState(request);
    await setE2ESystemConfig(request, "ui.update_badge_enabled", "false");

    await loginToBackOffice(page);
    await gotoBackOfficeLive(page, "/bo/dashboard");

    const disabledVersionText = await page.locator(".sidebar-version").textContent();
    expect((disabledVersionText || "").trim()).toMatch(/^v\S+$/);
    await expect(page.locator("#sidebar-version-update-badge")).toHaveCount(0);
  });
});
