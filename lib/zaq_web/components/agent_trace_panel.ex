defmodule ZaqWeb.Components.AgentTracePanel do
  @moduledoc """
  Agent/Model tiles, Measurements grid, and expandable Traces list for a
  message's agent telemetry (`%{agent:, model:, measurements:, traces:}`).

  Rendered in the chat message info popin (`ZaqWeb.Components.ChatMessage`)
  and inline on workflow run step cards.
  """

  use Phoenix.Component

  import ZaqWeb.CoreComponents, only: [icon: 1]

  attr :message_info, :map, default: %{}
  attr :expanded_ids, :any, default: nil
  attr :toggle_event, :string, required: true
  attr :testid, :string, default: "agent-trace-panel"
  attr :rest, :global, doc: "forwarded onto each trace-row button, e.g. phx-value-step_run_id"

  def agent_trace_panel(assigns) do
    assigns =
      assigns
      |> assign(:expanded_ids, assigns[:expanded_ids] || MapSet.new())
      |> assign(:traces, traces(assigns.message_info))
      |> assign(:measurements, measurements(assigns.message_info))
      |> assign(:agent_name, agent_name(assigns.message_info))
      |> assign(:model_name, model_name(assigns.message_info))

    ~H"""
    <div data-testid={@testid}>
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-2 mb-4">
        <div class="rounded-xl border border-[#e8e6e1] bg-[#fcfcfb] px-3 py-2">
          <p class="font-mono text-[0.62rem] uppercase tracking-widest text-[#9e9b94]">Agent</p>
          <p class="font-mono text-[0.75rem] text-[#2c2b28] truncate">{@agent_name}</p>
        </div>
        <div class="rounded-xl border border-[#e8e6e1] bg-[#fcfcfb] px-3 py-2">
          <p class="font-mono text-[0.62rem] uppercase tracking-widest text-[#9e9b94]">Model</p>
          <p class="font-mono text-[0.75rem] text-[#2c2b28] truncate">{@model_name}</p>
        </div>
      </div>

      <div class="mb-4">
        <p class="font-mono text-[0.68rem] font-bold text-[#7f7c76] mb-2">Measurements</p>
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
          <div
            :for={{key, value} <- @measurements}
            class="rounded-lg border border-[#ece9e3] bg-white px-2.5 py-2 flex items-center justify-between gap-3"
          >
            <span class="font-mono text-[0.66rem] text-[#7f7c76] truncate">{key}</span>
            <span class="font-mono text-[0.66rem] text-[#2c2b28]">
              {format_detail_value(value)}
            </span>
          </div>
          <p :if={@measurements == []} class="font-mono text-[0.66rem] text-[#9e9b94]">
            No measurements available.
          </p>
        </div>
      </div>

      <p class="font-mono text-[0.68rem] font-bold text-[#7f7c76] mb-2">
        Traces ({length(@traces)})
      </p>
      <ul class="space-y-2">
        <li
          :for={{trace, row_id} <- trace_rows(@traces)}
          class="border border-[#e8e6e1] rounded-xl overflow-hidden"
        >
          <button
            type="button"
            phx-click={@toggle_event}
            phx-value-trace_id={row_id}
            class="w-full text-left px-3 py-2.5 flex items-center justify-between hover:bg-[#faf9f7]"
            data-testid={"trace-row-#{row_id}"}
            {@rest}
          >
            <span class="font-mono text-[0.75rem] text-[#2c2b28] truncate">
              {trace_label(trace)}
            </span>
            <span class="font-mono text-[0.62rem] text-[#9e9b94]">
              {format_response_time(trace_duration_ms(trace))}
            </span>
          </button>

          <div
            :if={MapSet.member?(@expanded_ids, row_id)}
            class="px-3 pb-3 pt-1 bg-[#fcfcfb] border-t border-[#f0ede8]"
            data-testid={"trace-details-#{row_id}"}
          >
            <%!-- A file the agent read. The bytes are in `message_trace_artifacts`, not in the
                  entry below, so the chip draws from the metadata and fetches only on click. --%>
            <a
              :if={artifact = trace_artifact(trace)}
              href={"/bo/trace-artifacts/#{artifact.id}"}
              target="_blank"
              class="flex items-center gap-2 mt-2 px-2 py-1.5 rounded-lg border border-[#e8e6e1] bg-white hover:bg-[#faf9f7]"
              data-testid="trace-artifact-link"
            >
              <.icon name={artifact_icon(artifact.mime_type)} class="zaq-icon-sm" />
              <span class="font-mono text-[0.7rem] text-[#2c2b28] truncate">{artifact.name}</span>
              <span :if={artifact.size} class="font-mono text-[0.62rem] text-[#9e9b94] ml-auto">
                {format_bytes(artifact.size)}
              </span>
            </a>

            <div class="flex items-center justify-between mt-2 mb-1">
              <p class="font-mono text-[0.68rem] text-[#7f7c76] font-bold">Full JSON</p>
              <button
                type="button"
                phx-click="copy_message"
                phx-value-text={pretty_json(trace)}
                class="font-mono text-[0.62rem] px-2 py-1 rounded-md border border-black/10 text-black/60 hover:bg-black/5"
                title="Copy trace JSON"
              >
                Copy
              </button>
            </div>
            <pre class="font-mono text-[0.66rem] leading-relaxed text-[#2c2b28] bg-white border border-[#ece9e3] rounded-lg p-2 overflow-x-auto">{pretty_json(trace)}</pre>
          </div>
        </li>
      </ul>
    </div>
    """
  end

  @doc """
  The file a trace entry's tool read, or `nil` when it read none.

  Everything the chip needs is on the entry already — the tool result keeps name, type and size
  after `Zaq.Agent.TraceArtifact` takes the bytes out — so drawing a row costs no query.
  """
  def trace_artifact(%{"response" => %{"record" => record}}) when is_map(record) do
    case get_in(record, ["attributes", "trace_artifact_id"]) do
      id when is_binary(id) and id != "" ->
        %{
          id: id,
          name: Map.get(record, "name") || "attachment",
          mime_type: Map.get(record, "mime_type"),
          size: Map.get(record, "size")
        }

      _no_artifact ->
        nil
    end
  end

  def trace_artifact(_trace), do: nil

  @doc "Heroicon for a file, chosen from what the bytes were sniffed as."
  def artifact_icon("image/" <> _subtype), do: "hero-photo"
  def artifact_icon("audio/" <> _subtype), do: "hero-musical-note"
  def artifact_icon("video/" <> _subtype), do: "hero-film"
  def artifact_icon(_mime_type), do: "hero-document"

  @doc "Byte count as a reviewer reads it."
  def format_bytes(bytes) when is_integer(bytes) and bytes >= 1_048_576,
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  def format_bytes(bytes) when is_integer(bytes) and bytes >= 1024,
    do: "#{Float.round(bytes / 1024, 1)} KB"

  def format_bytes(bytes) when is_integer(bytes), do: "#{bytes} B"
  def format_bytes(_bytes), do: nil

  defp traces(message_info) when is_map(message_info) do
    case Map.get(message_info, :traces) || Map.get(message_info, "traces") do
      traces when is_list(traces) -> Enum.filter(traces, &is_map/1)
      _ -> []
    end
  end

  defp traces(_), do: []

  defp measurements(message_info) when is_map(message_info) do
    case Map.get(message_info, :measurements) || Map.get(message_info, "measurements") do
      measurements when is_map(measurements) ->
        measurements
        |> Enum.sort_by(fn {key, _value} -> to_string(key) end)

      _ ->
        []
    end
  end

  defp measurements(_), do: []

  defp agent_name(message_info) when is_map(message_info) do
    agent = Map.get(message_info, :agent) || Map.get(message_info, "agent")

    cond do
      is_binary(agent) and agent != "" -> agent
      is_map(agent) -> Map.get(agent, :name) || Map.get(agent, "name") || "n/a"
      true -> "n/a"
    end
  end

  defp agent_name(_), do: "n/a"

  defp model_name(message_info) when is_map(message_info) do
    case Map.get(message_info, :model) || Map.get(message_info, "model") do
      model when is_binary(model) and model != "" -> model
      _ -> "n/a"
    end
  end

  defp model_name(_), do: "n/a"

  defp trace_label(trace) do
    type = trace_value(trace, [:type, "type"]) || legacy_trace_type(trace)

    name =
      trace_value(trace, [:name, "name", :tool_name, "tool_name"])

    label =
      [friendly_trace_part(type), friendly_trace_part(name)]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" · ")

    case label do
      "" -> "Trace"
      label -> label
    end
  end

  defp friendly_trace_part(value) when is_binary(value) and value != "" do
    value
    |> String.replace(~r/[_\.]+/, " ")
    |> String.trim()
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp friendly_trace_part(_), do: nil

  defp legacy_trace_type(trace) when is_map(trace) do
    if Map.has_key?(trace, :tool_name) || Map.has_key?(trace, "tool_name") ||
         Map.has_key?(trace, :tool_call_id) || Map.has_key?(trace, "tool_call_id") do
      "tool_call"
    end
  end

  # A reasoning and a content segment of the same LLM call share its call id,
  # so trace ids can collide and toggling one row would expand/collapse the
  # other. Suffix only colliding ids so every unique id (and its testid) keeps
  # its persisted shape.
  defp trace_rows(traces) do
    sorted = sort_traces_chronologically(traces)
    ids = Enum.map(sorted, &trace_id/1)
    frequencies = Enum.frequencies(ids)

    sorted
    |> Enum.zip(ids)
    |> Enum.with_index()
    |> Enum.map(fn {{trace, id}, index} ->
      if frequencies[id] > 1 do
        {trace, "#{id}:#{trace_value(trace, [:type, "type"]) || index}"}
      else
        {trace, id}
      end
    end)
  end

  defp trace_id(trace) do
    id =
      trace_value(trace, [
        :id,
        "id",
        :tool_call_id,
        "tool_call_id",
        :started_at,
        "started_at",
        :timestamp,
        "timestamp"
      ]) || inspect(trace)

    if is_binary(id), do: id, else: inspect(id)
  end

  defp format_response_time(ms) when is_integer(ms), do: "#{ms} ms"
  defp format_response_time(ms) when is_float(ms), do: "#{Float.round(ms, 2)} ms"
  defp format_response_time(_), do: "n/a"

  defp format_detail_value(nil), do: "n/a"
  defp format_detail_value(""), do: "n/a"
  defp format_detail_value(value) when is_binary(value), do: value
  defp format_detail_value(value), do: inspect(value)

  defp pretty_json(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(value, pretty: true, limit: :infinity)
    end
  end

  defp sort_traces_chronologically(traces) when is_list(traces) do
    Enum.sort_by(traces, &trace_timestamp_sort_key/1, :asc)
  end

  defp trace_timestamp_sort_key(trace) when is_map(trace) do
    ms = trace_value(trace, [:started_at_ms, "started_at_ms", :ended_at_ms, "ended_at_ms"])

    timestamp =
      trace_value(trace, [
        :started_at,
        "started_at",
        :ended_at,
        "ended_at",
        :timestamp,
        "timestamp"
      ])

    numeric_timestamp_sort_key(ms) || iso8601_timestamp_sort_key(timestamp)
  end

  defp trace_duration_ms(trace) when is_map(trace) do
    trace_value(trace, [:duration_ms, "duration_ms", :response_time_ms, "response_time_ms"])
  end

  defp trace_value(map, keys) when is_map(map), do: Enum.find_value(keys, &Map.get(map, &1))

  defp numeric_timestamp_sort_key(ms) when is_integer(ms), do: {0, ms}
  defp numeric_timestamp_sort_key(ms) when is_float(ms), do: {0, trunc(ms)}
  defp numeric_timestamp_sort_key(_), do: nil

  defp iso8601_timestamp_sort_key(timestamp) do
    case DateTime.from_iso8601(to_string(timestamp || "")) do
      {:ok, dt, _offset} -> {0, DateTime.to_unix(dt, :microsecond)}
      _ -> {1, 0}
    end
  end
end
