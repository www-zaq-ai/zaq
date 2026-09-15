defmodule Zaq.People.AuthRateLimiter.Listener do
  @moduledoc false
  use GenServer

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @impl true
  def init(opts) do
    :ok = Phoenix.PubSub.subscribe(Keyword.fetch!(opts, :pubsub), Keyword.fetch!(opts, :topic))
    {:ok, Keyword.fetch!(opts, :local)}
  end

  @impl true
  def handle_info({:inc, key, scale, increment}, local) do
    _count = local.inc(key, scale, increment)
    {:noreply, local}
  end
end
