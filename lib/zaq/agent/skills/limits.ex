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

  ## Resources: the ceiling has to be ours

  `Jido.AI.Skill.Resources` imposes **no** size limit — `load_resource/2` is an uncapped
  `File.read/1`, and `list_resources/1` reports whatever it finds. Jido's only length caps
  are on SKILL.md metadata (see above). So nothing upstream stops a 20 MB reference file
  from being loaded straight into a tool result and blowing the context window:

    * `resource_max_bytes` — per-file **upload** cap, enforced at write time in the BO.
      Deliberately looser than the read cap, because a PDF or PNG reference is legitimately
      larger than anything the model will be handed as text.
    * `resource_read_max_bytes` — per-file **read** cap for the text a tool returns to the
      model. Enforced by `Zaq.Agent.Tools.Skills.LoadSkillReference`, which **refuses**
      oversize files naming their size rather than truncating them: half a reference
      document reads as a whole one, and instructions cut mid-sentence are worse than
      instructions withheld.
    * `resource_listing_max_files` — how many entries a `load_skill` manifest may carry.
      A listing is metadata, but a bundle with hundreds of files would still crowd out the
      instructions it accompanies. Over the cap the listing is truncated **and says so**
      ("showing 100 of 137"), so the model knows to ask rather than assuming it saw
      everything.

  These two are read caps and must not be conflated with `bundle_max_*`, which guard
  SKILL.md *import* (M4). One number serving two policies drifts the moment either moves.
  """

  @defaults %{
    skill_body_warning_tokens: 16_000,
    skill_body_max_tokens: 32_000,
    skill_body_max_bytes: 131_072,
    # Part 2 (import) — declared here, enforced in M4.
    bundle_max_bytes: 50 * 1024 * 1024,
    bundle_max_files: 500,
    # Resources: upload caps enforced on the BO write path, read caps on the tool read path.
    resource_max_bytes: 5 * 1024 * 1024,
    resource_max_files: 10,
    resource_read_max_bytes: 262_144,
    resource_listing_max_files: 100
  }

  @spec all(keyword()) :: map()
  def all(opts \\ []) do
    overrides = Zaq.Config.get(:zaq, :agent_skills, %{}, opts) |> Map.new()
    Map.merge(@defaults, overrides)
  end

  @spec get(atom(), keyword()) :: term()
  def get(key, opts \\ []) when is_atom(key), do: Map.fetch!(all(opts), key)
end
