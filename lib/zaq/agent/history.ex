defmodule Zaq.Agent.History do
  @moduledoc """
  Shared helper for building and consuming the conversation history map.

  ## Key format

  History is stored as a plain map with string keys of the form:

      "<iso8601_datetime>_<index>_<role>"

  For example:

      "2026-03-24T10:30:00.000000Z_1_user"
      "2026-03-24T10:30:00.000000Z_2_bot"

  The `<index>` (`1` for user, `2` for bot) guarantees that within a turn
  the user message sorts before the bot reply when keys share the same
  timestamp. Use `entry_key/2` to produce keys so the format stays consistent
  across producers.
  """

  alias ReqLLM.Context

  @doc """
  Returns the history map key for a turn entry.

  `datetime` must be a `DateTime` struct; `role` is `:user` or `:bot`.

      iex> History.entry_key(~U[2026-03-24 10:30:00Z], :user)
      "2026-03-24T10:30:00Z_1_user"
  """
  @spec entry_key(DateTime.t(), :user | :bot) :: String.t()
  def entry_key(datetime, :user), do: "#{DateTime.to_iso8601(datetime)}_1_user"
  def entry_key(datetime, :bot), do: "#{DateTime.to_iso8601(datetime)}_2_bot"

  @doc """
  Converts a conversation history map into a list of `ReqLLM.Message` structs,
  sorted chronologically by key (see module doc for the key format).

  Returns `[]` when given an empty list or non-map value.
  """
  @spec build(map() | list()) :: [ReqLLM.Message.t()]
  def build([]), do: []

  def build(history) when is_map(history) do
    history
    |> Enum.sort_by(fn {key, _} ->
      case String.split(key, "_", parts: 3) do
        [ts, idx | _] -> {ts, idx}
        _ -> {key, "0"}
      end
    end)
    |> Enum.map(fn
      {_timestamp, %{"body" => msg, "type" => "bot"}} ->
        msg = if is_binary(msg), do: msg, else: Jason.encode!(msg)
        Context.assistant(msg)

      {_timestamp, %{"body" => msg, "type" => "user"}} ->
        msg = if is_binary(msg), do: msg, else: Jason.encode!(msg)
        Context.user(msg)
    end)
  end
end
