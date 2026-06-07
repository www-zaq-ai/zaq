# Worktree Setup

Set up a git worktree with an isolated dev database and full developer environment for a branch.

## Arguments

`$ARGUMENTS` — the branch name (e.g. `feat/my-feature`). If empty, use the current git branch.

## What I do

1. Resolve the branch and compute all derived paths
2. Create the git worktree (skip if it already exists)
3. Copy `config/dev.secret.exs` into the worktree
4. Copy `.claude/settings.local.json` into the worktree
5. Run `mix setup` in the worktree — the database name is derived automatically from the git branch

## Step-by-step instructions

### 1. Resolve the branch name

- If `$ARGUMENTS` is non-empty, use it as `<branch>`.
- Otherwise run `git branch --show-current` to get `<branch>`.

### 2. Compute derived values

Given `<branch>` (e.g. `feat/my-feature`):

| Value | Rule | Example |
|---|---|---|
| **worktree slug** | replace `/` with `-` | `feat-my-feature` |
| **worktree path** | `<parent of main repo>/zaq-<worktree-slug>` | `/workspace/zaq/zaq-feat-my-feature` |
| **database name** | computed automatically by `config/dev.exs` from the git branch at compile time | `zaq_feat_my_feature` |

The main repo root is the current working directory. Its parent is one level up (e.g. main repo at `/workspace/zaq/zaq` → parent is `/workspace/zaq`).

### 3. Create the worktree

Check if the worktree already exists:

```sh
git worktree list | grep "<worktree-path>"
```

If it **does not exist**:

- Branch exists locally → `git worktree add <worktree-path> <branch>`
- Branch does NOT exist locally → `git worktree add -b <branch> <worktree-path> main`

If it **already exists**, skip creation and continue.

### 4. Copy dev.secret.exs

`config/dev.secret.exs` is gitignored and will not be present in the new worktree. Copy it as-is — no modifications needed, since the database name is now driven by the `DEV_DB` env var at compile time.

```sh
cp <main-repo>/config/dev.secret.exs <worktree-path>/config/dev.secret.exs
```

### 5. Copy .claude/settings.local.json

`settings.local.json` is gitignored so it is absent from the new worktree:

```sh
mkdir -p <worktree-path>/.claude
cp <main-repo>/.claude/settings.local.json <worktree-path>/.claude/settings.local.json
```

### 6. Run mix setup

```sh
cd <worktree-path> && mix setup
```

`config/dev.exs` reads the git branch via `System.cmd("git", ["branch", "--show-current"])` at compile time and derives the database name automatically (e.g. branch `feat/my-feature` → database `zaq_feat_my_feature`). No env var needed.

## Report on completion

Print a summary:

```
Worktree ready
  Path:     <worktree-path>
  Branch:   <branch>
  Database: zaq_<db-slug>

To start the server:
  cd <worktree-path>
  iex -S mix phx.server
```

If `mix setup` fails, print the error and stop — do not silently continue.
