# Memory maintenance entry point

- Authoritative organization, ownership, style and update criteria: [documentation hygiene](../../docs/documentation.md#serena-memory-hygiene). Read it before writing memories; repository standards stay in docs.
- Discovery starts at `mem:core`; focused topics use `<domain>/core`. Keep notes dense: owner links, source entry points, a few durable non-obvious pitfalls. No task-local progress or copied validation manuals.
- Cross-memory references use backticked `mem:` names, e.g. `mem:frontend/core`, with text explaining what the target helps discover. Referring memories own read-routing guidance.
- Use Serena's rename tool for memory moves so references are updated. Run `serena memories check` from the project root after reference changes; separately verify doc links and meaning.
- Tool exposure/fallback behavior belongs to [agent tools](../../docs/agent-tools.md), not this content policy pointer.
