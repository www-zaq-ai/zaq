defmodule Zaq.ExtensionGateway.Rust do
  @moduledoc "Explicitly opt-in commercial binary launcher; never started by ordinary tests."

  use GenServer, restart: :temporary

  def start!(directory) do
    binary =
      System.get_env("GATEWAY_BINARY") ||
        raise "Set GATEWAY_BINARY to a built commercial gateway to run --include commercial_gateway"

    config_path = Path.join(directory, "gateway.toml")

    File.write!(config_path, """
    socket_path = "#{directory}/gateway.sock"
    log_filter = "off"
    [tls]
    ca_cert = "#{directory}/ca.pem"
    server_cert = "#{directory}/server.pem"
    server_key = "#{directory}/server.key"
    client_cert = "#{directory}/client.pem"
    client_key = "#{directory}/client.key"
    server_name = "gateway.local"
    """)

    owner =
      ExUnit.Callbacks.start_supervised!({__MODULE__, {Path.expand(binary), config_path}},
        id: make_ref()
      )

    await_socket!(Path.join(directory, "gateway.sock"), 100)
    owner
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def stop(owner) do
    GenServer.stop(owner)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init({binary, config_path}) do
    Process.flag(:trap_exit, true)

    removed =
      for {key, _} <- System.get_env(),
          String.starts_with?(key, "GATEWAY_"),
          key != "GATEWAY_CONFIG",
          do: {String.to_charlist(key), false}

    port =
      Port.open({:spawn_executable, binary}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:env, [{~c"GATEWAY_CONFIG", String.to_charlist(config_path)} | removed]}
      ])

    {:ok, port}
  end

  @impl true
  def handle_info({_port, {:exit_status, _status}}, port), do: {:stop, :normal, port}
  def handle_info(_message, port), do: {:noreply, port}

  @impl true
  def terminate(_reason, port) do
    if info = Port.info(port, :os_pid) do
      {:os_pid, pid} = info
      System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)

      receive do
        {^port, {:exit_status, _status}} -> :ok
      after
        2_000 -> Port.close(port)
      end
    end

    :ok
  end

  defp await_socket!(path, attempts) when attempts > 0 do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(20)
      await_socket!(path, attempts - 1)
    end
  end

  defp await_socket!(_path, 0), do: raise("commercial gateway did not create its socket")
end
