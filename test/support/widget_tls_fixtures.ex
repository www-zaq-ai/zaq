defmodule Zaq.WidgetTLSFixtures do
  @moduledoc false

  def certificates(directory) do
    key = Path.join(directory, "widget-key.pem")
    cert = Path.join(directory, "widget-cert.pem")
    ca = Path.join(directory, "widget-ca.pem")
    ca_key = Path.join(directory, "widget-ca-key.pem")
    request = Path.join(directory, "widget-request.pem")
    extensions = Path.join(directory, "widget-extensions.cnf")
    File.write!(extensions, "subjectAltName=DNS:localhost\nbasicConstraints=CA:FALSE\n")

    commands = [
      [
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-keyout",
        Path.basename(ca_key),
        "-out",
        Path.basename(ca),
        "-days",
        "1",
        "-subj",
        "/CN=ZAQ Widget Test CA"
      ],
      [
        "req",
        "-new",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-keyout",
        Path.basename(key),
        "-out",
        Path.basename(request),
        "-subj",
        "/CN=localhost"
      ],
      [
        "x509",
        "-req",
        "-in",
        Path.basename(request),
        "-CA",
        Path.basename(ca),
        "-CAkey",
        Path.basename(ca_key),
        "-CAcreateserial",
        "-out",
        Path.basename(cert),
        "-days",
        "1",
        "-extfile",
        Path.basename(extensions)
      ]
    ]

    Enum.each(commands, fn args ->
      # OpenSSL's serial-file writer rejects paths of 256 bytes or more.
      # Keep filenames relative in the child without changing the BEAM's cwd.
      case System.cmd("openssl", args, cd: directory, stderr_to_stdout: true) do
        {_output, 0} ->
          :ok

        {output, status} ->
          raise "Widget TLS test certificate generation failed (#{status}): " <>
                  "openssl #{Enum.join(args, " ")}\n#{output}"
      end
    end)

    %{keyfile: key, certfile: cert, cacertfile: ca}
  end
end
