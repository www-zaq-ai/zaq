---
name: session-handoff
description: Writes a HANDOFF.md capturing the state of the current working session so another agent (or the same one after a context reset) can pick the work up cold. Covers goal, current state, active files, changes made, failed attempts, and next step. Use whenever the user asks for a handoff, a session summary, to "write down where we are", to hand work off to another agent/teammate, or before ending a session with work still in flight. Reconstructs facts from git and the actual files — never from memory alone.
---

# Session Handoff

Produce a handoff document that lets someone with **zero context** resume this work without re-deriving anything. The reader has the repo and nothing else.

## Non-negotiables

1. **Verify every claim against the repo before writing it.** Run `git status`, `git diff --stat`, `git log --oneline -5`, and read the files you are about to describe. A handoff that misstates the working tree is worse than none.
2. **Never claim a test passes without having run it in this session.** If the last run was before the most recent edit, say so explicitly: "last green at <commit//edit>, not re-run since".
3. **Record failed attempts.** This is the highest-value section and the one most often skipped. The next agent will otherwise repeat them.
4. **Distinguish decided from open.** If a decision is the user's to make and is still unmade, it belongs in Next Step as a question, not as an instruction.
5. **No invented file paths, line numbers, or test names.** Cite `path:line` only after reading the file.

## Where it goes

Default: `HANDOFF.md` at the repo root. If the repo has `docs/exec-plans/active/`, write
`docs/exec-plans/active/<YYYY-MM-DD>-handoff-<short-slug>.md` instead and mention the path in your reply.

If a handoff file already exists for this line of work, **update it in place** rather than
creating a second one — stale parallel handoffs are the main failure mode. Add a
`## Session log` entry at the bottom with the date and what changed.

## Gather first

Run these before writing anything:

```sh
git status --short
git diff --stat
git log --oneline -5
git stash list          # stashed work is invisible otherwise and gets lost
```

Then read each modified file well enough to describe what changed and why.

## Required structure

Use exactly these six headings, in this order.

### 1. Goal

What the user is actually trying to achieve — the outcome, not the task list. One or two
sentences. Include the motivating trigger if there was one ("the md-conversion library was
updated, so ..."). If the goal shifted mid-session, state the current goal and note the shift.

### 2. Current State

Where things stand right now. Be concrete and blunt:

- Branch name, and whether the tree is clean, dirty, or has stashes
- What works, verified how, and when it was last verified
- What is broken or unverified
- Any blocking question awaiting a user decision

Separate **pre-existing** breakage from **breakage this session introduced**. If you have not
established which is which, say that rather than guessing.

### 3. Active files

A table of every file created or modified, with a one-line description of its role in this work.
Mark untracked files — they are invisible to `git diff` and easy to lose.

| File | State | What it is |
|---|---|---|

Include scratch/probe files if they carry reusable value, and say they are disposable.

### 4. Changes Made

What changed, grouped by concern, each with the reasoning. For behavioural changes, give the
before → after in concrete terms (numbers, not adjectives): "49 chunks → 10 chunks", not
"fewer chunks". Link claims to `path:line` where a reader would want to look.

Include decisions the user made during the session and what they chose, so nobody relitigates them.

### 5. Failed attempts

Everything tried that did not work, and **why it failed**. Include:

- Approaches abandoned, with the reason (not just "didn't work")
- Assertions that turned out to be wrong about the codebase
- Commands or tool calls that were rejected, interrupted, or blocked, and what the user said
- Tests written that had to be rewritten because they encoded the wrong contract

If nothing failed, write "None." — do not pad it.

### 6. Next step

The single next action, stated so it can be started immediately. Then any follow-ups, ordered.

Mark each item as one of:

- **Blocked on user** — needs a decision only they can make; state the question and the options
- **Ready** — can be started with no further input
- **Optional** — worth doing, not required

End with anything the next agent must *not* do (dead ends, things the user explicitly declined).

## Tone

Write for a competent stranger. No hedging, no filler, no restating the obvious. Prefer a
short table to a long paragraph. If something is uncertain, name the uncertainty rather than
smoothing over it.
