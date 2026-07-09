// MarkdownHighlight — client-side syntax highlighting for rendered markdown
// code blocks in the skill instructions preview (and any other surface that
// mounts this hook on a `.markdown-preview` container).
//
// The server renders fenced code blocks as `<pre><code class="language-xxx">`
// (Earmark). highlight.js reads that class, tokenizes the source, and wraps
// tokens in `<span class="hljs-*">` which the scoped theme in
// `assets/css/highlight.css` colors. Languages outside the bundled set fall
// back to the plain monochrome block.
//
// Runs on mount and on every LiveView patch (e.g. live preview updates as the
// author types), re-querying fresh nodes each time since the server replaces
// the innerHTML with un-highlighted markup.
import hljs from "../../vendor/highlight.js"

function highlightWithin(el) {
  el.querySelectorAll("pre code").forEach((block) => {
    // Fresh server markup is never pre-highlighted; guard is belt-and-suspenders.
    if (block.dataset.highlighted === "yes") return

    // Earmark emits a bare language class (e.g. `class="elixir"`), not the
    // `language-xxx` form highlight.js auto-detects, so read it explicitly.
    const cls = (block.className || "").trim()
    const lang = cls.replace(/^(language|lang)-/, "").split(/\s+/)[0]

    try {
      if (lang && hljs.getLanguage(lang)) {
        const result = hljs.highlight(block.textContent, {
          language: lang,
          ignoreIllegals: true,
        })
        block.innerHTML = result.value
        block.classList.add("hljs")
        block.dataset.highlighted = "yes"
      } else {
        // Unknown/absent language: let highlight.js decide (auto-detect or plain).
        hljs.highlightElement(block)
      }
    } catch (_e) {
      // Never let a highlighter hiccup break the LiveView; leave the raw block.
    }
  })
}

const MarkdownHighlight = {
  mounted() {
    highlightWithin(this.el)
  },
  updated() {
    highlightWithin(this.el)
  },
}

export default MarkdownHighlight
