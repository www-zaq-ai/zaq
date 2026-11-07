// PhoenixStorybook 1.3's inline auto-resizer assumes the iframe survives its
// delayed measurement. LiveView can replace it first. Replace only that handler
// at the capture phase, before it schedules the unsafe callback; keep isolation.
export function installStorybookIframeResize(document, schedule = setTimeout) {
  const managed = new WeakSet()

  document.addEventListener("load", ({ target: frame }) => {
    if (frame?.tagName !== "IFRAME" || !frame.closest("#psb-story-live")) return

    const inline = frame.getAttribute("onload") || ""
    if (!managed.has(frame) && !inline.includes("contentWindow.document.body.scrollHeight")) return

    managed.add(frame)
    frame.removeAttribute("onload")

    const resize = () => {
      if (!frame.isConnected) return
      const body = frame.contentDocument?.body
      if (body) frame.style.height = `${body.scrollHeight}px`
    }

    resize()
    schedule(resize, 100)
  }, true)
}
