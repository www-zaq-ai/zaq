defmodule Zaq.Channels.EmailBridge.ImapAdapter.RuntimeState do
  @moduledoc false

  use GenServer

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(opts) do
    {:ok, %{bridge_id: Keyword.get(opts, :bridge_id), config: Keyword.get(opts, :config)}}
  end
end
