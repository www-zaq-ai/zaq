defmodule Zaq.Engine.Extension.Reader do
  @moduledoc "Owns blocking gRPC stream reads and hands off one decoded envelope at a time."

  alias Zaq.Engine.Extension.Protocol

  @doc "Reads until disconnect or rejection. The runtime owns deadlines and connection cleanup."
  @spec run(pid(), reference(), struct()) :: {:error, atom()}
  def run(owner, generation, stream) do
    case GRPC.Stub.recv(stream, timeout: :infinity) do
      {:ok, replies} -> read(replies, owner, generation, stream)
      {:error, _} -> {:error, :rpc_error}
    end
  rescue
    _ -> {:error, :rpc_error}
  catch
    :exit, _ -> {:error, :unreachable}
  end

  defp read(replies, owner, generation, stream) do
    replies
    |> Enum.reduce_while({:error, :unreachable}, fn
      {:ok, _frame}, {:rejected, reason} ->
        {:cont, {:rejected, reason}}

      {:error, _error}, {:rejected, reason} ->
        {:halt, {:error, reason}}

      {:ok, frame}, _acc ->
        case GenServer.call(owner, {:extension_frame, generation, frame}, :infinity) do
          :continue ->
            {:cont, {:error, :unreachable}}

          {:reject, reason} ->
            stream
            |> GRPC.Stub.send_request(Protocol.reject(frame.request_id, reason))
            |> GRPC.Stub.end_stream()

            # Gun acknowledges queueing, not peer receipt. Wait for trailers/close
            # before releasing this connection; the runtime still bounds this wait.
            {:cont, {:rejected, reason}}
        end

      {:error, %GRPC.RPCError{status: 8}}, _acc ->
        {:halt, {:error, :resource_exhausted}}

      {:error, _}, _acc ->
        {:halt, {:error, :rpc_error}}
    end)
    |> case do
      {:rejected, reason} -> {:error, reason}
      result -> result
    end
  end
end
