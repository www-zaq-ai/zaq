# Quality Score

This document grades each product domain and architectural layer.
Updated by the team and by the doc-gardening agent on a regular cadence.

**Grade scale**: A (excellent) · B (good) · C (needs work) · D (critical gaps)

---

## Domain Grades

| Domain | Grade | Notes |
|---|---|---|
| `accounts` | B | Auth, roles, users complete. Missing: remember me, role-based authz, password reset. |
| `agent` | C | Core pipeline done. Query extraction integration pending. No streaming, no classifier. |
| `channels` | C | Mattermost retrieval works. `forward_to_engine/1` is a stub. Slack/Email/Drive not implemented. |
| `engine` | B | Supervisors, contracts, conversations context solid. Retrieval routing to agent pending. |
| `ingestion` | B | Full async pipeline with chunk retries. PDF/DOCX not supported. HTML parser raises. |
| `license` | C | Load/verify/decrypt pipeline done. `LicensePostLoader` not implemented. BO UI stubbed. |
| `embedding` | A | Standalone, well-tested, mockable. No known gaps. |
| `node_router` | A | Core routing logic solid. Well-tested. |

---

## Architectural Layer Grades

| Layer | Grade | Notes |
|---|---|---|
| Context boundaries | B | Mostly enforced. Some LiveViews still call context internals directly. |
| Test coverage | C | Unit tests solid in most domains. E2E coverage thin. LiveView tests sparse. |
| Documentation | B | Service docs complete. Exec plans and quality tracking newly introduced. |
| Observability | C | Telemetry buffer in place. Metric coverage uneven across domains. |
| Security | B | Secret encryption enforced. PromptGuard in place. Auth plug solid. Rate limiting missing. |
| CI / Linting | B | `mix precommit` enforced. Custom linters not yet written. |

---

## Last Updated

Update this line when grades change: `2026-04-04`

---

## How to Update

When you complete work in a domain or fix a known gap:
1. Re-assess the grade based on the current state.
2. Update the notes to reflect what changed.
3. Update the "Last Updated" date.
4. If a gap is resolved, remove it from `docs/exec-plans/tech-debt-tracker.md`.