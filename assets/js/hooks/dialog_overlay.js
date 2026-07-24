const FOCUSABLE_SELECTOR =
  'a[href], button:not([disabled]), textarea:not([disabled]), input:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])'

function focusableElements(root) {
  return [...root.querySelectorAll(FOCUSABLE_SELECTOR)].filter((el) => {
    return el.getAttribute("aria-hidden") !== "true" && !el.closest("[hidden]")
  })
}

const DialogOverlay = {
  mounted() {
    this._previouslyFocused = document.activeElement
    this._panel = this.el.querySelector("[data-drawer-panel]")

    this._previousBodyOverflow = document.body.style.overflow
    document.body.style.overflow = "hidden"

    this._onKeyDown = (event) => this._handleKeyDown(event)
    this.el.addEventListener("keydown", this._onKeyDown)

    requestAnimationFrame(() => this._focusInitial())
  },

  updated() {
    if (document.body.style.overflow !== "hidden") {
      document.body.style.overflow = "hidden"
    }
  },

  destroyed() {
    document.body.style.overflow = this._previousBodyOverflow || ""
    this.el.removeEventListener("keydown", this._onKeyDown)

    const returnFocusId = this.el.dataset.returnFocusId
    const returnTarget = returnFocusId
      ? document.getElementById(returnFocusId)
      : this._previouslyFocused

    if (returnTarget && typeof returnTarget.focus === "function") {
      returnTarget.focus()
    }
  },

  _focusInitial() {
    const root = this._panel || this.el
    const focusables = focusableElements(root)
    if (focusables.length > 0) {
      focusables[0].focus()
    } else if (root && typeof root.focus === "function") {
      root.focus()
    }
  },

  _handleKeyDown(event) {
    if (event.key !== "Tab") return

    const root = this._panel || this.el
    const focusables = focusableElements(root)

    if (focusables.length === 0) {
      event.preventDefault()
      return
    }

    const first = focusables[0]
    const last = focusables[focusables.length - 1]
    const active = document.activeElement

    if (event.shiftKey && active === first) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && active === last) {
      event.preventDefault()
      first.focus()
    }
  }
}

export default DialogOverlay
