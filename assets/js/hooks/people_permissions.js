// LiveView can omit unchanged checked attributes after a rejected/no-op write.
// The server's refresh generation guarantees updated runs even for equal data.
export default {
  updated() {
    this.el.querySelectorAll('input[role="switch"]').forEach(input => {
      input.checked = input.getAttribute("aria-checked") === "true"
    })
  },
}
