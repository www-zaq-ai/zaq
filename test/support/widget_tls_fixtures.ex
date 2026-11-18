defmodule Zaq.WidgetTLSFixtures do
  @moduledoc false

  def certificates(directory, opts \\ []) do
    key = Path.join(directory, "widget-key.pem")
    cert = Path.join(directory, "widget-cert.pem")
    ca = Path.join(directory, "widget-ca.pem")
    ca_key = Path.join(directory, "widget-ca-key.pem")
    request = Path.join(directory, "widget-request.pem")
    extensions = Path.join(directory, "widget-extensions.cnf")
    subject_alt_name = Keyword.get(opts, :subject_alt_name, "DNS:localhost")
    File.write!(extensions, "subjectAltName=#{subject_alt_name}\nbasicConstraints=CA:FALSE\n")

    commands = [
      [
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-keyout",
        ca_key,
        "-out",
        ca,
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
        key,
        "-out",
        request,
        "-subj",
        "/CN=localhost"
      ],
      [
        "x509",
        "-req",
        "-in",
        request,
        "-CA",
        ca,
        "-CAkey",
        ca_key,
        "-CAcreateserial",
        "-out",
        cert,
        "-days",
        "1",
        "-extfile",
        extensions
      ]
    ]

    Enum.each(commands, fn args ->
      case System.cmd("openssl", args, stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {_output, status} -> raise "Widget TLS test certificate generation failed (#{status})"
      end
    end)

    %{keyfile: key, certfile: cert, cacertfile: ca}
  end
end
