// Shared LiveView hook definitions for the main app (`app.js`) and PhoenixStorybook (`storybook.js`).
// Storybook must not import `app.js`: PhoenixStorybook bundles its own LiveSocket and calls `connect()`.
import { hooks as colocatedHooks } from "phoenix-colocated/zaq"
import OntologyTree from "./hooks/ontology_tree_hook"
import ChartTooltip from "./hooks/chart_tooltip_hook"
import ContentFilter from "./hooks/content_filter"
import FolderDrop from "./hooks/folder_drop"
import DialogOverlay from "./hooks/dialog_overlay"
import { SearchableSelectHook } from "./hooks/searchable_select_hook"

export const liveViewHooks = {
  ...colocatedHooks,
  OntologyTree,
  ChartTooltip,
  ContentFilter,
  FolderDrop,
  DialogOverlay,
  DownloadFile: {
    mounted() {
      this.handleEvent("download_file", ({ filename, content, content_type }) => {
        const blob = new Blob([content], { type: content_type })
        const url = URL.createObjectURL(blob)
        const a = document.createElement("a")
        a.href = url
        a.download = filename
        document.body.appendChild(a)
        a.click()
        document.body.removeChild(a)
        URL.revokeObjectURL(url)
      })
    }
  },
  FocusAndSelect: {
    mounted() {
      this.el.focus()
      this.el.select()
    },
    updated() {
      this.el.focus()
    }
  },
  FlashAutoDismiss: {
    mounted() {
      this._scrollToFlash()
      this._startTimer()
    },
    updated() {
      this._scrollToFlash()
      clearTimeout(this._timer)
      this._startTimer()
    },
    destroyed() {
      clearTimeout(this._timer)
    },
    _scrollToFlash() {
      requestAnimationFrame(() => {
        const top = this.el.getBoundingClientRect().top + window.scrollY - 16
        window.scrollTo({ top: Math.max(0, top), behavior: "smooth" })
      })
    },
    _startTimer() {
      const duration = parseInt(this.el.dataset.autoDismissDuration, 10)
      if (duration > 0) {
        this._timer = setTimeout(() => {
          this.el.querySelector("[data-flash-dismiss]")?.click()
        }, duration)
      }
    }
  },
  LoadingActionButton: {
    mounted() {
      this._syncDisabled = () => {
        if (!this.el.classList.contains("phx-click-loading")) {
          this.el.disabled = false
        }
      }

      this._onClick = () => {
        // Defer disabling so LiveView can capture and push the click event first.
        requestAnimationFrame(() => {
          this.el.disabled = true
        })
      }

      this.el.addEventListener("click", this._onClick)

      this._observer = new MutationObserver(() => this._syncDisabled())
      this._observer.observe(this.el, { attributes: true, attributeFilter: ["class"] })

      this._onLoadingStop = () => this._syncDisabled()
      window.addEventListener("phx:page-loading-stop", this._onLoadingStop)
    },
    updated() {
      this._syncDisabled()
    },
    destroyed() {
      if (this._onClick) {
        this.el.removeEventListener("click", this._onClick)
        this._onClick = null
      }

      if (this._observer) {
        this._observer.disconnect()
        this._observer = null
      }

      if (this._onLoadingStop) {
        window.removeEventListener("phx:page-loading-stop", this._onLoadingStop)
        this._onLoadingStop = null
      }

      this._syncDisabled = null
    }
  },
  CopyToClipboard: {
    mounted() {
      this.el.addEventListener("click", () => {
        const url = this.el.dataset.shareUrl
        if (!url) return
        navigator.clipboard.writeText(url).then(() => {
          const orig = this.el.textContent
          this.el.textContent = "Copied!"
          setTimeout(() => {
            this.el.textContent = orig
          }, 1500)
        }).catch(() => {
          const orig = this.el.textContent
          this.el.textContent = "Failed"
          setTimeout(() => {
            this.el.textContent = orig
          }, 1500)
        })
      })
    }
  },
  ScrollBottom: {
    mounted() {
      this.el.scrollTop = this.el.scrollHeight
    },
    updated() {
      this.el.scrollTop = this.el.scrollHeight
    }
  },
  DetectTimezone: {
    mounted() {
      const offsetMinutes = new Date().getTimezoneOffset()
      this.pushEvent("detect_timezone", { offset: offsetMinutes })
    }
  },
  FocusInput: {
    mounted() {
      this.el.focus()
    },
    updated() {
      if (!this.el.disabled) this.el.focus()
    }
  },
  OAuthPopupListener: {
    mounted() {
      this._popup = null

      this.handleEvent("open_oauth_popup", ({ url }) => {
        if (!url) return

        const width = 640
        const height = 760
        const left = Math.max(0, Math.floor((window.screen.width - width) / 2))
        const top = Math.max(0, Math.floor((window.screen.height - height) / 2))
        const features = `popup=yes,width=${width},height=${height},left=${left},top=${top},resizable=yes,scrollbars=yes`

        this._popup = window.open(url, "oauth_claim_popup", features)

        if (!this._popup) {
          this.pushEvent("oauth_popup_blocked", {})
        }
      })

      this._handler = (event) => {
        const data = event && event.data
        const payload = data && data.payload
        if (event.origin !== window.location.origin) return
        if (!this._popup || event.source !== this._popup) return
        if (!data || data.type !== "zaq:oauth2_result") return
        if (!payload || !["success", "error"].includes(payload.status)) return
        this.pushEvent("oauth_popup_result", data.payload || {})

        if (this._popup && !this._popup.closed) {
          this._popup.close()
        }

        this._popup = null
      }

      window.addEventListener("message", this._handler)
    },
    destroyed() {
      if (this._handler) {
        window.removeEventListener("message", this._handler)
        this._handler = null
      }
    }
  },
  SearchableSelect: SearchableSelectHook,
  ScrollToFirstError: {
    updated() {
      requestAnimationFrame(() => {
        const firstError = this.el.querySelector("[data-error-message]")
        if (firstError && firstError.textContent.trim()) {
          const top = firstError.getBoundingClientRect().top + window.scrollY - 80
          window.scrollTo({ top: Math.max(0, top), behavior: "smooth" })
        }
      })
    }
  },
  DetailsKeepOpen: {
    mounted() {
      this._open = this.el.open
    },
    updated() {
      this.el.open = this._open
    },
    beforeUpdate() {
      this._open = this.el.open
    }
  },
  AutoExpand: {
    mounted() {
      const el = this.el

      // Only grow from real content. Empty fields otherwise pick up a huge `scrollHeight`
      // from the wrapped placeholder, which misaligns the send button beside the composer.
      this.resize = () => {
        if (!el.value) {
          el.style.height = ""
          return
        }

        el.style.height = "auto"
        el.style.height = Math.min(el.scrollHeight, 160) + "px"
      }

      el.addEventListener("input", this.resize)

      el.addEventListener("keydown", (e) => {
        if (e.key === "Enter" && !e.shiftKey) {
          e.preventDefault()
          const form = el.closest("form")
          if (form) form.requestSubmit()
        } else if (e.key === "Enter" && e.shiftKey) {
          // newline inserted by browser — resize after DOM updates
          setTimeout(this.resize, 0)
        }
      })

      if (el.value) this.resize()
    },
    updated() {
      if (this.el.value === "") {
        this.el.style.height = ""
      } else {
        this.resize()
      }
    }
  }
}
