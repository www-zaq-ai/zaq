defmodule Zaq.Engine.Router do
  @moduledoc """
  Central dispatch point for features that need to send a question to a
  retrieval channel and await a reply.

  Resolves the correct adapter from the configured `ChannelConfig` records,
  dispatches the question through it, and wires `PendingQuestions` so that
  when the SME replies in-thread the `on_answer` callback fires.

  ## Usage

      Zaq.Engine.Router.dispatch_question(channel_id, question, fn answer ->
        # handle answer
      end)

  Any feature using this function is decoupled from the underlying platform.
  Adding a new adapter (Slack, Teams, ...) requires no changes here.
  """

  @doc """
  Dispatches a question to the retrieval channel identified by `channel_id`
  and registers `on_answer` as the callback when a reply arrives.

  Returns `{:ok, post_id}` on success or `{:error, reason}` on failure.
  `{:error, :no_adapter}` is returned when no enabled channel config or
  adapter module is found for the given `channel_id`.
  """
  @spec dispatch_question(String.t(), String.t(), String.t(), (String.t() -> any())) ::
          {:ok, String.t()} | {:error, term()}
  def dispatch_question(provider, channel_id, question, on_answer) do
    payload = %{
      provider: provider,
      channel_id: channel_id,
      question: question,
      callback: on_answer
    }

    case run_sync_hooks(:before_question_dispatched, payload) do
      {:ok, %{post_id: post_id}} -> {:ok, post_id}
      {:ok, _} -> {:error, :dispatch_failed}
      {:halt, _} -> {:error, :dispatch_halted}
    end
  end

  # --- Private ---

  defp run_sync_hooks(event, payload) do
    hooks =
      Zaq.Hooks.Registry.lookup(event)
      |> Enum.filter(&(&1.mode == :sync))

    Enum.reduce_while(hooks, {:ok, payload}, fn hook, {:ok, acc} ->
      ctx = %{trace_id: nil, node: node()}

      case hook.handler.handle(event, acc, ctx) do
        {:ok, new_payload} -> {:cont, {:ok, new_payload}}
        {:halt, p} -> {:halt, {:halt, p}}
        {:error, _} -> {:cont, {:ok, acc}}
        :ok -> {:cont, {:ok, acc}}
      end
    end)
  end
end
