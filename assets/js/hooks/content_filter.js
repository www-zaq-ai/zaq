// ContentFilter hook — mounted on the wrapper div containing #chat-input.
// Detects "@<query>" typing in the textarea and drives the filter autocomplete.
//
// Folder selection drills in: "@za" → select "zaq" folder → textarea becomes "@zaq/"
// File selection completes with full path: "@zaq/" → select "report.pdf" → "@zaq/report.pdf"
// Arrow keys navigate the suggestion list; Enter selects; Escape dismisses.
const ContentFilter = {
  mounted() {
    this.textarea = this.el.querySelector("textarea")
    if (!this.textarea) return

    this._atPos = null
    this._currentQuery = null
    this._activeIndex = -1

    this._onInput = (e) => this.handleInput(e)
    this._onKeydown = (e) => this.handleKeydown(e)
    this._onClick = (e) => this.handleClick(e)

    this.textarea.addEventListener("input", this._onInput)
    // Capture phase so we intercept Enter before AutoExpand's bubble listener
    this.el.addEventListener("keydown", this._onKeydown, { capture: true })
    this.el.addEventListener("click", this._onClick)
  },

  destroyed() {
    if (this.textarea) {
      this.textarea.removeEventListener("input", this._onInput)
    }
    this.el.removeEventListener("keydown", this._onKeydown, { capture: true })
    this.el.removeEventListener("click", this._onClick)
  },

  handleInput(_e) {
    const ta = this.textarea
    const cursorPos = ta.selectionStart
    const textBeforeCursor = ta.value.slice(0, cursorPos)
    const match = textBeforeCursor.match(/(?:^|\s)@(\S*)$/)

    if (match) {
      const query = match[1]
      this._atPos = cursorPos - query.length - 1
      this._currentQuery = query
      this._activeIndex = -1
      this.pushEvent("filter_autocomplete", { query })
    } else {
      this._atPos = null
      this._currentQuery = null
      this._activeIndex = -1
      this.pushEvent("filter_autocomplete", { query: "" })
    }
  },

  handleKeydown(e) {
    const items = this.getSuggestionItems()
    if (items.length === 0) return

    if (e.key === "ArrowDown") {
      e.preventDefault()
      this._activeIndex = (this._activeIndex + 1) % items.length
      this.highlightActive(items)
    } else if (e.key === "ArrowUp") {
      e.preventDefault()
      this._activeIndex = this._activeIndex <= 0 ? items.length - 1 : this._activeIndex - 1
      this.highlightActive(items)
    } else if (e.key === "Escape") {
      e.preventDefault()
      this._activeIndex = -1
      this.pushEvent("filter_autocomplete", { query: "" })
    } else if (e.key === "Enter") {
      const target = this._activeIndex >= 0 ? items[this._activeIndex] : items[0]
      if (target) {
        // Prevent both the browser default and AutoExpand's form submission
        e.preventDefault()
        e.stopImmediatePropagation()
        this.selectSuggestion(target)
      }
    }
  },

  handleClick(e) {
    const selectBtn = e.target.closest("[data-select-folder-item]")
    if (selectBtn) {
      e.preventDefault()
      e.stopPropagation()
      this.selectFolderAsFilter(selectBtn)
      return
    }

    const item = e.target.closest("[data-suggestion-item]")
    if (item) {
      e.preventDefault()
      this.selectSuggestion(item)
    }
  },

  selectSuggestion(el) {
    const type = el.dataset.type
    const label = el.dataset.label
    const sourcePrefix = el.dataset.sourcePrefix
    const connector = el.dataset.connector

    const ta = this.textarea
    if (this._atPos === null) return

    const folderPrefix = this.getFolderPrefix()
    const before = ta.value.slice(0, this._atPos)
    const after = ta.value.slice(this._atPos + 1 + (this._currentQuery || "").length)

    if (type === "current_folder") {
      // The user is inside @folder/ and wants the folder itself as the filter.
      // label is e.g. "zaq"; _currentQuery is "zaq/" — replace the whole thing with "zaq ".
      const completion = label
      ta.value = before + "@" + completion + " " + after
      const newCursor = this._atPos + 1 + completion.length + 1
      ta.setSelectionRange(newCursor, newCursor)
      this._atPos = null
      this._currentQuery = null
      this._activeIndex = -1
      ta.dispatchEvent(new Event("input", { bubbles: true }))
      this.pushEvent("add_content_filter", { source_prefix: sourcePrefix, connector, label, type: "folder" })
    } else if (type === "folder") {
      const completion = folderPrefix + label + "/"
      ta.value = before + "@" + completion + after
      const newCursor = this._atPos + 1 + completion.length
      ta.setSelectionRange(newCursor, newCursor)
      this._currentQuery = completion
      this._activeIndex = -1
      ta.dispatchEvent(new Event("input", { bubbles: true }))
      this.pushEvent("filter_autocomplete", { query: completion })
    } else {
      const completion = folderPrefix + label
      ta.value = before + "@" + completion + " " + after
      const newCursor = this._atPos + 1 + completion.length + 1
      ta.setSelectionRange(newCursor, newCursor)
      this._atPos = null
      this._currentQuery = null
      this._activeIndex = -1
      ta.dispatchEvent(new Event("input", { bubbles: true }))
      this.pushEvent("add_content_filter", { source_prefix: sourcePrefix, connector, label, type })
    }
  },

  selectFolderAsFilter(el) {
    const ta = this.textarea
    if (this._atPos === null) return

    const sourcePrefix = el.dataset.sourcePrefix
    const connector = el.dataset.connector
    const label = el.dataset.label
    const type = el.dataset.type

    const folderPrefix = this.getFolderPrefix()
    const before = ta.value.slice(0, this._atPos)
    const after = ta.value.slice(this._atPos + 1 + (this._currentQuery || "").length)

    const completion = folderPrefix + label
    ta.value = before + "@" + completion + " " + after
    const newCursor = this._atPos + 1 + completion.length + 1
    ta.setSelectionRange(newCursor, newCursor)
    this._atPos = null
    this._currentQuery = null
    this._activeIndex = -1
    ta.dispatchEvent(new Event("input", { bubbles: true }))
    this.pushEvent("add_content_filter", { source_prefix: sourcePrefix, connector, label, type })
  },

  getFolderPrefix() {
    const q = this._currentQuery || ""
    const lastSlash = q.lastIndexOf("/")
    return lastSlash >= 0 ? q.slice(0, lastSlash + 1) : ""
  },

  getSuggestionItems() {
    return Array.from(this.el.querySelectorAll("[data-suggestion-item]"))
  },

  highlightActive(items) {
    items.forEach((item, i) => {
      if (i === this._activeIndex) {
        item.style.background = "#f0f9fb"
        item.scrollIntoView({ block: "nearest" })
      } else {
        item.style.background = ""
      }
    })
  }
}

export default ContentFilter
