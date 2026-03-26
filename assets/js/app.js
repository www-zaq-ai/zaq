// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/zaq"
import topbar from "../vendor/topbar"
import OntologyTree from "./hooks/ontology_tree_hook"
import ChartTooltip from "./hooks/chart_tooltip_hook"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {
    ...colocatedHooks,
    OntologyTree,
    ChartTooltip,
    DownloadFile: {
      mounted() {
        this.handleEvent("download_file", ({ filename, content, content_type }) => {
          const blob = new Blob([content], { type: content_type });
          const url = URL.createObjectURL(blob);
          const a = document.createElement("a");
          a.href = url;
          a.download = filename;
          document.body.appendChild(a);
          a.click();
          document.body.removeChild(a);
          URL.revokeObjectURL(url);
        });
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
    CopyToClipboard: {
      mounted() {
        this.el.addEventListener("click", () => {
          const url = this.el.dataset.shareUrl
          if (!url) return
          navigator.clipboard.writeText(url).then(() => {
            const orig = this.el.textContent
            this.el.textContent = "Copied!"
            setTimeout(() => { this.el.textContent = orig }, 1500)
          }).catch(() => {
            const orig = this.el.textContent
            this.el.textContent = "Failed"
            setTimeout(() => { this.el.textContent = orig }, 1500)
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
    Typewriter: {
      mounted() {
        const el = this.el
        const full = el.innerHTML
        if (!full || !full.trim()) return

        el.innerHTML = ""
        el.style.visibility = "visible"

        let i = 0
        const speed = 8

        const type = () => {
          if (i <= full.length) {
            el.innerHTML = full.slice(0, i)
            i++
            setTimeout(type, speed)
          }
        }

        type()
      },
      updated() {
        // intentional no-op — never let LiveView re-trigger typing
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
    SearchableSelect: {
      mounted() {
        const root = this.el
        this._search = ''
        this._open = false

        const hidden = () => root.querySelector('input[type=hidden][data-select-value]')
        const trigger = () => root.querySelector('[data-select-trigger]')
        const panel = () => root.querySelector('[data-select-panel]')
        const search = () => root.querySelector('[data-select-search]')
        const list = () => root.querySelector('[data-select-list]')
        const labelEl = () => root.querySelector('[data-select-label]')

        const filter = (q) => {
          this._search = q
          list().querySelectorAll('[data-select-option]').forEach(opt => {
            opt.style.display = opt.dataset.selectOption.toLowerCase().includes(q.toLowerCase()) ? '' : 'none'
          })
        }

        const openPanel = () => {
          this._open = true
          panel().classList.remove('hidden')
          search().value = ''
          filter('')
          search().focus()
        }

        const closePanel = () => {
          this._open = false
          panel().classList.add('hidden')
        }

        const selectOption = (value, label) => {
          hidden().value = value
          labelEl().textContent = label
          closePanel()
          hidden().dispatchEvent(new Event('input', { bubbles: true }))
        }

        trigger().addEventListener('click', (e) => {
          e.preventDefault()
          this._open ? closePanel() : openPanel()
        })

        this._outsideClick = (e) => { if (!root.contains(e.target)) closePanel() }
        document.addEventListener('click', this._outsideClick, true)

        search().addEventListener('input', () => filter(search().value))

        list().addEventListener('click', (e) => {
          const opt = e.target.closest('[data-select-option]')
          if (opt) selectOption(opt.dataset.selectValue, opt.dataset.selectOption)
        })

        search().addEventListener('keydown', (e) => {
          if (e.key === 'Escape') { e.stopPropagation(); closePanel() }
          if (e.key === 'Enter') {
            e.preventDefault()
            const visible = [...list().querySelectorAll('[data-select-option]')].find(o => o.style.display !== 'none')
            if (visible) selectOption(visible.dataset.selectValue, visible.dataset.selectOption)
          }
        })

        this._hidden = hidden
        this._labelEl = labelEl
        this._list = list
        this._filter = filter
      },
      updated() {
        if (this._open && this._filter) this._filter(this._search || '')
        const hidden = this._hidden && this._hidden()
        const labelEl = this._labelEl && this._labelEl()
        const list = this._list && this._list()
        if (!hidden || !labelEl || !list) return
        const current = hidden.value
        for (const opt of list.querySelectorAll('[data-select-option]')) {
          if (opt.dataset.selectValue === current) { labelEl.textContent = opt.dataset.selectOption; return }
        }
      },
      destroyed() {
        if (this._outsideClick) document.removeEventListener('click', this._outsideClick, true)
      }
    },
    AutoExpand: {
      mounted() {
        const el = this.el

        this.resize = () => {
          el.style.height = "auto"
          el.style.height = Math.min(el.scrollHeight, 160) + "px"
        }

        el.addEventListener("input", this.resize)

        el.addEventListener("keydown", (e) => {
          if (e.key === "Enter" && !e.shiftKey) {
            e.preventDefault()
            const form = el.closest("form")
            if (form) form.dispatchEvent(new Event("submit", { bubbles: true }))
          } else if (e.key === "Enter" && e.shiftKey) {
            // newline inserted by browser — resize after DOM updates
            setTimeout(this.resize, 0)
          }
        })

        this.resize()
      },
      updated() {
        if (this.el.value === "") {
          this.el.style.height = "auto"
        } else {
          this.resize()
        }
      }
    }
  },
})

// ── BO Layout: sidebar + collapsible nav sections ──────────────────────────
function toggleSidebar() {
  const sidebar = document.getElementById('bo-sidebar')
  const main = document.getElementById('bo-main')
  sidebar.classList.toggle('collapsed')
  main.classList.toggle('collapsed')
  localStorage.setItem('sidebar-collapsed', sidebar.classList.contains('collapsed'))
}

function setSectionOpenClass(id) {
  const wrapper = document.getElementById(id)
  const items = document.getElementById(id + '-items')
  if (!wrapper || !items) return
  if (items.classList.contains('closed')) {
    wrapper.classList.remove('section-open')
  } else {
    wrapper.classList.add('section-open')
  }
}

function toggleSection(id) {
  const items = document.getElementById(id + '-items')
  const chevron = document.getElementById(id + '-chevron')
  if (!items) return
  items.classList.toggle('closed')
  chevron && chevron.classList.toggle('open')
  localStorage.setItem('section-' + id, items.classList.contains('closed') ? 'closed' : 'open')
  setSectionOpenClass(id)
}

function restoreLayout() {
  const sidebar = document.getElementById('bo-sidebar')
  const main = document.getElementById('bo-main')
  if (!sidebar || !main) return

  if (localStorage.getItem('sidebar-collapsed') === 'true') {
    sidebar.classList.add('collapsed')
    main.classList.add('collapsed')
  } else {
    sidebar.classList.remove('collapsed')
    main.classList.remove('collapsed')
  }

  ;['section-ai', 'section-communication', 'section-accounts'].forEach(function (id) {
    const state = localStorage.getItem('section-' + id)
    if (!state) return
    const items = document.getElementById(id + '-items')
    const chevron = document.getElementById(id + '-chevron')
    if (!items) return
    if (state === 'closed') {
      items.classList.add('closed')
      chevron && chevron.classList.remove('open')
    } else {
      items.classList.remove('closed')
      chevron && chevron.classList.add('open')
    }
    setSectionOpenClass(id)
  })
}

window.toggleSidebar = toggleSidebar
window.toggleSection = toggleSection
restoreLayout()
window.addEventListener('phx:page-loading-stop', restoreLayout)

// Clipboard copy via push_event
window.addEventListener("phx:clipboard", (e) => {
  if (e.detail && e.detail.text) {
    navigator.clipboard.writeText(e.detail.text)
  }
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}