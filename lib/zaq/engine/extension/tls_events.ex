defmodule Zaq.Engine.Extension.TLSEvents do
  @moduledoc false
  @behaviour :gun_event

  # Gun permits prior-knowledge HTTP/2 without ALPN. This gateway contract does not.
  @impl true
  def tls_handshake_end(%{socket: socket, protocol: :http2}, state) do
    case :ssl.negotiated_protocol(socket) do
      {:ok, "h2"} ->
        state

      _ ->
        :ssl.close(socket)
        exit(:alpn_required)
    end
  end

  def tls_handshake_end(_event, state), do: state

  # A TLS 1.3 server can reject the client certificate after Gun reports the connection up.
  @impl true
  def disconnect(%{reason: {:tls_alert, _}}, alert_seen) do
    :atomics.put(alert_seen, 1, 1)
    alert_seen
  end

  def disconnect(_event, alert_seen), do: alert_seen

  for {callback, arity} <- :gun_event.behaviour_info(:callbacks),
      callback not in [:tls_handshake_end, :disconnect] do
    args = Macro.generate_arguments(arity, __MODULE__)
    @impl true
    defdelegate unquote(callback)(unquote_splicing(args)), to: :gun_default_event_h
  end
end
