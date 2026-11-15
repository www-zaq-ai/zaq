defmodule Zaq.TestSupport.HttpFaultRouter do
  @moduledoc "Routes through NodeRouter with a process-local failing remote RPC boundary."

  alias Zaq.{Event, NodeRouter}

  def dispatch(%Event{} = event) do
    {kind, sentinel} = Process.get({__MODULE__, :failure})

    NodeRouter.dispatch(event, %{
      node_list_fn: fn -> [:http_fault@remote] end,
      whereis_fn: fn _supervisor -> nil end,
      rpc_call_fn: fn
        :http_fault@remote, Process, :whereis, [Zaq.Channels.Supervisor] ->
          self()

        :http_fault@remote,
        Zaq.Channels.Api,
        :handle_event,
        [%Event{opts: [{:action, :http_request} | _]} = request, :http_request, nil] ->
          send(self(), {:http_rpc, request})
          fail(kind, sentinel)
      end
    })
  end

  defp fail(:raise, sentinel), do: raise(sentinel)
  defp fail(:throw, sentinel), do: throw({:http_rpc_failed, sentinel})
  defp fail(:exit, sentinel), do: exit({:http_rpc_failed, sentinel})
end
