defmodule Zaq.Agent.AnsweringRun do
  @moduledoc """
  Classifies Jido answering events for streaming transports.
  """

  @source_marker ~r/\s*\[\[source:[^\]]+\]\]/u

  @type classified ::
          {:done, String.t()}
          | {:error, term()}
          | :ignore

  @spec classify_event(term()) :: classified()
  def classify_event(event) do
    case field(event, :kind) do
      :request_completed -> {:done, event |> data() |> field(:result) |> clean_answer()}
      :request_failed -> {:error, event |> data() |> field(:error) || :react_failed}
      :request_cancelled -> {:error, :react_cancelled}
      _ -> :ignore
    end
  end

  @spec extract_chunks(term()) :: [map()]
  def extract_chunks(event) do
    if field(event, :kind) == :tool_completed do
      event |> data() |> field(:result) |> chunks_from_result()
    else
      []
    end
  end

  defp chunks_from_result({:ok, inner, _directives}), do: chunks_from_result(inner)
  defp chunks_from_result({:ok, inner}), do: chunks_from_result(inner)

  defp chunks_from_result(result) when is_map(result) do
    case field(result, :chunks) do
      chunks when is_list(chunks) -> chunks
      _ -> []
    end
  end

  defp chunks_from_result(_result), do: []

  @doc """
  Removes inline source markers duplicated by the structured `zaq_sources` frame.
  """
  @spec clean_answer(term()) :: String.t()
  def clean_answer(text) when is_binary(text) do
    text
    |> String.replace(@source_marker, "")
    |> String.replace(~r/[ \t]+\n/u, "\n")
    |> String.trim()
  end

  def clean_answer(nil), do: ""
  def clean_answer(other), do: other |> to_string() |> clean_answer()

  defp data(event), do: field(event, :data) || %{}

  defp field(struct, key) when is_struct(struct), do: Map.get(struct, key)
  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp field(_value, _key), do: nil
end
