# README interface previews

These images are browser captures of the real Back Office with synthetic demo configuration, not mockups or evidence of completed agent/workflow runs.

- Capture date: 2026-09-22.
- Source application: repository revision `e094f88a`, with documentation-only working changes.
- Environment: local E2E server with a separate `_readme` database partition; no production records or real credentials.
- Viewport: 1440 × 1000, light theme.
- Agent examples: Knowledge Assistant, Onboarding Guide, Operations Coordinator; an illustrative local Ollama configuration. No model server was contacted.
- Workflow example: a draft human-review checkpoint. No workflow execution results are simulated.

When refreshing the images, use populated demo configuration through the real application, inspect every visible field for sensitive content, and retain captions distinguishing configuration from execution. Do not capture prototype routes as shipped behavior or edit the page DOM to fabricate product capabilities.

The documentation build copies `docs/images` so the README images also resolve in the published ExDoc site.
