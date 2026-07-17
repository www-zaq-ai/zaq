---
name: leakage-check
description: Scans the edited files of the current branch (or a given diff/PR) for cross-boundary concern leakage — channel/adapter logic leaking into Engine modules, channel-specific knowledge (email, Mattermost) in generic modules, direct Bridge/adapter calls outside the channel layer, subset-only callbacks on global behaviours, BO web code bypassing NodeRouter, test-only affordances in production code, circular layer seams (A→B→A), and modules reading keys out of values contracted as opaque. Follows every seam touching an edited file to its far end (even into unedited files) and reconciles findings against unresolved PR reviewer threads. Identifies the exact file:line of every leak and drafts an implementation plan to fix them in docs/exec-plans/active/. Use whenever the user asks to check for leakage, boundary violations, separation-of-concerns problems, or "concerns leaking" into a module, or before requesting re-review on a PR that previously had leakage findings. Detection and planning only — never implements the fixes.
---

# Leakage Check

Act as a strict architecture reviewer for ZAQ module boundaries. Find every place where a concern leaks across a boundary in the **edited files**, pin each leak to exact lines, and draft an implementation plan to fix them. Do NOT implement anything.

## What "leakage" means in ZAQ

A module may only contain knowledge that belongs to its layer. A leak is any of:

| # | Leak type | Definition | Canonical example (PR #557) |
|---|---|---|---|
| L1 | **Engine → Channels call** | `lib/zaq/engine/**` calling `Zaq.Channels.*` (Bridge, adapters, EmailBridge, Mattermost) directly. Engine must consume pre-computed values, not derive them. | `Conversations` computing `Bridge.conversation_key(msg, channel_type)`; `Notifications` calling `Bridge.outbound_conversation_key/3` |
| L2 | **Channel-specific knowledge in generic modules** | Email/Mattermost/provider-specific logic, literals, or field names inside channel-agnostic modules (Conversations, Notifications, Engine, Workflows, Agent). Includes Message-ID minting, threading headers, provider-atom branching. | Email threading logic in `Conversations`; `EmailUtils.new_message_id` in `Notifications` |
| L3 | **Subset-only callbacks on global behaviours** | A behaviour/protocol declaring callbacks that only a subset of implementers can meaningfully implement. | `conversation_key/1` on the global `Bridge` behaviour when only conversation channels have one |
| L4 | **Web → service direct call** | `lib/zaq_web/**` calling `Zaq.Agent.*`, `Zaq.Engine.*`, `Zaq.Ingestion.*`, or `Zaq.Channels.*` directly instead of `NodeRouter.dispatch/1` with `%Zaq.Event{}`. | Any direct context call from a BO LiveView |
| L5 | **Provider/credential logic outside its home** | Provider-atom normalisation, URL detection, or credential resolution outside `Zaq.Agent.ProviderSpec` / `Factory` (see AGENTS.md Agent Service Rules). | `ServerManager` inspecting provider URLs |
| L6 | **Test-only affordances in production code** | Branches, options, or functions in `lib/` that exist only so a test can hook in. | `step_runner.ex` test hook that was moved into the test |
| L7 | **Config access outside Zaq.Config** | `System.get_env/fetch_env` or raw `Application.get_env` for runtime-configurable values in feature modules instead of `Zaq.Config`. | env-var read in `run_agent.ex` |
| L8 | **Circular layer seam** | Layer A calls layer B for work that immediately calls back into layer A (e.g. Channels delivering mail via an Engine notification module that wraps `Zaq.Channels.SmtpHelpers`). Each direction may look legal in isolation; the cycle means the responsibility has no home. | `EmailBridge.send_reply` → `Engine.Notifications.EmailNotification` → `Channels.SmtpHelpers` |
| L9 | **Opaque-contract violation** | A module reading specific keys out of a value another layer contracted as opaque (comments/docs saying "stored and read back opaquely", generic anchors, provider payloads) — including via SQL fragments (`->`/`->>` on JSONB). | `Conversations` filtering on `metadata -> 'threading' -> 'anchor' ->> 'message_id'` |

When judging L1/L2, direction matters: the channel layer MAY know about Engine schemas; Engine must NOT know about channel mechanics. The fix direction is always "compute in the channel node (adapter/bridge), pass the result in." But a legal direction does not excuse a cycle — if the callee bounces back into the caller's layer, that is L8 regardless of direction.

## Steps

### 1. Resolve the file set

Default scope: files changed on the current branch vs the merge base with `main`:

```sh
git diff --name-only --diff-filter=ACMR "$(git merge-base main HEAD)"...HEAD -- 'lib/**/*.ex' 'lib/**/*.heex'
```

Also include uncommitted changes (`git diff --name-only HEAD` + staged). Only `.ex`/`.heex` files under `lib/` are in scope — tests cannot leak by definition (but note L6 candidates they reveal).

**Always compute the branch-wide file list first, even when the user narrows scope.** If the user names specific files, a single commit, or a diff, scan that set — but list every other branch-changed `lib/` file under a "**Not scanned (changed on this branch)**" line in the plan header. A leakage check that silently drops branch files produces a false clean bill: PR #557's open findings (`conversations.ex`, `notifications.ex`, `bridge.ex`) were all missed by a single-commit run. If the narrowed set omits engine or channels files that the branch touched, say so explicitly in the chat output too.

If the file set is empty, say so and stop.

### 2. Classify each file into a layer

| Layer | Paths |
|---|---|
| `web` | `lib/zaq_web/**` |
| `engine` | `lib/zaq/engine/**` |
| `channels` | `lib/zaq/channels/**` |
| `agent` | `lib/zaq/agent/**` |
| `ingestion` | `lib/zaq/ingestion/**` |
| `shared` | `lib/zaq/utils/**`, `lib/zaq/config*`, other cross-cutting |

### 3. Scan for leaks — mechanical pass

Run the greps in the sandbox (`ctx_execute` / `ctx_batch_execute`) so raw output stays out of context; carry over only file:line + matched line. For each edited file, scan the **whole file** (not just changed hunks — a leak next to your edit is still your finding), but report which findings touch changed lines vs pre-existing ones.

Signals per leak type:

- **L1:** `Zaq.Channels`, `alias .*Channels\.` , `Bridge\.` inside `lib/zaq/engine/**`
- **L2:** case-insensitive `email|smtp|imap|message_id|message-id|in_reply_to|mattermost|slack|sending_domain|EmailUtils` inside engine/agent generic modules; provider-atom branching (`case .*provider`, `:email ->`, `:mattermost ->`) outside `lib/zaq/channels/**`
- **L3:** in behaviour modules, callbacks listed in `@optional_callbacks` that only some implementers define — cross-check with `grep -l "def <callback>" lib/zaq/channels/`
- **L4:** `Zaq.Agent\.|Zaq.Engine\.|Zaq.Ingestion\.|Zaq.Channels\.` inside `lib/zaq_web/**` (excluding `NodeRouter`)
- **L5:** `base_url|api_key|provider` handling in `lib/zaq/agent/**` outside `provider_spec.ex`, `factory.ex`
- **L6:** `Mix.env|:test|Application.get_env(:zaq, :test` branches in `lib/`; options only ever passed from `test/`; module-injection config keys set exclusively from `test/`
- **L7:** `System.get_env|System.fetch_env` in `lib/` outside `Zaq.Config` and `runtime.exs`-adjacent modules
- **L8:** in `lib/zaq/channels/**`, aliases/calls to `Zaq.Engine.*` — then check whether the engine target calls back into `Zaq.Channels.*`
- **L9:** words like `opaque|opaquely|anchor` in comments/docs near a returned map, cross-checked with `-> '<key>'|->> '<key>'|Map.get\(.*"<key>"` on those keys in other layers (grep `metadata ->|->> '` in `lib/zaq/engine/**`)

**Follow every seam to its far end.** A seam has two sides; an edited file is only one of them. When an edited file returns a value consumed by, or calls into, another layer, grep for the consuming/called module and judge that code too — even if it was not edited on this branch. A leak found at the far end of a seam touching an edited file is a full finding (mark it "far end of edited seam, file not in diff"), not a borderline note. This is exactly how `conversations.ex:478` reading the "opaque" anchor was missed: the run saw it and demoted it to out-of-scope.

### 4. Judge each hit — semantic pass

Greps produce candidates, not findings. For each hit, read the surrounding code and decide:

- **Leak** — knowledge crossed a boundary; record file, exact line(s), leak type, one-sentence statement of what leaked and where it belongs.
- **Legitimate** — e.g. `Zaq.Channels.Bridge` referenced from within the channel layer, a `@moduledoc` mentioning email, dispatch through an injected module. Discard silently unless borderline.
- **Borderline** — record it with the reasoning; the plan lists it under "Needs a human call".

Never report a finding you cannot pin to a concrete line. Never invent leaks to fill categories.

### 5. Reconcile with existing human review

Before writing the plan, check for prior human findings on this branch:

- `ls docs/exec-plans/active/ | grep -i review` — a `pr-*-review-plan.md` for this branch lists reviewer threads.
- If the branch has an open PR, fetch unresolved review threads (`gh pr view --json reviews` / GraphQL `reviewThreads`) when a review plan doc doesn't already capture them.

Map every **unresolved architecture/boundary thread** to one of your findings. For each one with no matching finding, either (a) its file is outside the scanned scope — add it to the "Not scanned" list and say the check cannot clear it, or (b) it is in scope and you judged it clean — record that as an explicit rebuttal in "Needs a human call" with your reasoning. A leakage check run before re-requesting review must never be silent about an open reviewer thread.

### 6. Draft the implementation plan

Write to `docs/exec-plans/active/leakage-fix-plan-<branch-or-pr>.md` (kebab-case the branch name). Structure:

```markdown
# Leakage Fix Plan — <branch or PR>

**Scope:** <N files scanned, diff base>
**Not scanned (changed on this branch):** <files, or "none — full branch diff scanned">
**Generated:** <date>
**Findings:** <N leaks, M borderline, files affected>
**Reviewer threads reconciled:** <N unresolved threads → matched findings / rebuttals, or "no open PR review">

---

## Summary

| Leak type | Count | Files |
|---|---|---|
| L1 Engine → Channels call | N | ... |
| ... (omit zero rows) |

---

## Findings

### Finding N — [L1] `path/file.ex:214-215`
**What leaked:** <one sentence — what knowledge, from which layer, into which module>
**Evidence:**
> <the offending line(s), quoted verbatim>

**Where it belongs:** <the module/layer that should own this computation>
**Fix:** <2-4 sentences: the concrete refactor — what moves where, what the leaking module receives instead, signature changes if visible>
**Introduced by this branch:** yes / no (pre-existing)

---

## Needs a human call

*(borderline items with reasoning — omit if empty)*

---

## Implementation Order

<Group findings that are one refactor family (same seam) into a single step. Order: structural moves first (behaviour splits, new callbacks), then call-site migrations, then deletions.>

---

## Definition of Done

- [ ] Every finding fixed or explicitly accepted with rationale
- [ ] Every unresolved reviewer thread about boundaries mapped to a finding or explicitly rebutted
- [ ] No `Bridge.`/`Zaq.Channels.` references remain in `lib/zaq/engine/**`
- [ ] `mix q` passes
```

### 7. Print the result

Print only:
- the plan file path
- the summary table (leak type → count)
- one line flagging which findings were introduced by this branch vs pre-existing
- the "Not scanned" file list, if non-empty
- one line on reviewer-thread reconciliation (N matched, N rebutted, N out of scope)

Do not inline the plan contents into the chat.

## Constraints

- **Detection and planning only** — never edit `lib/` code, even for a one-line fix.
- Every finding must cite exact line numbers verified against the current working tree, not stale diff hunks.
- Findings on pre-existing code are still reported, but clearly labeled — the fix scope decision belongs to the user.
- Group same-seam findings into one refactor step in the plan; four call sites of one leak are one fix, not four.
- If a leak matches an active exec-plan in `docs/exec-plans/active/` (e.g. an ongoing boundary-strip plan), reference that plan in the Fix section instead of re-designing the refactor.
- Keep the chat response under 500 words; the detail lives in the plan file.
