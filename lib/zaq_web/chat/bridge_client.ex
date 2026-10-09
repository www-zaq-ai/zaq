defmodule ZaqWeb.Chat.BridgeClient do
  @moduledoc """
  BO client for the shared WebBridge ingress contract.

  It constructs validated payload/context values and dispatches them through the
  Channels role. It does not build Engine Incoming messages or invoke WebBridge
  directly.
  """

  alias Zaq.Channels.Web.{Command, Context, Message}
  alias Zaq.Event
  alias Zaq.NodeRouter

  @context_keys [
    :consumer,
    :capabilities,
    :delivery,
    :selected_agent_id,
    :content_filter,
    :history
  ]

  @doc "Validates and dispatches one BO web message through Channels."
  @spec dispatch_message(map(), map(), keyword()) :: term()
  def dispatch_message(attrs, actor, opts \\ []) do
    with {:ok, message} <- Message.new(attrs),
         {:ok, context} <- Context.new(actor, Keyword.take(opts, @context_keys)) do
      dispatch(message, context, actor, opts)
    end
  end

  @doc "Validates and dispatches one BO web command through Channels."
  @spec dispatch_command(map(), map(), keyword()) :: term()
  def dispatch_command(attrs, actor, opts \\ []) do
    with {:ok, command} <- Command.new(attrs),
         {:ok, context} <- Context.new(actor, Keyword.take(opts, @context_keys)) do
      dispatch(command, context, actor, opts)
    end
  end

  defp dispatch(payload, context, actor, opts) do
    node_router = Keyword.get(opts, :node_router, NodeRouter)

    event_opts =
      [action: :web_ingress, node_router: node_router]
      |> maybe_put(:web_bridge_module, Keyword.get(opts, :web_bridge_module))
      |> maybe_put(:web_config, Keyword.get(opts, :web_config))

    %{payload: payload, context: context}
    |> Event.new(:channels, actor: actor, opts: event_opts)
    |> node_router.dispatch()
    |> case do
      %Event{response: response} -> response
      _ -> {:error, :channels_unavailable}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
