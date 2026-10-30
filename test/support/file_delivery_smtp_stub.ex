defmodule Zaq.TestSupport.FileDeliverySmtpStub do
  @moduledoc """
  Private loopback SMTP boundary for Channels contract tests.

  Captures the real SMTP envelope and encoded MIME before withholding the DATA
  response until all concurrent journeys have arrived. It does not model a real
  recipient inbox, authentication, TLS or a production SMTP server.
  """

  import ExUnit.Assertions

  def start!(owner, namespace, opts \\ []) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :line,
        ip: {127, 0, 0, 1},
        reuseaddr: true
      ])

    {:ok, port} = :inet.port(listener)
    ExUnit.Callbacks.on_exit(fn -> :gen_tcp.close(listener) end)

    ExUnit.Callbacks.start_supervised!(%{
      id: {:smtp_delivery, namespace},
      restart: :temporary,
      start:
        {Task, :start_link,
         [
           fn ->
             Enum.each(1..Keyword.get(opts, :connections, 1), fn _ ->
               accept!(listener, owner, namespace)
             end)
           end
         ]}
    })

    port
  end

  defp accept!(listener, owner, namespace) do
    {:ok, socket} = :gen_tcp.accept(listener, 15_000)

    try do
      :ok = :gen_tcp.send(socket, "220 stub.example.test ESMTP\r\n")
      commands!(socket, owner, namespace, %{sender: nil, recipients: []})
    after
      :gen_tcp.close(socket)
    end
  end

  defp commands!(socket, owner, namespace, envelope) do
    case :gen_tcp.recv(socket, 0, 15_000) do
      {:ok, "EHLO " <> _} ->
        :ok = :gen_tcp.send(socket, "250 stub.example.test\r\n")
        commands!(socket, owner, namespace, envelope)

      {:ok, "MAIL FROM:" <> address} ->
        :ok = :gen_tcp.send(socket, "250 OK\r\n")
        commands!(socket, owner, namespace, %{envelope | sender: address(address)})

      {:ok, "RCPT TO:" <> address} ->
        :ok = :gen_tcp.send(socket, "250 OK\r\n")

        commands!(socket, owner, namespace, %{
          envelope
          | recipients: envelope.recipients ++ [address(address)]
        })

      {:ok, "DATA\r\n"} ->
        :ok = :gen_tcp.send(socket, "354 End data with <CRLF>.<CRLF>\r\n")
        raw = data!(socket, [])
        send(owner, {:delivery_boundary, namespace, self(), Map.put(envelope, :raw, raw)})

        receive do
          :accept_delivery -> :ok = :gen_tcp.send(socket, "250 Accepted #{namespace}\r\n")
        after
          15_000 -> flunk("SMTP boundary was not released")
        end

        commands!(socket, owner, namespace, envelope)

      {:ok, "QUIT\r\n"} ->
        :gen_tcp.send(socket, "221 Bye\r\n")

      {:error, :closed} ->
        :ok

      other ->
        flunk("unexpected SMTP command: #{inspect(other)}")
    end
  end

  defp data!(socket, lines) do
    case :gen_tcp.recv(socket, 0, 15_000) do
      {:ok, ".\r\n"} -> lines |> Enum.reverse() |> IO.iodata_to_binary()
      {:ok, "." <> line} -> data!(socket, [line | lines])
      {:ok, line} -> data!(socket, [line | lines])
      other -> flunk("incomplete SMTP DATA: #{inspect(other)}")
    end
  end

  defp address(value) do
    [_, address] = Regex.run(~r/^\s*<([^>]+)>/, value)
    address
  end
end
