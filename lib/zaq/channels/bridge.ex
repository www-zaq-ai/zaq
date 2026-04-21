defmodule Zaq.Channels.Bridge do
  @moduledoc """
  Behaviour and shared helpers for channel bridge modules.

  All bridges must expose a canonical inbound mapper (`to_internal/2`) and
  outbound sender (`send_reply/2`). Runtime/lifecycle callbacks vary by bridge
  type and are optional.
  """

  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.NodeRouter

  @callback to_internal(map(), map()) :: Incoming.t() | {:error, term()}
  @callback send_reply(term(), map()) :: :ok | {:error, term()}

  @callback start_runtime(map()) :: :ok | {:error, term()}
  @callback stop_runtime(map()) :: :ok | {:error, term()}
  @callback send_typing(map() | atom() | String.t(), String.t(), map()) :: :ok | {:error, term()}

  @callback add_reaction(
              map() | atom() | String.t(),
              String.t(),
              String.t(),
              String.t(),
              map()
            ) :: :ok | {:error, term()}

  @callback remove_reaction(
              map() | atom() | String.t(),
              String.t(),
              String.t(),
              String.t(),
              map()
            ) :: :ok | {:error, term()}

  @callback subscribe_thread_reply(map(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback unsubscribe_thread_reply(map(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback open_dm_channel(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  @callback fetch_profile(String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback test_connection(map(), String.t()) :: {:ok, term()} | {:error, term()}
  @callback list_mailboxes(map(), map()) :: {:ok, [String.t()]} | {:error, term()}
  @callback resolve_agent_selection(map(), Incoming.t(), keyword()) :: map() | nil

  @optional_callbacks start_runtime: 1,
                      stop_runtime: 1,
                      send_typing: 3,
                      add_reaction: 5,
                      remove_reaction: 5,
                      subscribe_thread_reply: 3,
                      unsubscribe_thread_reply: 3,
                      open_dm_channel: 2,
                      fetch_profile: 2,
                      test_connection: 2,
                      list_mailboxes: 2,
                      resolve_agent_selection: 3

  @doc """
  Persists a processed incoming message and its metadata through the engine.

  If `conversations_module` is the default `Zaq.Engine.Conversations`, routing
  goes through `NodeRouter.dispatch/1` and the event envelope. Otherwise the
  override module is called directly for testability.
  """
  @spec persist_from_incoming(Incoming.t(), map(), module(), term(), module()) :: term()
  def persist_from_incoming(
        %Incoming{} = incoming,
        metadata,
        conversations_module,
        actor,
        node_router_module \\ NodeRouter
      )
      when is_map(metadata) and is_atom(conversations_module) and is_atom(node_router_module) do
    if conversations_module == Conversations do
      event =
        Event.new(
          %{incoming: incoming, metadata: metadata},
          :engine,
          actor: actor,
          opts: [action: :persist_from_incoming]
        )

      node_router_module.dispatch(event).response
    else
      conversations_module.persist_from_incoming(incoming, metadata)
    end
  end
end
