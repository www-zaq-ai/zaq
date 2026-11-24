// Fixed positioning lets label results escape the modal's scrolling body.
export default {
  mounted() {
    this.reposition = () => {
      const input = this.el.querySelector("input[type=search]")
      const results = this.el.querySelector("[data-label-results]")
      if (!input || !results) return

      const rect = input.getBoundingClientRect()
      const gap = 4
      const below = window.innerHeight - rect.bottom - gap
      const above = rect.top - gap
      const placeAbove = below < 200 && above > below
      const room = Math.max(0, (placeAbove ? above : below) - gap)

      Object.assign(results.style, {
        left: `${rect.left}px`,
        width: `${rect.width}px`,
        maxHeight: `${Math.min(256, room)}px`,
        top: placeAbove ? "auto" : `${rect.bottom + gap}px`,
        bottom: placeAbove ? `${window.innerHeight - rect.top + gap}px` : "auto"
      })
    }

    window.addEventListener("scroll", this.reposition, true)
    window.addEventListener("resize", this.reposition)
    this.observer = new ResizeObserver(this.reposition)
    this.observer.observe(this.el)
    this.reposition()
  },

  updated() {
    this.reposition()
  },

  destroyed() {
    window.removeEventListener("scroll", this.reposition, true)
    window.removeEventListener("resize", this.reposition)
    this.observer.disconnect()
  }
}
