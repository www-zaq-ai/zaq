<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->

## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, complete all of the following:

1. **File issues for remaining work** - Create issues for anything that needs follow-up.
2. **Run quality gates** (if code changed) - Tests, linters, builds.
3. **Update issue status** - Close finished work, update in-progress items.
4. **Sync beads data** - Run `bd dolt pull` and resolve any issue-state drift.
5. **Commit local changes** - Ensure code and beads metadata are committed according to the repo workflow.
6. **Hand off** - Provide clear context for the next session (what is done, what is blocked, and what is next).

**Important:**

- Follow the repository's current git workflow (branching, push/merge policy) defined in `AGENTS.md`, `docs/workflows.md`, and session context.
- Do not assume push-to-remote is always required; use the active workflow for this environment.
<!-- END BEADS INTEGRATION -->
