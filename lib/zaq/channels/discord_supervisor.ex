defmodule Zaq.Channels.DiscordSupervisor do
  @moduledoc """
  Supervises the full Discord/Nostrum stack with correct startup ordering.

  Nostrum.Shard.Supervisor requires at least one consumer to be registered in
  Nostrum.ConsumerGroup before it connects to the Discord gateway, or it times
  out and crashes. This supervisor enforces the required sequence:

    1. Nostrum infrastructure  (Store, ConsumerGroup, Api, Connector, Cache)
    2. Listener children       (NostrumGatewayBuffer + NostrumGatewayListener)
       → NostrumGatewayListener joins ConsumerGroup here, before shards connect
    3. Nostrum.Shard.Supervisor  (shards connect — consumer already registered)
    4. Nostrum.Voice.Supervisor
    5. GatewayWorker             (polls from buffer, safe to start any time after)
  """

  use Supervisor

  require Logger

  def start_link(listener_children) do
    Supervisor.start_link(__MODULE__, listener_children, name: __MODULE__)
  end

  def child_spec(listener_children) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [listener_children]},
      type: :supervisor,
      restart: :permanent
    }
  end

  @impl true
  def init(listener_children) do
    token = Application.fetch_env!(:nostrum, :token)
    {pre_shard_listeners, post_shard_listeners} = split_by_shard_dependency(listener_children)

    children =
      pre_shard_nostrum(token) ++
        pre_shard_listeners ++
        [Nostrum.Shard.Supervisor, Nostrum.Voice.Supervisor] ++
        post_shard_listeners

    Supervisor.init(children, strategy: :one_for_one)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp pre_shard_nostrum(token) do
    [
      Nostrum.Store.Supervisor,
      Nostrum.ConsumerGroup,
      Nostrum.Api.RatelimiterGroup,
      {Nostrum.Api.Ratelimiter, {token, []}},
      Nostrum.Shard.Connector,
      Nostrum.Cache.CacheSupervisor
    ]
  end

  # GatewayWorker only polls from the buffer — no need to precede the shard.
  # Everything else (Buffer + Listener) must be up before the shard connects.
  defp split_by_shard_dependency(children) do
    Enum.split_with(children, fn child ->
      case Map.get(child, :id) do
        {:discord_gateway_worker, _} -> false
        _ -> true
      end
    end)
  end
end
