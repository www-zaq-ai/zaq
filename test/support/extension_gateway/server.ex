defmodule Zaq.ExtensionGateway.Server do
  @moduledoc false

  use GRPC.Server, service: Zaq.Engine.Extension.Rpc.Gateway.V1.Gateway.Service

  alias Zaq.Engine.Extension.Rpc.Gateway.V1.{HealthRequest, HealthResponse}

  def health(%HealthRequest{} = request, stream) do
    {response, notify} = GenServer.call(stream.local, :response)
    if notify, do: send(notify, {:gateway_request, stream.local, self(), request})
    reply(response, stream.local)
  end

  defp reply({:ok, status}, _gateway), do: %HealthResponse{status: status}
  defp reply({:error, status}, _gateway), do: raise(GRPC.RPCError, status: status)

  defp reply({:await, response}, gateway) do
    receive do
      {:release, ^gateway} -> reply(response, gateway)
    after
      5_000 -> raise GRPC.RPCError, status: :deadline_exceeded
    end
  end
end
