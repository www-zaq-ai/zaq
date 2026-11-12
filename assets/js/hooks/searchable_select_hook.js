// Shared SearchableSelect LiveView hook — used by app.js and liveview_hooks.js.
export const SearchableSelectHook = {
  mounted() {
    const root = this.el
    this._search = ""
    this._open = false

    const hidden = () => root.querySelector("input[type=hidden][data-select-value]")
    const trigger = () => root.querySelector("[data-select-trigger]")
    const panel = () => root.querySelector("[data-select-panel]")
    const search = () => root.querySelector("[data-select-search]")
    const list = () => root.querySelector("[data-select-list]")
    const labelEl = () => root.querySelector("[data-select-label]")
    const createBtn = () => root.querySelector("[data-select-create]")
    const clearBtn = () => root.querySelector("[data-select-clear]")

    const pushScopedEvent = (event, payload) => {
      const context = JSON.parse(root.dataset.eventContext || "{}")
      const params = { ...context, ...payload }
      const target = root.dataset.eventTarget
      if (target) {
        this.pushEventTo(/^\d+$/.test(target) ? Number(target) : target, event, params)
      } else {
        this.pushEvent(event, params)
      }
    }

    const filter = (q) => {
      this._search = q
      let visibleCount = 0
      let exactMatch = false
      list().querySelectorAll("[data-select-option]").forEach((opt) => {
        const visible = opt.dataset.selectOption.toLowerCase().includes(q.toLowerCase())
        opt.style.display = visible ? "" : "none"
        if (visible) visibleCount++
        if (opt.dataset.selectOption.toLowerCase() === q.toLowerCase()) exactMatch = true
      })
      const btn = createBtn()
      if (btn) {
        const canCreate = root.dataset.createOnNoExactMatch === "true" ? !exactMatch : visibleCount === 0
        if (q.trim().length > 0 && canCreate) {
          btn.classList.remove("hidden")
          const lbl = btn.querySelector("[data-create-label]")
          if (lbl) lbl.textContent = `+ Add "${q}"`
        } else {
          btn.classList.add("hidden")
        }
      }
    }

    const panelContentWidth = () => {
      const triggerWidth = trigger().getBoundingClientRect().width
      let maxOption = 0
      const listEl = list()
      if (listEl) {
        listEl.querySelectorAll("[data-select-option]").forEach((opt) => {
          maxOption = Math.max(maxOption, opt.scrollWidth)
        })
      }
      const optionPad = 32
      return Math.ceil(Math.max(triggerWidth, maxOption + optionPad))
    }

    const positionPanel = () => {
      const rect = trigger().getBoundingClientRect()
      const p = panel()
      const listEl = list()
      const margin = 4
      const viewportH = window.innerHeight
      const spaceBelow = viewportH - rect.bottom - margin
      const spaceAbove = rect.top - margin
      const placeAbove = spaceBelow < 200 && spaceAbove > spaceBelow
      const width = panelContentWidth()

      p.style.position = "fixed"
      p.style.zIndex = "9999"
      p.style.width = `${width}px`
      p.style.minWidth = `${width}px`
      p.style.maxWidth = `${width}px`
      p.style.left = `${rect.left}px`

      if (listEl) {
        const room = (placeAbove ? spaceAbove : spaceBelow) - 60
        listEl.style.maxHeight = `${Math.max(96, Math.min(208, room))}px`
      }

      if (placeAbove) {
        p.style.top = `${Math.max(margin, rect.top - p.offsetHeight - margin)}px`
      } else {
        p.style.top = `${rect.bottom + margin}px`
      }
    }

    const openPanel = () => {
      if (trigger().disabled) return
      this._open = true
      panel().classList.remove("hidden")
      positionPanel()
      trigger().setAttribute("aria-expanded", "true")
      if (search()) {
        search().value = ""
        search().focus()
      }
      filter("")
      if (root.dataset.serverSearch) pushScopedEvent(root.dataset.serverSearch, { query: "" })
    }

    const closePanel = () => {
      this._open = false
      const p = panel()
      p.classList.add("hidden")
      p.style.position = ""
      p.style.width = ""
      p.style.minWidth = ""
      p.style.maxWidth = ""
      p.style.left = ""
      p.style.top = ""
      trigger().setAttribute("aria-expanded", "false")
    }

    this._reposition = () => {
      if (this._open) positionPanel()
    }
    window.addEventListener("scroll", this._reposition, true)
    window.addEventListener("resize", this._reposition)

    const selectOption = (value, label) => {
      hidden().value = value
      if (clearBtn()) clearBtn().hidden = value === ""
      labelEl().textContent = label
      closePanel()
      const opts = { bubbles: true }
      hidden().dispatchEvent(new Event("input", opts))
      hidden().dispatchEvent(new Event("change", opts))
    }

    trigger().addEventListener("click", (e) => {
      e.preventDefault()
      this._open ? closePanel() : openPanel()
    })

    clearBtn()?.addEventListener("click", (e) => {
      e.preventDefault()
      e.stopPropagation()
      if (trigger().disabled) return
      const empty = [...list().querySelectorAll("[data-select-option]")].find(
        (option) => option.dataset.selectValue === ""
      )
      selectOption("", empty?.dataset.selectOption || root.dataset.emptyLabel || "Select...")
      trigger().focus()
    })

    this._outsideClick = (e) => {
      // Flash auto-dismiss clicks its close button programmatically, not as user intent.
      if (e.isTrusted && !root.contains(e.target)) closePanel()
    }
    document.addEventListener("click", this._outsideClick, true)

    if (search()) {
      search().addEventListener("input", (e) => {
        e.stopPropagation()
        this._search = search().value
        // Empty/unchanged server results may produce no LiveView DOM patch.
        // Keep filtering and the create action responsive without waiting for updated().
        filter(this._search)
        positionPanel()
        const serverSearch = root.dataset.serverSearch
        if (serverSearch) {
          clearTimeout(this._searchTimer)
          this._searchTimer = setTimeout(() => {
            pushScopedEvent(serverSearch, { query: this._search })
          }, 300)
        }
      })
      search().addEventListener("change", (e) => {
        e.stopPropagation()
      })

      search().addEventListener("keydown", (e) => {
        if (e.key === "Escape") {
          e.stopPropagation()
          closePanel()
        }
        if (e.key === "Enter") {
          e.preventDefault()
          const visible = [...list().querySelectorAll("[data-select-option]")].find(
            (o) => o.style.display !== "none" && o.dataset.selectDisabled !== "true"
          )
          const btn = createBtn()
          const canCreate = btn && !btn.classList.contains("hidden") && this._search.trim().length > 0
          // Opt-in value pickers must not replace typed values with a partial match.
          if (canCreate && (root.dataset.createOnNoExactMatch === "true" || !visible)) {
            const eventName = btn.dataset.createEvent || "create_and_assign_team"
            pushScopedEvent(eventName, { name: this._search })
            closePanel()
          } else if (visible) {
            selectOption(visible.dataset.selectValue, visible.dataset.selectOption)
          }
        }
      })
    }

    list().addEventListener("click", (e) => {
      const opt = e.target.closest("[data-select-option]")
      if (opt && opt.dataset.selectDisabled === "true") return
      if (opt) selectOption(opt.dataset.selectValue, opt.dataset.selectOption)
    })

    const btn = createBtn()
    if (btn) {
      btn.addEventListener("click", (e) => {
        e.preventDefault()
        e.stopPropagation()
        const eventName = btn.dataset.createEvent || "create_and_assign_team"
        pushScopedEvent(eventName, { name: this._search })
        closePanel()
      })
    }

    this._hidden = hidden
    this._labelEl = labelEl
    this._list = list
    this._panel = panel
    this._filter = filter
    this._positionPanel = positionPanel
  },
  updated() {
    const panel = this._panel && this._panel()

    if (this._open && panel) {
      panel.classList.remove("hidden")
      if (this._filter) this._filter(this._search || "")
      if (this._positionPanel) this._positionPanel()
    }

    const hidden = this._hidden && this._hidden()
    const labelEl = this._labelEl && this._labelEl()
    const list = this._list && this._list()
    if (!hidden || !labelEl || !list) return
    const current = hidden.value
    for (const opt of list.querySelectorAll("[data-select-option]")) {
      if (opt.dataset.selectValue === current) {
        labelEl.textContent = opt.dataset.selectOption
        return
      }
    }
  },
  destroyed() {
    if (this._outsideClick) document.removeEventListener("click", this._outsideClick, true)
    if (this._reposition) {
      window.removeEventListener("scroll", this._reposition, true)
      window.removeEventListener("resize", this._reposition)
    }
    clearTimeout(this._searchTimer)
  }
}
