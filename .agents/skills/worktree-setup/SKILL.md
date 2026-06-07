---
name: worktree-setup
description: Set up a git worktree with an isolated dev database and full developer environment for a branch.
compatibility: opencode
---

## Role

You are a developer environment setup agent for the ZAQ project.

Your goal is to create a fully isolated, ready-to-run git worktree for a given branch — with its own database, secrets, and editor configuration — so a developer can start coding immediately.

## Arguments

The branch name is passed as the skill argument (e.g. `feat/my-feature`). If no argument is provided, read the current git branch with `git branch --show-current`.

## Setup process

Follow these steps in order. Stop and report the error clearly if any step fails.

### 1. Resolve the branch name

- Use the argument if provided.
- Otherwise run `git branch --show-current`.
- Call this value `<branch>`.

### 2. Compute derived values

| Value | Rule | Example |
|---|---|---|
| **worktree slug** | replace `/` with `-` in `<branch>` | `feat-my-feature` |
| **worktree path** | `<parent of main repo>/zaq-<worktree-slug>` | `/workspace/zaq/zaq-feat-my-feature` |

The main repo root is the current working directory. Its parent is one level up.

The database name does **not** need to be computed manually — `config/dev.exs` reads the git branch via `System.cmd` at compile time and derives it automatically (e.g. `feat/my-feature` → `zaq_feat_my_feature`).

### 3. Create the worktree

Check if already exists:

```sh
git worktree list | grep "<worktree-path>"
```

If it does **not** exist:

- Branch exists locally → `git worktree add <worktree-path> <branch>`
- Branch does **not** exist locally → `git worktree add -b <branch> <worktree-path> main`

If it already exists, skip and continue.

### 4. Copy config/dev.secret.exs

This file is gitignored and absent from the new worktree. Copy it as-is — no modifications needed:

```sh
cp <main-repo>/config/dev.secret.exs <worktree-path>/config/dev.secret.exs
```

### 5. Copy .claude/settings.local.json

```sh
mkdir -p <worktree-path>/.claude
cp <main-repo>/.claude/settings.local.json <worktree-path>/.claude/settings.local.json
```

### 6. Run mix setup

```sh
cd <worktree-path> && mix setup
```

This installs dependencies, creates the branch-isolated database, runs all migrations, and builds assets. The database name is derived automatically from the git branch by `config/dev.exs` at compile time.

## Output

On success, print:

```
Worktree ready
  Path:     <worktree-path>
  Branch:   <branch>
  Database: zaq_<slug>  (derived automatically from branch)

To start the server:
  cd <worktree-path>
  iex -S mix phx.server
```

On failure, print the step that failed and the full error output. Do not continue past a failed step.
