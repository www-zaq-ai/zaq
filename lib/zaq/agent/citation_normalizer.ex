defmodule Zaq.Agent.CitationNormalizer do
  @moduledoc false

  @marker_regex ~r/\[\[(source|memory):([^\]]+)\]\]/u
  @default_memory_labels MapSet.new([
                           "llm-general-knowledge",
                           "llm-reasoning-inference",
                           "llm-linguistic-normalization"
                         ])

  @typedoc """
  Normalized reference map returned by `normalize/3`.

  Runtime shape:
  - `%{"index" => integer(), "type" => "document", "path" => String.t()}`
  - `%{"index" => integer(), "type" => "memory", "label" => String.t()}`
  """
  @type normalized_reference :: %{required(binary()) => String.t() | pos_integer()}
  @type normalized_result :: %{body: String.t(), sources: [normalized_reference()]}

  @spec normalize(String.t(), [String.t()], keyword()) :: normalized_result()
  def normalize(answer, retrieved_sources, opts \\ [])

  def normalize(answer, retrieved_sources, opts)
      when is_binary(answer) and is_list(retrieved_sources) do
    allowed_memory_labels =
      opts
      |> Keyword.get(:memory_labels, MapSet.to_list(@default_memory_labels))
      |> MapSet.new()

    source_set =
      retrieved_sources
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> MapSet.new()

    state = %{next_index: 1, refs: %{}, ordered_refs: []}

    {body, final_state} = normalize_text(answer, source_set, allowed_memory_labels, state)

    %{body: String.trim(body), sources: Enum.reverse(final_state.ordered_refs)}
  end

  def normalize(_answer, _retrieved_sources, _opts), do: %{body: "", sources: []}

  defp normalize_text(text, source_set, allowed_memory_labels, state) do
    case Regex.run(@marker_regex, text, return: :index) do
      nil ->
        {text, state}

      [{start, len}, {kind_start, kind_len}, {value_start, value_len}] ->
        prefix = binary_part(text, 0, start)
        suffix_start = start + len
        suffix_len = byte_size(text) - suffix_start
        suffix = binary_part(text, suffix_start, suffix_len)

        kind = binary_part(text, kind_start, kind_len)
        value = text |> binary_part(value_start, value_len) |> String.trim()

        {replacement, next_state} =
          resolve_marker(kind, value, source_set, allowed_memory_labels, state)

        {normalized_suffix, final_state} =
          normalize_text(suffix, source_set, allowed_memory_labels, next_state)

        {prefix <> replacement <> normalized_suffix, final_state}
    end
  end

  defp resolve_marker("source", value, source_set, _allowed_memory_labels, state) do
    if MapSet.member?(source_set, value) do
      add_or_reuse_reference({"document", value}, %{"type" => "document", "path" => value}, state)
    else
      {"", state}
    end
  end

  defp resolve_marker("memory", value, _source_set, allowed_memory_labels, state) do
    if MapSet.member?(allowed_memory_labels, value) do
      add_or_reuse_reference({"memory", value}, %{"type" => "memory", "label" => value}, state)
    else
      {"", state}
    end
  end

  defp resolve_marker(_kind, _value, _source_set, _allowed_memory_labels, state), do: {"", state}

  defp add_or_reuse_reference(key, payload, state) do
    case Map.fetch(state.refs, key) do
      {:ok, index} ->
        {"[#{index}]", state}

      :error ->
        index = state.next_index
        reference = Map.put(payload, "index", index)

        {
          "[#{index}]",
          %{
            state
            | next_index: index + 1,
              refs: Map.put(state.refs, key, index),
              ordered_refs: [reference | state.ordered_refs]
          }
        }
    end
  end
end
