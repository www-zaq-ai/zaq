defmodule Zaq.ExtensionGateway.Certificates do
  @moduledoc false

  def generate!(directory) do
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

  defp openssl!(directory, args) do
    case System.cmd("openssl", args, cd: directory, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> raise "test certificate generation failed: #{output}"
    end
  end
end
