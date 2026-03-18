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

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.PendingQuestions
  alias Zaq.Engine.RetrievalSupervisor

  @doc """
  Dispatches a question to the retrieval channel identified by `channel_id`
  and registers `on_answer` as the callback when a reply arrives.

  Returns `{:ok, post_id}` on success or `{:error, reason}` on failure.
  `{:error, :no_adapter}` is returned when no enabled channel config or
  adapter module is found for the given `channel_id`.
  """
  @spec dispatch_question(String.t(), String.t(), (String.t() -> any())) ::
          {:ok, String.t()} | {:error, term()}
  def dispatch_question(channel_id, question, on_answer) do
    case resolve_adapter(channel_id) do
      {:ok, adapter} ->
        send_fn = build_send_fn(adapter)
        pending_questions_module().ask(channel_id, "zaq_engine", question, send_fn, on_answer)

      error ->
        error
    end
  end

  # --- Private ---

  defp build_send_fn(adapter) do
    fn ch, q ->
      case adapter.send_question(ch, q) do
        {:ok, post_id} -> {:ok, %{"id" => post_id}}
        error -> error
      end
    end
  end

  defp resolve_adapter(channel_id) do
    case channel_config_module().get_by_channel_id(channel_id) do
      nil ->
        {:error, :no_adapter}

      %{provider: provider} ->
        case retrieval_supervisor_module().adapter_for(provider) do
          nil -> {:error, :no_adapter}
          adapter -> {:ok, adapter}
        end
    end
  end

  defp channel_config_module do
    Application.get_env(:zaq, :channel_config_module, ChannelConfig)
  end

  defp retrieval_supervisor_module do
    Application.get_env(:zaq, :retrieval_supervisor_module, RetrievalSupervisor)
  end

  defp pending_questions_module do
    Application.get_env(:zaq, :pending_questions_module, PendingQuestions)
  end
end
