const CSS = `
  .jt-root { line-height: 1.7; }
  .jt-entry { padding: 1px 0; }
  .jt-key { color: #1e293b; font-weight: 600; }
  .jt-str { color: #16a34a; }
  .jt-num { color: #2563eb; }
  .jt-bool { color: #d97706; }
  .jt-null { color: #94a3b8; font-style: italic; }
  .jt-punct { color: #94a3b8; }
  .jt-summary { color: #64748b; font-style: italic; font-size: 0.72em; }
  .jt-block { display: block; padding-left: 1.1rem; border-left: 2px solid #e2e8f0; margin: 2px 0; }
  .jt-btn {
    display: inline-flex; align-items: center; justify-content: center;
    width: 14px; height: 14px; border-radius: 3px;
    border: 1px solid #cbd5e1; background: #f8fafc; color: #475569;
    font-size: 10px; font-weight: 700; cursor: pointer; line-height: 1;
    vertical-align: middle; margin: 0 3px; font-family: ui-monospace, monospace;
    flex-shrink: 0; user-select: none;
  }
  .jt-btn:hover { background: #e2e8f0; color: #1e293b; border-color: #94a3b8; }
`

let _styleInjected = false
function injectStyle() {
  if (_styleInjected) return
  const s = document.createElement('style')
  s.textContent = CSS
  document.head.appendChild(s)
  _styleInjected = true
}

let _uid = 0
function uid() { return `jt-${++_uid}` }

function esc(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}

const MAX_STR = 100

function btn(id, summaryId, label) {
  return `<button class="jt-btn" data-toggle="${id}" data-summary="${summaryId}">${label}</button>`
}

function disp(hidden) {
  return hidden ? ' style="display:none"' : ''
}

function renderValue(v, depth, collapsed = true) {
  if (v === null) return `<span class="jt-null">null</span>`
  if (typeof v === 'boolean') return `<span class="jt-bool">${v}</span>`
  if (typeof v === 'number') return `<span class="jt-num">${v}</span>`

  if (typeof v === 'string') {
    if (v.length <= MAX_STR) return `<span class="jt-str">"${esc(v)}"</span>`
    const id = uid()
    const sid = uid()
    return [
      btn(id, sid, collapsed ? '+' : '−'),
      `<span id="${sid}"${disp(!collapsed)} class="jt-str">"${esc(v.slice(0, MAX_STR))}…"</span>`,
      `<span id="${id}"${disp(collapsed)} class="jt-block jt-str">"${esc(v)}"</span>`
    ].join('')
  }

  if (Array.isArray(v)) {
    if (v.length === 0) return `<span class="jt-punct">[]</span>`
    const id = uid()
    const sid = uid()
    const items = v.map((item, i) =>
      `<div class="jt-entry"><span class="jt-punct">${i}:</span> ${renderValue(item, depth + 1, depth >= 1)}</div>`
    ).join('')
    return [
      btn(id, sid, collapsed ? '+' : '−'),
      `<span id="${sid}"${disp(!collapsed)} class="jt-summary">[${v.length} ${v.length === 1 ? 'item' : 'items'}]</span>`,
      `<span id="${id}"${disp(collapsed)} class="jt-block">${items}</span>`
    ].join('')
  }

  if (typeof v === 'object') {
    const keys = Object.keys(v)
    if (keys.length === 0) return `<span class="jt-punct">{}</span>`
    const id = uid()
    const sid = uid()
    const entries = keys.map(k =>
      `<div class="jt-entry"><span class="jt-key">${esc(k)}:</span> ${renderValue(v[k], depth + 1, depth >= 1)}</div>`
    ).join('')
    return [
      btn(id, sid, collapsed ? '+' : '−'),
      `<span id="${sid}"${disp(!collapsed)} class="jt-summary">{${keys.length} ${keys.length === 1 ? 'key' : 'keys'}}</span>`,
      `<span id="${id}"${disp(collapsed)} class="jt-block">${entries}</span>`
    ].join('')
  }

  return esc(String(v))
}

function renderTree(data) {
  if (data === null || typeof data !== 'object' || Array.isArray(data)) {
    return `<div class="jt-entry">${renderValue(data, 0, false)}</div>`
  }
  return Object.entries(data).map(([k, v]) =>
    `<div class="jt-entry"><span class="jt-key">${esc(k)}:</span> ${renderValue(v, 0, false)}</div>`
  ).join('')
}

const JsonTree = {
  mounted() {
    injectStyle()
    this._render()
    this.el.addEventListener('click', e => {
      const b = e.target.closest('.jt-btn')
      if (!b) return
      const target = document.getElementById(b.dataset.toggle)
      if (!target) return
      const opening = target.style.display === 'none'
      target.style.display = opening ? '' : 'none'
      b.textContent = opening ? '−' : '+'
      const summary = document.getElementById(b.dataset.summary)
      if (summary) summary.style.display = opening ? 'none' : ''
    })
  },
  updated() { this._render() },
  _render() {
    try {
      const data = JSON.parse(this.el.dataset.json || 'null')
      this.el.innerHTML = `<div class="jt-root font-mono text-[0.78rem]">${renderTree(data)}</div>`
    } catch {
      this.el.textContent = this.el.dataset.json
    }
  }
}

export default JsonTree
