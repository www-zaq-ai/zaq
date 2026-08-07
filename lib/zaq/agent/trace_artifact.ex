defmodule Zaq.Agent.TraceArtifact do
  @moduledoc """
  Moves the bytes a tool returned out of the trace entry and into `message_trace_artifacts`.

  A tool that reads a file answers with the bytes on the record. Left alone they land in the
  message's `trace` column, which is loaded whole on every conversation read and rendered into
  the DOM by the trace panel. So the bytes are stored once, and the entry keeps a pointer plus
  the metadata a file chip needs — name, type, size.

  Called from the agent's stream handler, which is what scopes this to agent turns: a workflow
  runs its actions through the workflow engine and never reaches it, so a workflow invocation
  stores nothing and answers with the bytes in its own output.

  Size is always taken from the decoded bytes. A provider may transport them as base64, and the
  encoded length is a third larger than the file the reviewer sees.
  """

  require Logger

  alias Zaq.Contracts.Record
  alias Zaq.Engine.Conversations.MessageTraceArtifact
  alias Zaq.Event

  @artifact_key "trace_artifact_id"

  @doc """
  Replaces the content on a tool result with a stored artifact's id.

  Anything that is not a result carrying bytes passes through untouched, so this is safe to
  call on every tool result. A failed store also passes the result through: the turn already
  happened, and losing the copy must not cost the answer.
  """
  @spec store(term(), String.t() | nil, map()) :: term()
  def store(%{record: %Record{} = record} = result, tool_call_id, state)
      when is_binary(tool_call_id) do
    case decode(record) do
      {:ok, bytes} -> %{result | record: put_artifact(record, bytes, tool_call_id, state)}
      :none -> result
    end
  end

  def store(result, _tool_call_id, _state), do: result

  @doc "Key the artifact id is written under on the record's attributes."
  @spec artifact_key() :: String.t()
  def artifact_key, do: @artifact_key

  defp put_artifact(%Record{} = record, bytes, tool_call_id, state) do
    size = byte_size(bytes)

    attrs = %{
      tool_call_id: tool_call_id,
      name: record.name,
      mime_type: record.mime_type,
      size: size,
      content: within_cap(bytes, size)
    }

    case create(attrs, state) do
      {:ok, %MessageTraceArtifact{id: id}} ->
        record
        |> without_content(size)
        |> annotate(@artifact_key, to_string(id))

      other ->
        Logger.warning(
          "[TraceArtifact] Could not keep #{inspect(record.name)} read by " <>
            "#{inspect(tool_call_id)}: #{inspect(other)}"
        )

        without_content(record, size)
    end
  end

  # Over the cap the row is metadata only. What was read still shows in the trace; the bytes do
  # not, which is the trade the cap exists to make.
  defp within_cap(bytes, size) do
    if size > MessageTraceArtifact.max_content_bytes(), do: nil, else: bytes
  end

  defp create(attrs, state) do
    node_router = Map.get(state, :node_router, Zaq.NodeRouter)

    attrs
    |> Event.new(:engine, opts: [action: :create_trace_artifact])
    |> node_router.dispatch()
    |> Map.fetch!(:response)
  rescue
    error -> {:error, error}
  end

  # The bytes are stored now, so leaving them on the record would write them to the trace as
  # well — the duplication this module exists to prevent. Size stays, since a chip renders it.
  defp without_content(%Record{} = record, size),
    do: %{record | content: nil, size: record.size || size}

  defp annotate(%Record{} = record, key, value),
    do: %{record | attributes: Map.put(record.attributes || %{}, key, value)}

  # `Zaq.Ingestion.materialize_record/1` marks encoded bytes with `attributes["encoding"]`;
  # anything else is already raw.
  defp decode(%Record{content: content, attributes: attributes}) when is_binary(content) do
    case Map.get(attributes || %{}, "encoding") do
      "base64" -> Base.decode64(content) |> normalize_decode()
      _raw -> {:ok, content}
    end
  end

  defp decode(%Record{}), do: :none

  defp normalize_decode({:ok, bytes}), do: {:ok, bytes}
  defp normalize_decode(:error), do: :none
end
