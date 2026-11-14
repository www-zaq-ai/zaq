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

  for {callback, arity} <- :gun_event.behaviour_info(:callbacks),
      callback != :tls_handshake_end do
    args = Macro.generate_arguments(arity, __MODULE__)
    @impl true
    defdelegate unquote(callback)(unquote_splicing(args)), to: :gun_default_event_h
  end
end
