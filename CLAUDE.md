# Claude Agent Entry Point

@AGENTS.md

Follow the task-based loading requirements in `AGENTS.md`; do not import the whole documentation map. Read `DESIGN.md` before BO/UI work only.

When delegating, explicitly pass the applicable policy paths if they are not inherited. Use only tools exposed to that agent; follow `docs/agent-tools.md` for bounded fallbacks. Do not assume automatic prompt injection or tool access.
