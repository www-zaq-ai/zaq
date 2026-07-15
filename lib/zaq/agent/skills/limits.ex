defmodule Zaq.Agent.Skills.Limits do
  @moduledoc """
  Hard caps on skill size — the single home for the numbers.

  These are safety rails, not per-tenant tunables. A runaway skill body defeats the whole
  point of progressive disclosure (a loaded body stays in the agent's context for the life
  of the server), so the ceiling is global and enforced at **write** time — the author
  sees the error in the BO and fixes it, rather than an end user hitting a truncated skill
  or a blown context window mid-conversation.

  Defaults live here so there is one source of truth. Deployments may override specific
  values via `config :zaq, :agent_skills, ...` (for example in `runtime.exs`), and tests
  can stub them through the app-config layer.

  ## Body: three thresholds, two behaviours

    * `skill_body_warning_tokens` — a **non-blocking warning** recorded in the skill's
      diagnostics and surfaced in the BO. "This is large; consider moving bulk into
      `references/` resources."
    * `skill_body_max_tokens` — a **hard reject**. Tokens are the real context cost.
    * `skill_body_max_bytes` — a **hard reject** and the absolute backstop. Tokens are
      estimated (`TokenEstimator`, word-based), so a pathological body — CJK, base64, no
      whitespace — could slip the token check; the byte ceiling cannot be gamed.

  ## Not owned here

    * `description` (1024 chars) and `compatibility` (500 chars) are capped by
      `Jido.AI.Skill.Loader`, not ZAQ. Duplicating them as settable here would be a lie —
      changing our number would not change Jido's.
    * `bundle_max_bytes` / `bundle_max_files` guard **SKILL.md import** (Part 2 M4). They
      live here so the ceilings are all in one place, but nothing enforces them in Part 1.
  """

  @defaults %{
    skill_body_warning_tokens: 16_000,
    skill_body_max_tokens: 32_000,
    skill_body_max_bytes: 131_072,
    # Part 2 (import) — declared here, enforced in M4.
    bundle_max_bytes: 50 * 1024 * 1024,
    bundle_max_files: 500
  }

  @spec all(keyword()) :: map()
  def all(opts \\ []) do
    overrides = Zaq.Config.get(:zaq, :agent_skills, %{}, opts) |> Map.new()
    Map.merge(@defaults, overrides)
  end

  @spec get(atom(), keyword()) :: term()
  def get(key, opts \\ []) when is_atom(key), do: Map.fetch!(all(opts), key)
end
