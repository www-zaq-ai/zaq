defmodule Zaq.ExtensionGateway do
  @moduledoc false

  def certificates!(directory) do
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)

    openssl!(directory, ~w(req -x509 -newkey ed25519 -nodes -days 1
      -keyout ca.key -out ca.pem -subj /CN=ExtensionTestCA
      -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign))

    for {identity, usage} <- [{"server", "serverAuth"}, {"client", "clientAuth"}] do
      openssl!(directory, [
        "req",
        "-new",
        "-newkey",
        "ed25519",
        "-nodes",
        "-keyout",
        "#{identity}.key",
        "-out",
        "#{identity}.csr",
        "-subj",
        "/CN=gateway.local"
      ])

      File.write!(Path.join(directory, "#{identity}.ext"), """
      basicConstraints=critical,CA:FALSE
      keyUsage=critical,digitalSignature
      extendedKeyUsage=#{usage}
      subjectAltName=DNS:gateway.local
      """)

      openssl!(directory, [
        "x509",
        "-req",
        "-days",
        "1",
        "-in",
        "#{identity}.csr",
        "-CA",
        "ca.pem",
        "-CAkey",
        "ca.key",
        "-CAcreateserial",
        "-out",
        "#{identity}.pem",
        "-extfile",
        "#{identity}.ext"
      ])
    end

    [
      socket_path: Path.join(directory, "gateway.sock"),
      ca_cert: Path.join(directory, "ca.pem"),
      client_cert: Path.join(directory, "client.pem"),
      client_key: Path.join(directory, "client.key"),
      server_name: "gateway.local"
    ]
  end

  def start!(directory) do
    binary = System.fetch_env!("GATEWAY_BINARY") |> Path.expand()
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

    port =
      Port.open({:spawn_executable, binary}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:env,
         [{~c"GATEWAY_CONFIG", String.to_charlist(config_path)}, {~c"GATEWAY_BINARY", false}]}
      ])

    await_socket!(Path.join(directory, "gateway.sock"), 100)
    {:os_pid, pid} = Port.info(port, :os_pid)
    {port, pid}
  end

  def stop({_port, pid}) do
    System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
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

  defp await_socket!(_path, 0), do: raise("gateway did not create its socket")

  defp openssl!(directory, args) do
    case System.cmd("openssl", args, cd: directory, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> raise "test certificate generation failed: #{output}"
    end
  end
end
