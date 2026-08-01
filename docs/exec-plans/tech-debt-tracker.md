# Tech Debt Tracker

All known gaps, deferred work, and shortcuts across the ZAQ codebase.
Sourced from service docs `What's Left` sections. Updated continuously.

**Priority scale**: Must Do · Should Do · Nice to Have

---

## Agent (`docs/services/agent.md`)

### Must Do
- [ ] Implement query extraction integration — connect Retrieval output → DocumentProcessor → Answering

### Should Do
- [ ] Knowledge gap tracking — detect unanswered questions, store for review
- [ ] Classifier module — route questions to different agents or topics
- [ ] Add Agent GenServers to `Zaq.Agent.Supervisor` when stateful components are needed

### Nice to Have
- [ ] Streaming responses for long answers
- [ ] Per-session LLM config overrides
- [ ] HTML parser for `DocumentChunker` (currently raises `"not implemented"`)

---

## BO Auth (`docs/services/bo-auth.md`)

### Must Do
- [ ] Add `remember me` functionality (persistent session/token)

### Should Do
- [ ] Role-based authorization plug (restrict routes by role)
- [ ] Flash messages styled consistently across BO
- [ ] Password reset flow (admin-initiated or self-service)

### Nice to Have
- [ ] Audit log for login attempts
- [ ] Session expiry / timeout
- [ ] Rate limiting on login
- [ ] Two-factor authentication

---

## Channels (`docs/services/channels.md`)

### Must Do
- [ ] Implement `forward_to_engine/1` — route incoming messages to the Agent pipeline via `NodeRouter`
- [ ] Connect channel responses back to Mattermost (answer → `API.send_message/3`)

### Should Do
- [ ] Slack retrieval adapter (`Zaq.Channels.Retrieval.Slack`)
- [ ] Email retrieval adapter (`Zaq.Channels.Retrieval.Email`)
- [ ] Google Drive ingestion adapter (`Zaq.Channels.Ingestion.GoogleDrive`)
- [ ] SharePoint ingestion adapter (`Zaq.Channels.Ingestion.SharePoint`)
- [ ] Reload retrieval supervisor when config changes in BO (currently requires restart)
- [ ] Standardize channel runtime config maps on one token key format, then remove dual `:token` / `"token"` handling in `ChannelConfig.to_runtime_config/1`

### Nice to Have
- [ ] Teams adapter
- [ ] Channel-level rate limiting
- [ ] Message queue for outbound messages under load

---

## Ingestion (`docs/services/ingestion.md`)

### Must Do
- [ ] Implement `FileExplorer` properly (currently referenced but not fully reviewed)

### Should Do
- [ ] Support non-markdown file types (PDF, DOCX) via `DocumentProcessor.Behaviour`
- [ ] Add chunk deduplication (same content, different source)
- [ ] Expose ingestion progress as percentage in `IngestJob`
- [ ] Batch/stream `prepare_file_chunks/3` payload persistence for very large documents

### Nice to Have
- [ ] Implement HTML parsing in `DocumentChunker`
- [ ] Batch embedding requests to reduce LLM roundtrips
- [ ] Outbound ingestion-completion notifications for external systems

---

## Addons (`docs/services/addons.md`)

### Must Do
- [ ] Implement `PostLoader.notify/2` — run bundled migrations and post-load hooks
- [ ] Document the `.zaq-license` build/signing process (for the add-on package builder)

### Should Do
- [ ] Expand add-on status in BO beyond the current upload/status page
- [ ] Validate `addon_data["features"]` structure on load
- [ ] Handle add-on package expiry gracefully at runtime (warn before expiry, disable after)

### Nice to Have
- [ ] Multiple add-on packages support
- [ ] Add-on audit log (who loaded what and when)
- [ ] Grace period after expiry before hard cutoff

---

## Workflows (`docs/services/workflows.md`)

### Nice to Have
- [ ] `EdgeStep` stays outside `StepRunner` — wrapping edges in `StepRunner` would
      give crash handling for free (instead of `EdgeStep`'s own `try/rescue` +
      idempotent guard-row writer), but changes row semantics (inputs/results
      recorded for every edge) and `DagBuilder` wiring. Out of scope for the
      2026-07-11 crash-visibility fix; see its Decisions Log.

---

## Ingestion

### Should Do
- [ ] **`FolderSetting` tags are not applied to newly created documents.**
      `Ingestion.set_folder_public/2` back-fills the `"public"` tag onto documents that
      already exist and writes a `folder_settings` row, but nothing consults that row when a
      document is created — `track_upload/2` and `RecordMaterializer.persist/2` both insert
      untagged. `DirectorySnapshot` is the only other reader, and only for display.

      Effect: marking a folder public today does **not** make tomorrow's uploads into it
      public. They silently stay private.

      Found while implementing skill reference materialization
      (`docs/exec-plans/active/skill-reference-materialization.md`). That plan works around
      it by tagging each file at write time rather than relying on folder inheritance —
      deliberately, to keep a skill-scoped change from altering permission behaviour for
      every ingestion folder. The general fix belongs here.

### Should Do
- [ ] **Python conversion steps report `:ok` on input they cannot parse.**
      `Zaq.Ingestion.Python.Steps.DocxToMd.run/2` (and `XlsxToMd`) given a file that is not
      a real document copy the input bytes through to the output path and return
      `{:ok, "  ✔  …"}`. Callers cannot distinguish "converted" from "gave up and copied".

      `ZaqWeb.Live.BO.AI.FilePreviewData` now guards against the visible symptom by checking
      the output is text before treating it as markdown, but that is a heuristic at the call
      site: a plain-text file named `.docx` still passes through and renders. The step
      itself should fail when it cannot parse its input, and the guard should then be
      redundant.

      Found when two `FilePreviewLiveTest` cases failed on a machine *with* Python — they
      had only ever passed where it was absent.

---

## CI / Linting

### Should Do
- [ ] Write custom linters for: structured logging, naming conventions, file size limits
- [ ] Add architectural layer enforcement via structural tests
- [ ] Add a doc-gardening agent task that scans for stale docs and opens fix-up PRs

---

## How to Use This File

- When starting a task, check if it's already tracked here.
- When completing a tracked item, check it off and note the PR.
- When introducing a known shortcut, add it here with a `TODO` referencing the issue.
- When a domain grade improves, update `docs/QUALITY_SCORE.md` accordingly.
