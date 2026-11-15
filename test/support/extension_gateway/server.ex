defmodule Zaq.ExtensionGateway.Server do
  @moduledoc false

  use GRPC.Server, service: Zaq.Engine.Extension.Rpc.Gateway.V1.Gateway.Service

  alias Zaq.Engine.Extension.Rpc.Gateway.V1.{
    GatewayEnvelope,
    GatewayHello,
    HealthRequest,
    HealthResponse,
    ZaqEnvelope
  }

  def health(%HealthRequest{} = request, stream) do
    {response, notify} = GenServer.call(stream.local, :response)
    if notify, do: send(notify, {:gateway_unary_health, stream.local})
    if notify, do: send(notify, {:gateway_request, stream.local, self(), request})
    reply(response, stream.local)
  end

  def connect(requests, stream) do
    :ok = GenServer.call(stream.local, {:stream, stream})
    {_, notify} = GenServer.call(stream.local, :response)
    if notify, do: send(notify, {:gateway_connected, stream.local, self()})

    Enum.each(requests, &handle_frame(&1, stream))
  end

  defp handle_frame(%ZaqEnvelope{payload: {:hello, _}} = frame, stream) do
    {_, notify} = GenServer.call(stream.local, :response)
    if notify, do: send(notify, {:gateway_hello, stream.local, elem(frame.payload, 1)})
    hello = GenServer.call(stream.local, :hello)
    send_hello(hello, frame.request_id, stream)
  end

  defp handle_frame(%ZaqEnvelope{payload: {:health_request, request}} = frame, stream) do
    {response, notify} = GenServer.call(stream.local, :response)
    if notify, do: send(notify, {:gateway_request, stream.local, self(), request})
    GRPC.Server.send_reply(stream, stream_response(response, frame.request_id, stream.local))
  end

  defp handle_frame(%ZaqEnvelope{payload: {:error, error}}, stream) do
    {_, notify} = GenServer.call(stream.local, :response)
    if notify, do: send(notify, {:gateway_rejection, stream.local, error})
  end

  defp send_hello(:unimplemented, _id, _stream),
    do: raise(GRPC.RPCError, status: :unimplemented)

  defp send_hello({:await, hello}, id, stream) do
    receive do
      {:release, gateway} when gateway == stream.local -> send_hello(hello, id, stream)
    after
      5_000 -> raise GRPC.RPCError, status: :deadline_exceeded
    end
  end

  defp send_hello(hello, id, stream), do: GRPC.Server.send_reply(stream, envelope(id, hello))

  defp stream_response({:frame, frame}, _id, _gateway), do: frame

  defp stream_response(response, id, gateway),
    do: envelope(id, {:health_response, reply(response, gateway)})

  defp envelope(id, {:hello, %GatewayHello{} = hello}),
    do: %GatewayEnvelope{request_id: id, protocol_version: 1, payload: {:hello, hello}}

  defp envelope(id, payload),
    do: %GatewayEnvelope{request_id: id, protocol_version: 1, payload: payload}

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
