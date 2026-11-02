// Runs in the browser, independently of Playwright's post-action trace capture.
// One collector per document; navigation creates a fresh collector automatically.
function installFlashObserver() {
  if (window !== window.top || window.__e2eFlashes) return
  const events = window.__e2eFlashes = []
  let seen = new WeakMap()
  window.__e2eArmFlashes = () => {
    events.length = 0
    seen = new WeakMap()
    for (const banner of document.querySelectorAll('[id^="flash-"], #ingest-toast')) {
      seen.set(banner, (banner.querySelector('.zaq-feedback-body') || banner).textContent.trim())
    }
  }
  const record = () => {
    for (const banner of document.querySelectorAll('[id^="flash-"], #ingest-toast')) {
      if (!banner.getClientRects().length || getComputedStyle(banner).visibility === "hidden") continue
      const text = (banner.querySelector('.zaq-feedback-body') || banner).textContent.trim()
      if (text && seen.get(banner) !== text) {
        events.push(text)
        seen.set(banner, text)
      }
    }
  }
  const observer = new MutationObserver(record)
  observer.observe(document, { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ['class', 'style', 'hidden'] })
  record()
}

module.exports = { installFlashObserver }
