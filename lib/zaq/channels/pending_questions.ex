defmodule Zaq.Channels.PendingQuestions do
  @moduledoc """
  Tracks questions awaiting answers across any channel connector (Mattermost, Slack, Teams, etc.).
  State: %{post_id => %{bot_user_id: String.t(), callback: fun}}
  """

  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc """
  Sends a question via the provided `send_fn` and tracks it for reply matching.

  `send_fn` must be a 2-arity function `(channel_id, question)` that returns
  `{:ok, %{"id" => post_id, "user_id" => bot_user_id}}` or `{:ok, %{"id" => post_id}}` or `{:error, reason}`.
  """
  def ask(channel_id, user_id, question, send_fn, on_answer) do
    case send_fn.(channel_id, question) do
      {:ok, %{"id" => post_id, "user_id" => bot_user_id}} ->
        Agent.update(__MODULE__, fn state ->
          Map.put(state, post_id, %{bot_user_id: bot_user_id, callback: on_answer})
        end)

        {:ok, post_id}

      {:ok, %{"id" => post_id}} ->
        Agent.update(__MODULE__, fn state ->
          Map.put(state, post_id, %{bot_user_id: user_id, callback: on_answer})
        end)

        {:ok, post_id}

      error ->
        error
    end
  end

  @doc """
  Checks if a message is a reply to a pending question thread.
  Any user can answer except the bot that posted the question.
  """
  def check_reply(%{root_id: root_id, user_id: user_id, message: message})
      when root_id != "" do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state, root_id) do
        %{bot_user_id: ^user_id} ->
          {:ignore, state}

        %{callback: callback} ->
          {{:answered, message, callback}, Map.delete(state, root_id)}

        _ ->
          {:ignore, state}
      end
    end)
  end

  def check_reply(_post), do: :ignore

  def pending do
    Agent.get(__MODULE__, & &1)
  end
end
