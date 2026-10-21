// Viewer-local observation time, not an execution timestamp or persisted duration.
// Keep the hook element stable across message patches; terminal durations belong
// to the server. A genuine remount starts a fresh estimate on this page.
export const ToolStepTimer = {
  mounted() {
    this._interval = null
    this._observedAt = null
    this._identity = null
    this._disconnected = false
    this._sync()
  },
  updated() {
    this._sync()
  },
  disconnected() {
    this._disconnected = true
    this._stop()
  },
  reconnected() {
    this._disconnected = false
    this._sync()
  },
  destroyed() {
    this._stop()
    this._observedAt = null
  },
  _sync() {
    const identity = this.el.dataset.toolStepId
    if (identity !== this._identity) {
      this._stop()
      this._observedAt = null
      this._identity = identity
    }

    if (this.el.dataset.toolState !== "running") {
      this._stop()
      this._observedAt = null
      return
    }

    if (this._observedAt === null) this._observedAt = performance.now()
    this._tick()
    if (!this._disconnected && this._interval === null) {
      this._interval = setInterval(() => this._tick(), 1000)
    }
  },
  _tick() {
    if (this._disconnected || this._observedAt === null || this.el.dataset.toolState !== "running") return
    const duration = this.el.querySelector("[data-tool-duration]")
    if (!duration) return
    const seconds = Math.max(0, Math.floor((performance.now() - this._observedAt) / 1000))
    duration.textContent = `~${seconds} s`
  },
  _stop() {
    if (this._interval !== null) clearInterval(this._interval)
    this._interval = null
  }
}
