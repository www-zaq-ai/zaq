// ContentFilter hook — mounted on the wrapper div containing #chat-input.
// Detects "@<query>" typing in the textarea and drives the filter autocomplete.
// When a suggestion is selected, replaces @<query> with @<label> in-place.
const ContentFilter = {
  mounted() {
    this.textarea = this.el.querySelector("textarea")
    if (!this.textarea) return

    this._atPos = null
    this._currentQuery = null

    this._onInput = (e) => this.handleInput(e)
    this.textarea.addEventListener("input", this._onInput)

    this.handleEvent("complete_filter_mention", ({ label }) => {
      const ta = this.textarea
      if (!label || this._atPos === null) return

      const atPos = this._atPos
      const queryLen = (this._currentQuery || "").length
      const before = ta.value.slice(0, atPos)
      const after = ta.value.slice(atPos + 1 + queryLen)

      ta.value = before + "@" + label + " " + after

      const newCursor = atPos + 1 + label.length + 1
      ta.setSelectionRange(newCursor, newCursor)
      ta.dispatchEvent(new Event("input", { bubbles: true }))

      this._atPos = null
      this._currentQuery = null
    })
  },

  destroyed() {
    if (this.textarea && this._onInput) {
      this.textarea.removeEventListener("input", this._onInput)
    }
  },

  handleInput(_e) {
    const ta = this.textarea
    const cursorPos = ta.selectionStart
    const textBeforeCursor = ta.value.slice(0, cursorPos)

    // Match "@<word>" immediately before the cursor, preceded by start or whitespace
    const match = textBeforeCursor.match(/(?:^|\s)@(\S*)$/)

    if (match) {
      const query = match[1]
      // Position of the "@" character
      this._atPos = cursorPos - query.length - 1
      this._currentQuery = query
      this.pushEvent("filter_autocomplete", { query })
    } else {
      this._atPos = null
      this._currentQuery = null
      this.pushEvent("filter_autocomplete", { query: "" })
    }
  }
}

export default ContentFilter
