defmodule Zaq.TestSupport.Http2ResponsePeer do
  @moduledoc "A local HTTP/2 peer that preserves empty DATA frames on the wire."

  import ExUnit.Assertions
  import ExUnit.Callbacks

  @preface "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

  def start!(chunks, owner) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    start_supervised!(
      {Task,
       fn ->
         {:ok, socket} = :gen_tcp.accept(listener, 5_000)
         assert {:ok, @preface} = :gen_tcp.recv(socket, byte_size(@preface), 5_000)
         :ok = :gen_tcp.send(socket, frame(4, 0, 0, ""))
         stream_id = receive_request(socket)
         send(owner, {:http2_request, stream_id})

         # HPACK static-table entry 8 is the complete :status = 200 header.
         :ok = :gen_tcp.send(socket, frame(1, 4, stream_id, <<0x88>>))

         for chunk <- chunks do
           :ok = :gen_tcp.send(socket, frame(0, 0, stream_id, chunk))
         end

         :ok = :gen_tcp.send(socket, frame(0, 1, stream_id, ""))
         send(owner, {:http2_response_sent, self()})

         receive do
           :close -> :gen_tcp.close(socket)
         end
       end},
      id: make_ref()
    )

    "http://127.0.0.1:#{port}/signed"
  end

  defp receive_request(socket) do
    assert {:ok, <<length::24, type::8, flags::8, _reserved::1, stream_id::31>>} =
             :gen_tcp.recv(socket, 9, 5_000)

    if length > 0, do: assert(match?({:ok, _}, :gen_tcp.recv(socket, length, 5_000)))

    case {type, flags, stream_id} do
      {4, 0, 0} ->
        :ok = :gen_tcp.send(socket, frame(4, 1, 0, ""))
        receive_request(socket)

      {1, _, id} when id > 0 ->
        id

      _ ->
        receive_request(socket)
    end
  end

  defp frame(type, flags, stream_id, payload) do
    <<byte_size(payload)::24, type::8, flags::8, 0::1, stream_id::31, payload::binary>>
  end
end
