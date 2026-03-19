defmodule Zaq.Channels.Retrieval.Mattermost.DispatchHook do
  @moduledoc """
  Hook handler that wires Mattermost into the :before_question_dispatched chain.

  Runs at priority 10 (before PendingQuestions at 50) and injects a `send_fn`
  into the payload when the provider is "mattermost". The downstream
  PendingQuestions handler uses `send_fn` to actually post the message and
  register the pending reply callback.
  """

  @behaviour Zaq.Hooks.Handler

  alias Zaq.Channels.Retrieval.Mattermost

  def register do
    Zaq.Hooks.Registry.register(%Zaq.Hooks.Hook{
      handler: __MODULE__,
      events: [:before_question_dispatched],
      mode: :sync,
      node_role: :local,
      priority: 10
    })
  end

  @impl Zaq.Hooks.Handler
  def handle(:before_question_dispatched, %{provider: "mattermost"} = payload, _ctx) do
    send_fn = fn channel_id, question ->
      case Mattermost.send_question(channel_id, question) do
        {:ok, post_id} -> {:ok, %{"id" => post_id}}
        error -> error
      end
    end

    {:ok, Map.put(payload, :send_fn, send_fn)}
  end

  def handle(_event, payload, _ctx), do: {:ok, payload}
end
