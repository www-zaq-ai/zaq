defmodule ZaqWeb.Live.BO.Communication.MessageHelpers do
  @moduledoc """
  Shared helpers for BO communication message feedback and message inspection.

  Used by:
  - `ZaqWeb.Live.BO.Communication.ChatLive`
  - `ZaqWeb.Live.BO.Communication.ConversationDetailLive`

  Provides common functions for:
  - Feedback rating attributes (positive/negative)
  - Message trace and metadata normalization
  - Modal state management helpers
  """

  alias Zaq.Engine.Messages.Measurements

  def positive_rater_attrs(current_user) do
    if current_user,
      do: %{user_id: current_user.id, rating: 5},
      else: %{channel_user_id: "bo_anonymous", rating: 5}
  end

  def negative_rater_attrs(current_user, reasons, comment) do
    full_comment =
      [Enum.join(reasons, ", "), comment]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    if current_user,
      do: %{
        user_id: current_user.id,
        rating: 1,
        comment: full_comment,
        feedback_reasons: reasons
      },
      else: %{
        channel_user_id: "bo_anonymous",
        rating: 1,
        comment: full_comment,
        feedback_reasons: reasons
      }
  end

  def open_feedback_modal(socket, message_id) do
    socket
    |> Phoenix.Component.assign(:show_feedback_modal, true)
    |> Phoenix.Component.assign(:feedback_message_id, message_id)
    |> Phoenix.Component.assign(:feedback_reasons, [])
    |> Phoenix.Component.assign(:feedback_comment, "")
  end

  def normalize_tool_calls(tool_calls) when is_list(tool_calls) do
    tool_calls
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn tc ->
      %{
        tool_call_id: Map.get(tc, :tool_call_id) || Map.get(tc, "tool_call_id"),
        tool_name: Map.get(tc, :tool_name) || Map.get(tc, "tool_name"),
        timestamp: Map.get(tc, :timestamp) || Map.get(tc, "timestamp"),
        params: Map.get(tc, :params) || Map.get(tc, "params"),
        response: Map.get(tc, :response) || Map.get(tc, "response"),
        response_time_ms: Map.get(tc, :response_time_ms) || Map.get(tc, "response_time_ms"),
        status: Map.get(tc, :status) || Map.get(tc, "status")
      }
    end)
  end

  def normalize_tool_calls(_), do: []

  def message_info_from_runtime(metadata) when is_map(metadata) do
    trace = get_any(metadata, [:trace, "trace"]) || []
    legacy_tool_calls = get_any(metadata, [:tool_calls, "tool_calls"]) || []

    %{
      agent: get_any(metadata, [:agent, "agent"]) || runtime_agent(metadata),
      model: get_any(metadata, [:model, "model"]),
      measurements: Measurements.message_info_measurements(metadata),
      traces: normalize_traces(trace, legacy_tool_calls)
    }
  end

  def message_info_from_runtime(_), do: empty_message_info()

  def message_info_from_message(nil), do: empty_message_info()

  def message_info_from_message(message) when is_map(message) do
    metadata = get_any(message, [:metadata, "metadata"]) || %{}
    trace = get_any(message, [:trace, "trace"]) || []
    legacy_tool_calls = get_any(metadata, ["tool_calls", :tool_calls]) || []

    %{
      agent: get_any(metadata, ["agent", :agent]),
      model: get_any(message, [:model, "model"]) || get_any(metadata, ["model", :model]),
      measurements: Measurements.message_info_measurements(message),
      traces: normalize_traces(trace, legacy_tool_calls)
    }
  end

  def empty_message_info, do: %{agent: nil, model: nil, measurements: %{}, traces: []}

  def message_info_available?(message_info) when is_map(message_info) do
    present?(get_any(message_info, [:agent, "agent"])) ||
      present?(get_any(message_info, [:model, "model"])) ||
      measurements_present?(get_any(message_info, [:measurements, "measurements"])) ||
      traces_present?(get_any(message_info, [:traces, "traces"]))
  end

  def message_info_available?(_), do: false

  def toggle_trace_details(expanded, trace_id) do
    if MapSet.member?(expanded, trace_id) do
      MapSet.delete(expanded, trace_id)
    else
      MapSet.put(expanded, trace_id)
    end
  end

  def infer_feedback_from_ratings([]), do: nil
  def infer_feedback_from_ratings([%{rating: r} | _]) when r >= 4, do: :positive
  def infer_feedback_from_ratings([%{rating: r} | _]) when r <= 2, do: :negative
  def infer_feedback_from_ratings(_), do: nil

  def toggle_reason(reasons, reason) do
    if reason in reasons,
      do: List.delete(reasons, reason),
      else: reasons ++ [reason]
  end

  def toggle_tool_call_details(expanded, tool_id) do
    if MapSet.member?(expanded, tool_id) do
      MapSet.delete(expanded, tool_id)
    else
      MapSet.put(expanded, tool_id)
    end
  end

  defp normalize_traces(trace, _legacy_tool_calls) when is_list(trace) and trace != [] do
    Enum.filter(trace, &is_map/1)
  end

  defp normalize_traces(_trace, legacy_tool_calls) when is_list(legacy_tool_calls) do
    Enum.filter(legacy_tool_calls, &is_map/1)
  end

  defp normalize_traces(_trace, _legacy_tool_calls), do: []

  defp runtime_agent(metadata) do
    case get_any(metadata, [:configured_agent_name, "configured_agent_name"]) do
      name when is_binary(name) and name != "" -> %{"name" => name}
      _ -> nil
    end
  end

  defp get_any(map, keys) when is_map(map), do: Enum.find_value(keys, &Map.get(map, &1))
  defp get_any(_map, _keys), do: nil

  defp present?(value), do: value not in [nil, "", %{}, []]

  defp measurements_present?(measurements) when is_map(measurements),
    do: map_size(measurements) > 0

  defp measurements_present?(_), do: false

  defp traces_present?(traces) when is_list(traces), do: traces != []
  defp traces_present?(_), do: false
end
