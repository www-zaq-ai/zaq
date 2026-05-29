# Storybook Smoke Tests

Playwright suite that visits every story in the ZAQ Storybook and asserts it renders without errors.

## How to run

From the project root:

```bash
mix storybook
```

The suite starts (or reuses) the dev server automatically, discovers all stories from the filesystem, and runs one test per story.

## Options

| Command | When to use |
|---|---|
| `mix storybook` | Standard run from project root |
| `cd test/storybook && npm run test:headed` | Watch the browser — useful when debugging a failing story |
| `cd test/storybook && npx playwright test --grep "button"` | Run a single story by name |
| `cd test/storybook && npx playwright show-report` | Open the HTML report after a run |

## What to expect when it passes

```
Discovered 39 stories → test/storybook/support/story-urls.json

  ✓  story renders: /storybook/components/forms/button
  ✓  story renders: /storybook/components/forms/input
  ...
39 passed
```

## What to expect when it fails

Each failure is reported individually with the URL and reason:

```
✗  story renders: /storybook/components/file_preview/file_preview

  TimeoutError: locator.waitFor: Timeout 10000ms exceeded.
  waiting for locator('div#story-live') to be visible
```

This means PhoenixStorybook showed a compile or runtime error instead of the story. Open the screenshot in `test/storybook/test-results/` or run headed to see the error panel:

```bash
cd test/storybook && npx playwright test --headed --grep "file_preview"
```

Common causes:

| Symptom | Cause | Fix |
|---|---|---|
| `TokenMissingError: expression is incomplete` | `{@attr}` in a `<pre><code>` block inside `~H` — HEEx parses it as a live expression | Escape as `&#123;&#64;attr&#125;` |
| `KeyError: key :X not found` | Story passes a map with the wrong key | Check the component's `attr` declarations and fix the story data |
| `(UndefinedFunctionError) function X/1 is undefined` | Story calls a component that uses `JS.dispatch` or similar (unavailable in script mode) | Replace the live call with a static code snippet in `<pre><code>` |
| `~N[]` syntax error | NaiveDateTime sigil not available in PhoenixStorybook script mode | Use `NaiveDateTime.from_iso8601!("2024-01-01 00:00:00")` instead |

## When to run this

- After adding a new story
- After modifying an existing story
- After changing a component referenced by a story
- After adding or removing CSS design tokens

## How stories are discovered

The suite scans the `storybook/` directory at runtime for `*.story.exs` files — no hardcoded list. New stories are automatically picked up without changing any test file.
