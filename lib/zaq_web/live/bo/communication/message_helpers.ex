defmodule ZaqWeb.Live.BO.Communication.MessageHelpers do
  @moduledoc """
  Shared helpers for BO communication message feedback and tool calls.
  """

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
    |> Enum.sort_by(fn tc -> tool_call_sort_key(tc.response_time_ms) end, :desc)
  end

  def normalize_tool_calls(_), do: []

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

  defp tool_call_sort_key(ms) when is_integer(ms), do: ms
  defp tool_call_sort_key(ms) when is_float(ms), do: ms
  defp tool_call_sort_key(_), do: -1
end
