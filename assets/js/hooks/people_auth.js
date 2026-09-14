// HTTP forms deliberately keep credential verification outside LiveView messages.
export const PeopleAuthForm = {
  mounted() {
    this.onSubmit = () => {
      this.el.querySelectorAll("button").forEach(button => { button.disabled = true })
    }
    this.el.addEventListener("submit", this.onSubmit)
  },
  destroyed() { this.el.removeEventListener("submit", this.onSubmit) }
}

export const PeopleOTP = {
  mounted() {
    this.input = this.el.querySelector("input[autocomplete='one-time-code']")
    this.submitting = false
    this.onInput = () => {
      const raw = this.input.value.replace(/[\s-]/g, "")
      // Never silently remove invalid characters; the backend validates all input.
      if (/^[0-9]{0,8}$/.test(raw)) {
        this.input.value = raw.length > 4 ? `${raw.slice(0, 4)}-${raw.slice(4)}` : raw
      }
    }
    this.onSubmit = () => {
      this.submitting = true
      this.el.querySelectorAll("button").forEach(button => { button.disabled = true })
    }
    this.input.addEventListener("input", this.onInput)
    this.el.addEventListener("submit", this.onSubmit)
    this.tick = () => {
      const seconds = Math.max(0, Math.ceil((Date.parse(this.el.dataset.expiresAt) - Date.now()) / 1000))
      const label = this.el.querySelector("[data-countdown]")
      label.textContent = seconds > 0 ? `Code expires in ${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}` : "Code expired. Request a new code."
      const remaining = Math.max(0, Math.ceil((Date.parse(this.el.dataset.resendAvailableAt) - Date.now()) / 1000)) || 0
      const resend = this.el.querySelector("#people-resend")
      if (this.submitting) {
        this.el.querySelectorAll("button").forEach(button => { button.disabled = true })
      }
      resend.disabled = this.submitting || remaining > 0
      this.el.querySelector("[data-resend-countdown]").textContent = remaining > 0
        ? `Resend in ${String(Math.floor(remaining / 60)).padStart(2, "0")}:${String(remaining % 60).padStart(2, "0")}`
        : "Resend code"
    }
    this.tick()
    this.timer = setInterval(this.tick, 1000)
  },
  updated() { this.tick() },
  disconnected() { clearInterval(this.timer) },
  reconnected() {
    this.tick()
    clearInterval(this.timer)
    this.timer = setInterval(this.tick, 1000)
  },
  destroyed() {
    clearInterval(this.timer)
    this.input.removeEventListener("input", this.onInput)
    this.el.removeEventListener("submit", this.onSubmit)
  }
}
