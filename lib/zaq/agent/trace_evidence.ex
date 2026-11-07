defmodule Zaq.Agent.TraceEvidence do
  @moduledoc """
  Converts invocation evidence without changing executed Action results.

  `metadata/1` removes resource bytes and capabilities for callbacks and arguments.
  `result/1` retains supported typed artifact bytes only for the native request
  stream, until `externalize/4` separates them from the JSON trace. Both reuse
  Record metadata, tool-error summaries and Observe redaction, with bounded ZAQ
  adaptation that preserves tagged result/effect envelopes.

  `json_safe/1` is the legacy persistence conversion, not a security sanitizer:
  it preserves struct details and inspection fallbacks for existing consumers.
  Workflow event persistence deliberately has a stricter, separate boundary.

  This module neither executes Actions, collects events, correlates invocations
  nor persists artifacts. The stream reducer owns collection; Engine owns storage.
  """

  alias Jido.AI.Observe
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolResult
  alias Zaq.Agent.Tools.Error, as: ToolError
  alias Zaq.Contracts.Record

  @doc "Prepares bounded metadata without inline artifact bytes or capabilities."
  @spec metadata(term()) :: term()
  def metadata(value), do: trace_value(value, false, 0)

  @doc "Prepares native-stream result evidence, retaining supported typed artifact bytes."
  @spec result(term()) :: term()
  def result(value), do: trace_value(value, true, 0)

  @doc """
  Separates supported artifact bytes from a tool result without changing effects.

  Nested diagnostic artifacts are optional evidence; root artifacts retain their
  existing required-storage behavior. Unsupported result shapes pass through.
  """
  @spec externalize(term(), binary(), binary() | nil, boolean()) :: {term(), [map()]}
  def externalize(result, tool_call_id, tool_name, nested?) do
    {evidence, artifacts} = externalize_trace_artifacts(result, tool_call_id, tool_name, nested?)

    artifacts =
      if nested?, do: Enum.map(artifacts, &Map.put(&1, :optional, true)), else: artifacts

    {evidence, artifacts}
  end

  @doc "Converts legacy persistence values, preserving struct tags and inspection fallbacks."
  @spec json_safe(term()) :: term()
  def json_safe(value) do
    safe = do_json_safe(value)

    case Jason.encode(safe) do
      {:ok, _encoded} -> safe
      {:error, _reason} -> inspect(value)
    end
  end

  defp trace_value(_value, _artifacts?, depth) when depth >= 16, do: "[omitted]"

  defp trace_value(%Record{} = record, artifacts?, depth) do
    fields =
      record
      |> Record.metadata()
      # The metadata contract owns this allowlist; its keys are existing Record fields.
      |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
      |> Map.merge(%{content: nil, materialization_handle: nil, provenance_ref: nil})

    safe = trace_map(fields, artifacts?, depth)
    if artifacts?, do: %{struct(Record, safe) | content: record.content}, else: safe
  end

  defp trace_value(%ToolResult{} = result, artifacts?, depth) do
    fields = result |> Map.from_struct() |> Map.put(:content, nil) |> trace_map(artifacts?, depth)
    if artifacts?, do: struct(ToolResult, fields), else: fields
  end

  defp trace_value(%ContentPart{} = part, true, depth) do
    fields = part |> Map.from_struct() |> Map.put(:data, nil) |> trace_map(false, depth)
    %{struct(ContentPart, fields) | data: part.data}
  end

  defp trace_value(%ContentPart{} = part, false, depth),
    do: part |> Map.from_struct() |> Map.drop([:data, :url]) |> trace_map(false, depth)

  defp trace_value(%_{} = value, _artifacts?, _depth),
    do: ToolError.trace_summary(value)

  defp trace_value(value, artifacts?, depth) when is_map(value),
    do: trace_map(value, artifacts?, depth)

  defp trace_value(value, artifacts?, depth) when is_tuple(value),
    do:
      value
      |> Tuple.to_list()
      |> Enum.map(&trace_value(&1, artifacts?, depth + 1))
      |> List.to_tuple()

  defp trace_value(value, artifacts?, depth) when is_list(value),
    do: value |> Enum.take(100) |> Enum.map(&trace_value(&1, artifacts?, depth + 1))

  defp trace_value(value, _artifacts?, _depth)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_atom(value), do: value

  defp trace_value(value, _artifacts?, _depth) when is_binary(value) do
    if String.valid?(value),
      do: Observe.sanitize_transport_payload(value),
      else: "[binary omitted]"
  end

  defp trace_value(_value, _artifacts?, _depth), do: "[runtime value omitted]"

  defp trace_map(map, artifacts?, depth) do
    map
    |> Enum.take(100)
    |> Map.new(fn {key, _value} ->
      capability? =
        key in [
          :materialization_handle,
          "materialization_handle",
          :provenance_ref,
          "provenance_ref"
        ]

      {key, if(capability?, do: "[REDACTED]", else: nil)}
    end)
    |> Observe.sanitize_sensitive()
    |> Map.new(fn {key, redaction} ->
      value =
        if is_nil(redaction),
          do: trace_value(Map.get(map, key), artifacts?, depth + 1),
          else: redaction

      {key, value}
    end)
  end

  defp externalize_trace_artifacts(
         {:ok, %ToolResult{} = tool_result, effects},
         tool_call_id,
         tool_name,
         nested?
       ) do
    case externalize_trace_artifacts(
           {:ok, tool_result.output, effects},
           tool_call_id,
           tool_name,
           nested?
         ) do
      {{:ok, output, _effects}, artifacts} ->
        {{:ok, %{tool_result | output: output, content: nil}, effects}, artifacts}

      {result, artifacts} ->
        {result, artifacts}
    end
  end

  defp externalize_trace_artifacts({:ok, %Record{} = record, effects}, id, name, true) do
    {{:ok, %{record: safe}, effects}, artifacts} =
      externalize_record_artifact(%{record: record}, effects, id, name, true)

    {{:ok, safe, effects}, artifacts}
  end

  defp externalize_trace_artifacts({:ok, payload, effects}, tool_call_id, tool_name, nested?)
       when is_map(payload) do
    {parts, payload} = skill_resource_parts(payload)

    {{:ok, safe_payload, effects}, record_artifacts} =
      externalize_record_artifact(payload, effects, tool_call_id, tool_name, nested?)

    part_artifacts = skill_resource_artifacts(parts, safe_payload, tool_call_id, tool_name)
    {{:ok, safe_payload, effects}, record_artifacts ++ part_artifacts}
  end

  defp externalize_trace_artifacts(result, _tool_call_id, _tool_name, _nested?), do: {result, []}

  defp externalize_record_artifact(payload, effects, tool_call_id, tool_name, nested?) do
    case payload_record(payload) do
      {key, %Record{} = record} ->
        case trace_media_artifact(record, tool_call_id, tool_name, nested?) do
          {:ok, artifact} ->
            safe_record = %{record | content: nil}
            {{:ok, Map.put(payload, key, safe_record), effects}, [artifact]}

          {:error, _reason} ->
            safe_record = %{record | content: nil}
            {{:ok, Map.put(payload, key, safe_record), effects}, []}

          :not_media ->
            {{:ok, payload, effects}, []}
        end

      nil ->
        {{:ok, payload, effects}, []}
    end
  end

  defp skill_resource_parts(payload) do
    case Map.get(payload, :__content_parts__) || Map.get(payload, "__content_parts__") do
      parts when is_list(parts) ->
        {parts, Map.drop(payload, [:__content_parts__, "__content_parts__"])}

      _parts ->
        {[], payload}
    end
  end

  defp skill_resource_artifacts(parts, payload, tool_call_id, tool_name) do
    Enum.flat_map(parts, fn
      %ContentPart{type: type, data: content} = part
      when type in [:image, :file] and is_binary(content) ->
        [
          %{
            record: json_safe(payload),
            content: content,
            name: artifact_text([part.filename, map_value(payload, :filename)], "skill-resource"),
            mime_type:
              artifact_text(
                [part.media_type, map_value(payload, :mime_type)],
                "application/octet-stream"
              ),
            size: byte_size(content),
            tool_call_id: tool_call_id,
            tool_name: tool_name || "tool"
          }
        ]

      _part ->
        []
    end)
  end

  defp map_value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp artifact_text(values, fallback) do
    Enum.find(values, fallback, &(is_binary(&1) and String.trim(&1) != ""))
  end

  defp payload_record(payload) do
    cond do
      match?(%Record{}, Map.get(payload, :record)) -> {:record, Map.get(payload, :record)}
      match?(%Record{}, Map.get(payload, "record")) -> {"record", Map.get(payload, "record")}
      true -> nil
    end
  end

  defp trace_media_artifact(
         %Record{content: content, attributes: attributes} = record,
         tool_call_id,
         tool_name,
         nested?
       )
       when is_binary(content) and is_map(attributes) do
    if nested? or source_type(attributes) == "communication_media" do
      case decode_record_content(record, content) do
        {:ok, decoded_content} ->
          {:ok,
           %{
             record: Record.metadata(record),
             content: decoded_content,
             name: artifact_text([record.name], "attachment"),
             mime_type: artifact_text([record.mime_type], "application/octet-stream"),
             size: byte_size(decoded_content),
             tool_call_id: tool_call_id,
             tool_name: tool_name || "tool"
           }}

        {:error, reason} ->
          {:error, reason}
      end
    else
      :not_media
    end
  end

  defp trace_media_artifact(_record, _tool_call_id, _tool_name, _nested?), do: :not_media

  defp decode_record_content(%Record{attributes: attributes}, content) do
    if encoding(attributes) == "base64" do
      case Base.decode64(content) do
        {:ok, decoded} -> {:ok, decoded}
        :error -> {:error, :invalid_encoding}
      end
    else
      {:ok, content}
    end
  end

  defp source_type(attributes),
    do: Map.get(attributes, "source_type") || Map.get(attributes, :source_type)

  defp encoding(attributes),
    do: Map.get(attributes, "encoding") || Map.get(attributes, :encoding)

  defp do_json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp do_json_safe(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp do_json_safe(%Date{} = value), do: Date.to_iso8601(value)
  defp do_json_safe(%Time{} = value), do: Time.to_iso8601(value)

  defp do_json_safe(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {safe_key(key), json_safe(value)} end)
    |> Map.put("__struct__", Atom.to_string(struct.__struct__))
  end

  defp do_json_safe(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {safe_key(key), json_safe(value)} end)
  end

  defp do_json_safe(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> do_json_safe()
  defp do_json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp do_json_safe(value) when is_atom(value), do: Atom.to_string(value)

  defp do_json_safe(value)
       when is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value), do: value

  defp do_json_safe(value) when is_float(value), do: value

  defp do_json_safe(value)
       when is_pid(value) or is_reference(value) or is_port(value) or is_function(value),
       do: inspect(value)

  defp do_json_safe(value), do: inspect(value)

  defp safe_key(key) when is_binary(key), do: key
  defp safe_key(key) when is_atom(key), do: Atom.to_string(key)
  defp safe_key(key), do: inspect(key)
end
