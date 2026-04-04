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
- [ ] Ingestion webhooks for external notification on completion

---

## License (`docs/services/license.md`)

### Must Do
- [ ] Implement `LicensePostLoader.notify/2` — run bundled migrations and post-load hooks
- [ ] Document the `.zaq-license` build/signing process (for the license manager tool)

### Should Do
- [ ] Expose license status in BO (`license_live.ex` is stubbed)
- [ ] Validate `license_data["features"]` structure on load
- [ ] Handle license expiry gracefully at runtime (warn before expiry, disable after)

### Nice to Have
- [ ] Multiple license files support (already partially handled by watcher)
- [ ] License audit log (who loaded what and when)
- [ ] Grace period after expiry before hard cutoff

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