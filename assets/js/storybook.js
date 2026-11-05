// Injected before PhoenixStorybook's bundled JS. Must NOT create a LiveSocket or call `connect()` —
// see https://hexdocs.pm/phoenix_storybook/sandboxing.html — otherwise search, sidebar, and color
// mode hooks break (double LiveSocket / view binding races).
import { liveViewHooks } from "./liveview_hooks"
import { installStorybookIframeResize } from "./storybook_iframes"

installStorybookIframeResize(document)

window.storybook = {
  Hooks: { ...liveViewHooks }
}

// Storybook dark mode bridge: maps PhoenixStorybook color mode to app token attributes.
;(() => {
  const applyPsbTheme = (mode) => {
    const dark =
      (mode === "system" && window.matchMedia("(prefers-color-scheme: dark)").matches) ||
      mode === "dark"
    if (dark) {
      document.documentElement.setAttribute("data-theme", "dark")
      document.documentElement.setAttribute("data-zaq-theme", "dark")
    } else {
      document.documentElement.removeAttribute("data-theme")
      document.documentElement.removeAttribute("data-zaq-theme")
    }
  }
  const stored = localStorage.getItem("psb_selected_color_mode")
  if (stored) applyPsbTheme(stored)
  window.addEventListener("psb:set-color-mode", (e) => applyPsbTheme(e.detail?.mode || "system"))
})()
