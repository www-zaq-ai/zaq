defmodule Zaq.Agent.Skills.Validation do
  @moduledoc """
  Validates a skill against the Open Agent Skills spec, using Jido's loader as the
  canonical validator.

  ## Why a round trip through SKILL.md text

  ZAQ stores skills in Postgres, not as `SKILL.md` files. But the format's rules —
  name shape, length caps, the `allowed-tools` encoding — are enforced by
  `Jido.AI.Skill.Loader`, whose validators are all `defp` and reachable **only** by
  parsing SKILL.md *text*. There is no `Skill.validate(%Spec{})` for an in-memory spec.

  So we serialize the record to SKILL.md, parse it back, and keep what comes out. That
  is deliberately more than validation: it is a **round-trip proof**. Whatever we persist
  is exactly what a real `SKILL.md` would produce, which is what makes import/export and
  catalog interop possible later rather than subtly broken.

  The alternative — reimplementing Jido's rules in ZAQ — is what this replaces. The old
  `@name_regex` / `@max_name_length` / `@max_description_length` constants in
  `Zaq.Agent.Skill` were hand-copied from `loader.ex` and had nothing keeping them in sync.

  ## The round-trip guard

  Jido owns field-shape validation and rejects over-long fields in strict mode. ZAQ
  still compares round-tripped values that can be normalized by serialization, so a
  lossy SKILL.md encoding is rejected before it can be persisted.

  This guard is intentionally narrow: it is a check that the persisted record can be
  faithfully exported and parsed back, not a reimplementation of Jido's validator.
  """

  alias Jido.AI.Skill.Diagnostics
  alias Jido.AI.Skill.Loader
  alias Jido.AI.Skill.Spec

  @type field_error :: {atom(), String.t()}

  @doc """
  Validates skill attrs through Jido's loader.

  Returns the parsed `%Spec{}` plus its diagnostics as a plain map (persisted on the
  record so the BO can badge warnings without re-parsing every row).
  """
  @spec validate(map(), keyword()) :: {:ok, Spec.t(), map() | nil} | {:error, [field_error()]}
  def validate(attrs, opts \\ [])

  def validate(%{name: name, description: description, body: body} = attrs, opts)
      when is_binary(name) and is_binary(description) and is_binary(body) do
    allowed_tools = Map.get(attrs, :allowed_tools) || []
    loader = Keyword.get(opts, :loader, Loader)

    content = to_skill_md(name, description, body, allowed_tools)

    # The source path is NOT "inline". Jido checks `name` against the parent directory
    # name and warns on a mismatch — and `Path.dirname("inline")` is ".", which never
    # matches, so every single DB-backed skill would collect a bogus
    # `directory_name_mismatch` warning and be badged as having problems in the BO.
    source_path = Path.join(name, "SKILL.md")

    case loader.parse(content, source_path, lenient: false) do
      {:ok, %Spec{} = spec} ->
        case round_trip_errors(spec, allowed_tools) do
          [] -> {:ok, spec, diagnostics_map(spec.diagnostics)}
          errors -> {:error, errors}
        end

      {:error, error} ->
        {:error, [to_field_error(error)]}
    end
  end

  def validate(_attrs, _opts), do: {:error, []}

  @doc """
  Serializes skill attrs to Open Agent Skills `SKILL.md` content.

  Exposed for round-trip tests and for the export path (Part 2).
  """
  @spec to_skill_md(String.t(), String.t(), String.t(), [String.t()]) :: String.t()
  def to_skill_md(name, description, body, allowed_tools \\ []) do
    frontmatter =
      [
        "name: #{name}",
        "description: #{yaml_string(description)}",
        allowed_tools_line(allowed_tools)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    # The body may itself contain `---`. That is safe: Jido's frontmatter regex is
    # anchored at the start of the document and non-greedy, so it closes on OUR
    # delimiter, and everything after it — including any `---` — is body.
    "---\n#{frontmatter}\n---\n\n#{body}"
  end

  # The OAS spec encodes `allowed-tools` as a SPACE-SEPARATED STRING under a kebab-case
  # key — not a YAML list. Emitting a list would parse fine in Jido (it accepts both) but
  # would produce non-conformant SKILL.md, breaking the export/catalog interop this round
  # trip exists to guarantee.
  defp allowed_tools_line([]), do: nil

  defp allowed_tools_line(tools) do
    "allowed-tools: #{yaml_string(Enum.join(tools, " "))}"
  end

  # A double-quoted YAML scalar: safe for colons, hashes, quotes and newlines, all of
  # which appear in real descriptions and would otherwise produce invalid YAML.
  defp yaml_string(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")

    "\"#{escaped}\""
  end

  # Compare fields whose SKILL.md encoding can be lossy and refuse to persist any
  # value that does not parse back to the submitted shape.
  defp round_trip_errors(%Spec{} = spec, allowed_tools) do
    [
      field_mismatch(
        :allowed_tools,
        spec.allowed_tools,
        allowed_tools,
        "could not be encoded — tool names must not contain spaces"
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp field_mismatch(_field, same, same, _message), do: nil
  defp field_mismatch(field, _parsed, _submitted, message), do: {field, message}

  # Stored in a `:map` column, so it comes back from the DB with string keys. Normalize to
  # string keys at write time too, so the in-memory, persisted and reloaded shapes are
  # identical — and so ZAQ can merge its own warnings (e.g. an over-long body) into the
  # same map without mixing atom and string keys.
  defp diagnostics_map(nil), do: nil

  defp diagnostics_map(diagnostics) do
    diagnostics
    |> Diagnostics.to_map()
    |> stringify_keys()
  end

  defp stringify_keys(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp to_field_error(%{__struct__: mod} = error) do
    message = Exception.message(error)

    case mod do
      Jido.AI.Skill.Error.Validation.MissingField -> {error.field, "can't be blank"}
      Jido.AI.Skill.Error.Validation.InvalidName -> {:name, message}
      Jido.AI.Skill.Error.Validation.InvalidField -> invalid_field_error(error, message)
      Jido.AI.Skill.Error.Parse.InvalidYaml -> {:description, message}
      _ -> {:body, message}
    end
  end

  defp invalid_field_error(%{field: :description, reason: :too_long}, _message),
    do: {:description, "is too long (max 1024 characters)"}

  defp invalid_field_error(%{field: field}, message)
       when field in [:description, :allowed_tools, :metadata, :license, :compatibility],
       do: {field, message}

  defp invalid_field_error(_error, message), do: {:body, message}
end
