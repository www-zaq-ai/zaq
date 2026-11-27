defmodule Zaq.Engine.Extension.Reader do
  @moduledoc "Owns blocking gRPC stream reads and hands off one decoded envelope at a time."

  alias Zaq.Engine.Extension.Protocol
  alias Zaq.Engine.Extension.Rpc.Gateway.V1.GatewayEnvelope

  @doc "Reads until disconnect or rejection. The runtime owns deadlines and connection cleanup."
  @spec run(pid(), reference(), struct(), pos_integer()) :: {:error, atom()}
  def run(owner, generation, stream, limit) do
    case GRPC.Stub.recv(stream, timeout: :infinity) do
      {:ok, replies} -> read(replies, owner, generation, stream, limit)
      {:error, _} -> {:error, :rpc_error}
    end
  rescue
    _ -> {:error, :rpc_error}
  catch
    :exit, _ -> {:error, :unreachable}
  end

  defp read(replies, owner, generation, stream, limit) do
    replies
    |> Enum.reduce_while({:reading, limit}, fn
      {:ok, _frame}, {:rejected, reason} ->
        {:cont, {:rejected, reason}}

      {:error, _error}, {:rejected, reason} ->
        {:halt, {:error, reason}}

      {:ok, bytes}, {:reading, limit} ->
        handle_message(bytes, owner, generation, stream, limit)

      {:error, %GRPC.RPCError{status: 8}}, _acc ->
        {:halt, {:error, :resource_exhausted}}

      {:error, _}, _acc ->
        {:halt, {:error, :rpc_error}}
    end)
    |> case do
      {:rejected, reason} -> {:error, reason}
      {:reading, _limit} -> {:error, :unreachable}
      result -> result
    end
  end

  defp handle_message(bytes, owner, generation, stream, limit) when byte_size(bytes) > limit do
    {:reject, reason} = GenServer.call(owner, {:oversized_extension_frame, generation}, :infinity)
    reject(stream, "", reason)
  end

  defp handle_message(bytes, owner, generation, stream, limit) do
    received_at = System.monotonic_time(:millisecond)
    frame = GatewayEnvelope.decode(bytes)

    case GenServer.call(owner, {:extension_frame, generation, frame, received_at}, :infinity) do
      :continue -> {:cont, {:reading, limit}}
      {:continue, selected_limit} -> {:cont, {:reading, selected_limit}}
      {:reject, reason} -> reject(stream, frame.request_id, reason)
    end
  end

  defp reject(stream, id, reason) do
    stream
    |> GRPC.Stub.send_request(Protocol.reject(id, reason))
    |> GRPC.Stub.end_stream()

    # Gun acknowledges queueing, not peer receipt. The runtime bounds the wait for trailers.
    {:cont, {:rejected, reason}}
  end
end
