const { test, expect } = require("@playwright/test");

// Matches the transient LiveSocket init race filtered in stories.spec.js
const LIVESOCKET_INIT_ERROR = /Cannot bind multiple views|already been bound to a view/;

// Foundation token values from foundations.css
const LIGHT = {
  blue400: "rgb(2, 117, 137)",      // #027589
  black400: "rgb(12, 19, 36)",      // #0C1324
};
const DARK = {
  blue400: "rgb(10, 173, 202)",     // #0aadca
  black400: "rgb(243, 245, 247)",   // #F3F5F7
};

async function waitForStory(page, url) {
  const errors = [];
  page.on("pageerror", (e) => {
    if (!LIVESOCKET_INIT_ERROR.test(e.message)) errors.push(e.message);
  });
  await page.goto(url);
  await page.locator("div#story-live").waitFor({ timeout: 10_000 });
  await page.waitForLoadState("networkidle");
  await page.addStyleTag({ content: "*, *::before, *::after { transition-duration: 0ms !important; }" });
  if (errors.length > 0) throw new Error(`Page error at ${url}:\n${errors.join("\n")}`);
}

async function setDarkMode(page) {
  await page.evaluate(() => {
    window.dispatchEvent(new CustomEvent("psb-set-color-mode", { detail: { mode: "dark" } }));
  });
}

async function setLightMode(page) {
  await page.evaluate(() => {
    window.dispatchEvent(new CustomEvent("psb-set-color-mode", { detail: { mode: "light" } }));
  });
}

async function getTokenValue(page, token) {
  return page.evaluate((t) => {
    const el = document.createElement("div");
    el.style.cssText = `display:none;background-color:var(${t})`;
    document.documentElement.appendChild(el);
    const rgb = getComputedStyle(el).backgroundColor;
    el.remove();
    return rgb;
  }, token);
}

test.describe("Storybook dark mode bridge", () => {
  test("on-load sync: data-theme=dark is applied from localStorage before navigation", async ({ page }) => {
    // Set the Storybook localStorage key before navigating — tests the bridge's load-time path
    await page.addInitScript(() => {
      localStorage.setItem("psb_selected_color_mode", "dark");
    });

    await waitForStory(page, "/storybook/foundations/palette");

    await expect(page.locator("html")).toHaveAttribute("data-zaq-theme", "dark");
  });

  test("toggle: psb-set-color-mode switches data-theme on and off", async ({ page }) => {
    await waitForStory(page, "/storybook/foundations/palette");

    // Start in light (no data-zaq-theme)
    await expect(page.locator("html")).not.toHaveAttribute("data-zaq-theme");

    // Switch to dark
    await setDarkMode(page);
    await expect(page.locator("html")).toHaveAttribute("data-zaq-theme", "dark");

    // Switch back to light
    await setLightMode(page);
    await expect(page.locator("html")).not.toHaveAttribute("data-zaq-theme");
  });

  test("palette: foundation tokens resolve to correct values per theme", async ({ page }) => {
    await waitForStory(page, "/storybook/foundations/palette");

    // Light mode values
    const lightBlue = await getTokenValue(page, "--zaq-color-blue-400");
    expect(lightBlue).toBe(LIGHT.blue400);

    const lightBlack = await getTokenValue(page, "--zaq-color-black-400");
    expect(lightBlack).toBe(LIGHT.black400);

    // Dark mode values
    await setDarkMode(page);

    const darkBlue = await getTokenValue(page, "--zaq-color-blue-400");
    expect(darkBlue).toBe(DARK.blue400);

    const darkBlack = await getTokenValue(page, "--zaq-color-black-400");
    expect(darkBlack).toBe(DARK.black400);
  });

  test("sandbox: text color switches in dark mode (regression guard for legacy --zaq-color-ink)", async ({ page }) => {
    await waitForStory(page, "/storybook/foundations/palette");

    const sandbox = page.locator(".zaq-sandbox").first();

    // Light mode — text should be dark ink (black-400 light value)
    const lightColor = await sandbox.evaluate((el) =>
      getComputedStyle(el).color
    );
    expect(lightColor).toBe(LIGHT.black400);

    // Dark mode — text should flip to light (black-400 dark value)
    await setDarkMode(page);
    const darkColor = await sandbox.evaluate((el) =>
      getComputedStyle(el).color
    );
    expect(darkColor).toBe(DARK.black400);
  });

  test("button playground: primary button background and secondary text switch in dark mode", async ({ page }) => {
    await waitForStory(page, "/storybook/playground/button_playground");

    const primaryBtn = page.locator(".zaq-btn-primary").first();
    const secondaryBtn = page.locator(".zaq-btn-secondary").first();

    // Light: primary bg = blue-400 light
    const lightPrimaryBg = await primaryBtn.evaluate((el) =>
      getComputedStyle(el).backgroundColor
    );
    expect(lightPrimaryBg).toBe(LIGHT.blue400);

    // Light: secondary text = black-200 light = rgb(67, 83, 109) (#43536d)
    const lightSecondaryText = await secondaryBtn.evaluate((el) =>
      getComputedStyle(el).color
    );
    expect(lightSecondaryText).toBe("rgb(67, 83, 109)");

    // Dark
    await setDarkMode(page);

    // Dark: primary bg = blue-400 dark
    const darkPrimaryBg = await primaryBtn.evaluate((el) =>
      getComputedStyle(el).backgroundColor
    );
    expect(darkPrimaryBg).toBe(DARK.blue400);

    // Dark: secondary text = black-200 dark = rgb(160, 178, 200) (#A0B2C8)
    const darkSecondaryText = await secondaryBtn.evaluate((el) =>
      getComputedStyle(el).color
    );
    expect(darkSecondaryText).toBe("rgb(160, 178, 200)");
  });
});
