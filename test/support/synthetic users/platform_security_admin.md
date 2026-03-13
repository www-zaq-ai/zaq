# Synthetic Persona: Platform and Security Admin (Operator)

## Subagent Plan
- Subagent name: `subagent_platform_security_operator`
- Objective: guarantee secure access, governance controls, channel connectivity, and runtime health checks remain stable across dev updates.
- Scope: authentication and password policy, user/role lifecycle, channel configuration and tests, diagnostics, and license visibility.
- Primary UI surfaces: `/bo/login`, `/bo/change-password`, `/bo/users`, `/bo/roles`, `/bo/channels`, `/bo/channels/retrieval/:provider`, `/bo/dashboard`, `/bo/ai-diagnostics`, `/bo/license`.
- Expected deliverable from this subagent: operational QA journeys with explicit controls and failure-sensitive checkpoints.

## Top Journeys

### Journey 1: Secure login and forced password rotation
Sequence of pages visited:
1. `/bo/login`
2. `/bo/change-password`
3. `/bo/dashboard`

| Page visited | Elements seen | Elements interacted with |
| --- | --- | --- |
| `/bo/login` | Username/password fields, remember checkbox `input[name="remember"]`, login CTA | Submit initial credentials |
| `/bo/change-password` | Password form `#change-password-form`, requirement list `#password-requirements`, confirmation status `#password-confirmation-status`, submit CTA | Enter invalid password first (expect requirement failures), then valid password + matching confirmation, submit |
| `/bo/dashboard` | Service status table, user metric, license card | Confirm redirect success and authenticated operator state |

### Journey 2: Role-based governance and account lifecycle
Sequence of pages visited:
1. `/bo/roles`
2. `/bo/roles/new`
3. `/bo/users`
4. `/bo/users/new`

| Page visited | Elements seen | Elements interacted with |
| --- | --- | --- |
| `/bo/roles` | Roles table with user counts and meta column | Click `+ New Role`, optionally edit/delete existing roles |
| `/bo/roles/new` | Role form fields (`role[name]`, `role[meta]`) | Create role with metadata JSON and submit |
| `/bo/users` | Users table with status badges and actions | Click `+ New User`, verify role options include newly created role |
| `/bo/users/new` | User form with username/password/role selectors, password requirements panel `#password-requirements` | Create user with compliant password and selected role, submit, verify return to list |

### Journey 3: Retrieval channel configuration, test, and activation
Sequence of pages visited:
1. `/bo/channels`
2. `/bo/channels/retrieval`
3. `/bo/channels/retrieval/mattermost`

| Page visited | Elements seen | Elements interacted with |
| --- | --- | --- |
| `/bo/channels` | Category cards `#category-card-retrieval`, `#category-card-ingestion` | Click retrieval category card |
| `/bo/channels/retrieval` | Provider cards with IDs like `#channel-card-mattermost` | Click Mattermost provider card |
| `/bo/channels/retrieval/mattermost` | Config list cards `#config-card-*`, add CTA `#new-config-button`, config form `#config-form`, test modal form `#test-connection-form`, retrieval channels list `#retrieval-channel-*` | Add or edit config, run connection test, enable/disable config (`#toggle-config-*`), browse teams/channels, add retrieval channel, pause/activate channel, remove via `#remove-retrieval-channel-button` |

### Journey 4: Operational readiness checks (services, AI, licensing)
Sequence of pages visited:
1. `/bo/dashboard`
2. `/bo/ai-diagnostics`
3. `/bo/license`

| Page visited | Elements seen | Elements interacted with |
| --- | --- | --- |
| `/bo/dashboard` | Service rows (Engine/Agent/Ingestion/Channels/Back Office), status badges, node column | Validate required services are `Running`; confirm node attribution is present |
| `/bo/ai-diagnostics` | LLM/Embedding/Ingestion cards, status badges, test buttons (`Test Connection`, `Test TokenEstimator`) | Run LLM and embedding connectivity checks, run token estimator check, confirm status transitions (`idle` -> `loading` -> `ok` or error) |
| `/bo/license` | License state card, features list, expiry and days-left indicators, sales CTA when unlicensed | Verify key metadata rendering and feature availability state (licensed vs locked) |
