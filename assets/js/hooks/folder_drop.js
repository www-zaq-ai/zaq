// FolderDrop — LiveView hook that intercepts folder drags onto the upload drop zone.
//
// Supported extensions intentionally match DocumentProcessor.@supported_extensions.
// Note: .txt is deliberately excluded here to avoid accepting files that pass upload
// but fail ingestion (pre-existing mismatch between @allowed_extensions and DocumentProcessor
// — tracked separately, out of scope for this feature).
const SUPPORTED_EXTENSIONS = [
  ".md",
  ".pdf",
  ".docx",
  ".pptx",
  ".xlsx",
  ".csv",
  ".png",
  ".jpg",
  ".jpeg",
]

// Must match allow_upload max_entries: 10 in IngestionLive.mount/3.
// Change both together.
const BATCH_SIZE = 10

/**
 * Returns the file extension (lowercase, including the dot) for the given filename.
 * Returns "" if no extension is found.
 */
function extname(filename) {
  const idx = filename.lastIndexOf(".")
  return idx > 0 ? filename.slice(idx).toLowerCase() : ""
}

/**
 * Recursively walks a FileSystemDirectoryEntry, collecting all FileSystemFileEntry
 * descendants. Calls `onDone(fileEntries)` when the walk is complete.
 *
 * Uses the paginated readEntries() loop (each call may return fewer than the
 * browser's internal page size; loop until an empty array is returned).
 */
function walkDirectory(dirEntry, onDone) {
  const fileEntries = []
  let pending = 0

  function readDir(entry) {
    const reader = entry.createReader()

    function readBatch() {
      reader.readEntries((entries) => {
        if (entries.length === 0) {
          // Done reading this directory
          if (--pending === 0) onDone(fileEntries)
          return
        }

        for (const child of entries) {
          if (child.isFile) {
            fileEntries.push(child)
          } else if (child.isDirectory) {
            pending++
            readDir(child)
          }
        }

        // readEntries may be paginated — loop until empty
        readBatch()
      })
    }

    readBatch()
  }

  pending = 1
  readDir(dirEntry)
}

/**
 * Resolves a list of FileSystemFileEntry objects to File objects concurrently.
 * Calls `onDone(files)` with the resolved File array in insertion order.
 */
function resolveFiles(fileEntries, onDone) {
  if (fileEntries.length === 0) {
    onDone([])
    return
  }

  const files = new Array(fileEntries.length).fill(null)
  let remaining = fileEntries.length

  fileEntries.forEach((entry, i) => {
    entry.file((file) => {
      // Phoenix LiveView reads webkitRelativePath to populate client_relative_path.
      // webkitRelativePath is configurable on File.prototype so we can shadow it
      // on the instance to carry the folder-relative path through to the server.
      Object.defineProperty(file, "webkitRelativePath", {
        value: entry.fullPath.replace(/^\//, ""),
        configurable: true,
      })
      files[i] = file
      if (--remaining === 0) onDone(files)
    })
  })
}

const FolderDrop = {
  mounted() {
    this._queue = []

    // Allow drag-over so the drop event can fire.
    this._onDragOver = (event) => {
      event.preventDefault()
      event.dataTransfer.dropEffect = "copy"
    }

    this._onDrop = (event) => {
      const items = Array.from(event.dataTransfer.items || [])

      // Collect directory entries — we need at least one to handle this as a folder drop.
      const dirEntries = items
        .map((item) => item.webkitGetAsEntry && item.webkitGetAsEntry())
        .filter((entry) => entry && entry.isDirectory)

      if (dirEntries.length === 0) {
        // No directories — reset queue so folder_batch_done is a no-op on the next
        // regular upload, then let LiveView handle the drop normally.
        this._queue = []
        return
      }

      // Confirmed folder drop — take ownership of the event.
      event.preventDefault()
      event.stopPropagation()

      const allFileEntries = []
      let pending = dirEntries.length

      dirEntries.forEach((dirEntry) => {
        walkDirectory(dirEntry, (fileEntries) => {
          allFileEntries.push(...fileEntries)
          if (--pending === 0) {
            resolveFiles(allFileEntries, (files) => {
              const supported = []
              const skipped = []

              for (const file of files) {
                const ext = extname(file.name)
                if (SUPPORTED_EXTENSIONS.includes(ext)) {
                  supported.push(file)
                } else {
                  skipped.push({
                    name: file.name,
                    path: file.relativePath || file.name,
                    reason: "unsupported_format",
                  })
                }
              }

              this._queue = supported

              this.pushEvent("folder_drop_skipped", { skipped })

              if (this._queue.length > 0) {
                this._injectNextBatch()
              }
            })
          }
        })
      })
    }

    this.el.addEventListener("dragover", this._onDragOver)
    this.el.addEventListener("drop", this._onDrop)

    // folder_batch_done is pushed by the server after each upload batch is consumed.
    // If the queue still has files, inject the next batch automatically.
    // This must be registered inside mounted() — it is NOT a top-level lifecycle key.
    this.handleEvent("folder_batch_done", () => {
      if (this._queue.length > 0) {
        this._injectNextBatch()
      }
    })
  },

  destroyed() {
    if (this._onDragOver) this.el.removeEventListener("dragover", this._onDragOver)
    if (this._onDrop) this.el.removeEventListener("drop", this._onDrop)
  },

  _injectNextBatch() {
    const form = this.el.closest("form")
    if (!form) return

    const input = form.querySelector("input[type=file]")
    if (!input) return

    const slice = this._queue.splice(0, BATCH_SIZE)

    const dt = new DataTransfer()
    for (const file of slice) {
      dt.items.add(file)
    }

    input.files = dt.files

    // Dispatch a synthetic change event so Phoenix LiveView's file input hook
    // picks up the newly injected files and queues them for upload.
    input.dispatchEvent(new Event("change", { bubbles: true }))

    // Auto-submit the form so the user does not need to click Upload for each batch.
    // The server will push folder_batch_done after consuming the batch, which
    // triggers _injectNextBatch() again for any remaining files.
    form.requestSubmit()
  },
}

export default FolderDrop
