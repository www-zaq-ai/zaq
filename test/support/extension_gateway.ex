defmodule Zaq.ExtensionGateway do
  @moduledoc "Test-only protobuf gateway with an isolated TLS/UDS listener and programmable Health replies."

  use GenServer, restart: :temporary

  alias GRPC.Server.Adapters.Cowboy.{Handler, Router}
  alias Zaq.ExtensionGateway.{Certificates, Server}

  defdelegate certificates!(directory), to: Certificates, as: :generate!

  def start!(directory, opts \\ []) do
    opts = Keyword.put_new(opts, :notify, self())
    ExUnit.Callbacks.start_supervised!({__MODULE__, {directory, opts}}, id: make_ref())
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def stop(owner) do
    GenServer.stop(owner)
  catch
    :exit, _ -> :ok
  end

  def respond(gateway, response), do: GenServer.call(gateway, {:respond, response})

  @impl true
  def init({directory, opts}) do
    Process.flag(:trap_exit, true)
    reference = make_ref()
    socket = Path.join(directory, "gateway.sock")

    routes =
      for {:grpc, path} <- Server.__meta__(:routes) do
        {path, Handler,
         {nil, {Server.__meta__(:service).__meta__(:name), Server}, path, %{local: self()}}}
      end

    transport = %{
      connection_type: :supervisor,
      num_acceptors: 2,
      socket_opts: [
        ip: {:local, socket},
        port: 0,
        versions: [:"tlsv1.3"],
        verify: :verify_peer,
        fail_if_no_peer_cert: true,
        cacertfile: Path.join(directory, "ca.pem"),
        certfile: Path.join(directory, "server.pem"),
        keyfile: Path.join(directory, "server.key"),
        alpn_preferred_protocols: ["h2"]
      ]
    }

    # grpc_server's wrapper names listeners by module and logs an IP address.
    # Its wire handler works over UDS; own the Ranch listener to isolate fixtures.
    protocol = %{
      connection_type: :supervisor,
      env: %{dispatch: Router.compile([{:_, routes}])},
      stream_handlers: [:grpc_stream_h],
      idle_timeout: 5_000
    }

    case start_listener(reference, socket, transport, protocol) do
      {:ok, listener} ->
        case File.chmod(socket, 0o600) do
          :ok ->
            monitor = Process.monitor(listener)

            {:ok,
             %{
               reference: reference,
               monitor: monitor,
               socket: socket,
               response: Keyword.get(opts, :response, {:ok, "ok"}),
               notify: opts[:notify]
             }}

          {:error, reason} ->
            :ranch.stop_listener(reference)
            File.rm(socket)
            {:stop, reason}
        end

      {:error, :socket_exists} ->
        {:stop, :socket_exists}

      {:error, reason} ->
        File.rm(socket)
        {:stop, reason}
    end
  end

  defp start_listener(reference, socket, transport, protocol) do
    case File.lstat(socket) do
      {:error, :enoent} ->
        :ranch.start_listener(reference, :ranch_ssl, transport, :cowboy_tls, protocol)

      _ ->
        {:error, :socket_exists}
    end
  end

  @impl true
  def handle_call(:response, _from, state), do: {:reply, {state.response, state.notify}, state}

  def handle_call({:respond, response}, _from, state),
    do: {:reply, :ok, %{state | response: response}}

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, reason}, %{monitor: monitor} = state),
    do: {:stop, reason, state}

  @impl true
  def terminate(_reason, state) do
    :ranch.stop_listener(state.reference)
    File.rm(state.socket)
    :ok
  end
end
