defmodule Zaq.Agent.Tools.Skills.LoadSkillResource do
  @moduledoc """
  ReAct tool: returns the text of one file bundled with a skill.

  This is the third and last level of progressive disclosure. The system prompt carries a
  name + description **index** (`Zaq.Agent.Skills.index_system_prompt/2`); `load_skill`
  returns a skill's instructions plus a **manifest** of its files; this tool returns **one
  file's content**, and only when the model asks for it by path.

  Each level costs strictly more context than the last, which is why they are separate
  calls. A skill with five reference documents would blow the window if `load_skill`
  returned them eagerly, and the model usually needs none of them.

  ## Scoping — the same boundary as `load_skill`

  Resolution is scoped to the invoking agent's own attached, active skills, read from
  `:configured_agent_id`. A `nil` agent id refuses rather than falling back to a global
  lookup, and the not-found path names neither the skill's files nor any other skill
  (upstream gap G3). An agent cannot read a file belonging to a skill it was not granted.

  ## `scripts/` is refused

  A script's body returned as a tool result is instructions the model may follow, written by
  whoever uploaded the file — a prompt-injection vector with no upside while there is no
  execution story. `references/` and `assets/` are readable; `scripts/` is refused before
  anything is dispatched.

  ## Where the bytes come from

  Through `Zaq.Agent.Skills.Bundle` to the `:ingestion` role, addressed by the skill's
  opaque locator. This module never names a volume, never joins a path, and never sees an
  absolute one. `resource_path` is passed through byte-for-byte: the manifest handed the
  model that exact string, so validating or rewriting it here could only let it reach a file
  it did not name.

  ## Size

  `resource_read_max_bytes` (`Zaq.Agent.Skills.Limits`) is enforced **after** the read and
  the file is refused with its size named, never truncated — half a reference document reads
  like a whole one, and a document cut mid-sentence is worse than one withheld. The cap sits
  far below the upload cap on purpose: a multi-megabyte PDF is a legitimate upload but is
  never handed to a model as text.
  """

  use Zaq.Engine.Workflows.Action,
    name: "load_skill_resource",
    description: """
    Read one file bundled with one of your skills. Call `load_skill` first — its result
    lists the available files with their exact `resource_path`. Pass that path verbatim,
    together with the skill's name. Only read a file the skill's instructions actually point
    you at; each one costs context.
    """,
    schema: [
      skill_name: [type: :string, required: true, doc: "The exact name of the skill."],
      resource_path: [
        type: :string,
        required: true,
        doc: "The exact resource_path from the skill's file listing, e.g. references/guide.md."
      ]
    ],
    output_schema: [
      skill_name: [type: :string, required: true, doc: "The skill the file belongs to."],
      resource_path: [type: :string, required: true, doc: "The file that was read."],
      content: [type: :string, required: true, doc: "The file's text."]
    ]

  alias Zaq.Agent.Skills.Bundle
  alias Zaq.Agent.Skills.Limits
  alias Zaq.Agent.TokenEstimator
  alias Zaq.Agent.Tools.Skills.Scope

  require Logger

  @scripts_dir "scripts"

  @impl Jido.Action
  def run(%{skill_name: skill_name, resource_path: resource_path}, context) do
    with {:ok, agent} <- fetch_agent(context),
         {:ok, skill} <- fetch_granted_skill(agent, skill_name),
         :ok <- refuse_scripts(resource_path),
         {:ok, content} <- read(skill, resource_path, context),
         :ok <- enforce_read_cap(content, resource_path, context) do
      emit_telemetry(agent, skill, resource_path, content, context)

      {:ok, %{skill_name: skill.name, resource_path: resource_path, content: content}}
    end
  end

  # Both scope checks live in `Scope`, shared with `LoadSkill`: a nil scope must never widen
  # access, and not-found names neither the catalog nor the skill's files.
  defp fetch_agent(context), do: Scope.fetch_agent(context, "load_skill_resource")

  defp fetch_granted_skill(agent, skill_name), do: Scope.fetch_granted_skill(agent, skill_name)

  defp refuse_scripts(resource_path) do
    case Path.split(resource_path) do
      [@scripts_dir | _rest] ->
        {:error,
         "Scripts are not readable. #{inspect(resource_path)} is executable content, not " <>
           "reference material."}

      _ ->
        :ok
    end
  end

  defp read(skill, resource_path, context) do
    case Bundle.read_text(skill, resource_path, context) do
      {:ok, content} ->
        {:ok, content}

      {:error, :no_bundle} ->
        {:error, "Skill #{inspect(skill.name)} has no bundled files."}

      {:error, :not_found} ->
        {:error,
         "#{inspect(resource_path)} is not a file bundled with #{inspect(skill.name)}. " <>
           "Call load_skill to see what it has."}

      {:error, :invalid_utf8} ->
        {:error,
         "#{inspect(resource_path)} is a binary file and cannot be read as text. Its name " <>
           "and size are in the skill's file listing."}

      {:error, reason} when reason in [:path_traversal, :invalid_resource_path] ->
        {:error,
         "#{inspect(resource_path)} is not a valid resource path. Use one exactly as listed " <>
           "by load_skill."}

      {:error, reason} ->
        Logger.warning(
          "[LoadSkillResource] read failed for #{inspect(resource_path)}: #{inspect(reason)}"
        )

        {:error, "#{inspect(resource_path)} could not be read right now. Try again shortly."}
    end
  end

  # Enforced after the read because the ingestion side returns text, not a stat — and the
  # cap protects the *context window*, which only the returned bytes threaten.
  defp enforce_read_cap(content, resource_path, context) do
    max = Limits.get(:resource_read_max_bytes, Map.get(context, :limits_opts, []))
    size = byte_size(content)

    if size > max do
      {:error,
       "#{inspect(resource_path)} is #{size} bytes, over the #{max}-byte limit for a single " <>
         "file, so it was not returned. Ask someone to split it into smaller files."}
    else
      :ok
    end
  end

  defp emit_telemetry(agent, skill, resource_path, content, context) do
    telemetry = Map.get(context, :telemetry_module, :telemetry)

    telemetry.execute(
      [:zaq, :agent, :skill, :resource_load],
      %{bytes: byte_size(content), tokens: TokenEstimator.estimate(content)},
      %{
        skill_id: skill.id,
        skill_name: skill.name,
        resource_path: resource_path,
        configured_agent_id: agent.id
      }
    )
  rescue
    # Telemetry must never take down a tool call.
    e ->
      Logger.warning("[LoadSkillResource] telemetry emit failed: #{Exception.message(e)}")
      :ok
  end
end
