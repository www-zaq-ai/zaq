defmodule Zaq.TestSupport.Channels.RuntimeAdapterStub do
  @moduledoc false

  def listener_child_specs(bridge_id, _opts) do
    {:ok,
     [
       %{
         id: {:listener, bridge_id},
         start: {Agent, :start_link, [fn -> :listener end]},
         restart: :temporary,
         type: :worker
       }
     ]}
  end
end
