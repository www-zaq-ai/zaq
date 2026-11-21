defmodule Zaq.Engine.Extension.Writer do
  @moduledoc """
  Owns blocking Connect setup/writes and releases the named connection on owner death.

  Gun deliberately retains named connections across caller death. Monitoring the
  Extension runtime here gives that connection a lifetime even if the runtime is
  killed before its termination callback runs. Reads use a separate task because
  gRPC's reply enumerable blocks while this process must still send probes.
  """

  alias Zaq.Engine.Extension.{Client, Protocol}

  @doc "Connects, offers negotiation, and handles at most one runtime-issued write at a time."
  @spec run(pid(), reference(), String.t(), keyword()) :: :ok | {:error, atom()}
  def run(owner, generation, hello_id, opts) do
    monitor = Process.monitor(owner)

    try do
      with {:ok, stream} <- Client.connect(opts) do
        if stopped?(monitor) do
          :ok
        else
          stream = GRPC.Stub.send_request(stream, Protocol.hello(hello_id))
          send(owner, {:extension_stream, generation, stream})
          write_loop(owner, monitor, generation, stream)
        end
      end
    rescue
      _ -> {:error, :rpc_error}
    catch
      :exit, _ -> {:error, :unreachable}
    after
      Process.demonitor(monitor, [:flush])
      Client.disconnect(Keyword.fetch!(opts, :connection_name))
    end
  end

  defp write_loop(owner, monitor, generation, stream) do
    receive do
      {:write, frame} ->
        stream = GRPC.Stub.send_request(stream, frame)
        send(owner, {:extension_sent, generation})
        write_loop(owner, monitor, generation, stream)

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        :ok

      :stop ->
        :ok
    end
  end

  defp stopped?(monitor) do
    receive do
      {:DOWN, ^monitor, :process, _owner, _reason} -> true
      :stop -> true
    after
      0 -> false
    end
  end
end
