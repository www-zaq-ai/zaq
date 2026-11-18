defmodule Zaq.TestSupport.Http2ResponsePeer do
  @moduledoc "A local HTTP/2 peer for entity bytes, empty DATA frames and response trailers."

  import ExUnit.Assertions
  import ExUnit.Callbacks

  @preface "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

  def start!(chunks, owner, options \\ []) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    start_supervised!(
      {Task,
       fn ->
         {:ok, socket} = :gen_tcp.accept(listener, 5_000)
         assert {:ok, @preface} = :gen_tcp.recv(socket, byte_size(@preface), 5_000)
         :ok = :gen_tcp.send(socket, frame(4, 0, 0, ""))
         stream_id = receive_request(socket, owner, Keyword.get(options, :capture_headers, false))
         send(owner, {:http2_request, stream_id})

         headers = [{":status", "200"} | Keyword.get(options, :headers, [])]
         :ok = :gen_tcp.send(socket, frame(1, 4, stream_id, encode_headers(headers)))

         for chunk <- chunks do
           :ok = :gen_tcp.send(socket, frame(0, 0, stream_id, chunk))
         end

         end_stream? = Keyword.get(options, :end_stream, true)

         case Keyword.get(options, :trailers, []) do
           [] ->
             flags = if end_stream?, do: 1, else: 0
             :ok = :gen_tcp.send(socket, frame(0, flags, stream_id, ""))

           trailers ->
             flags = if end_stream?, do: 5, else: 4
             :ok = :gen_tcp.send(socket, frame(1, flags, stream_id, encode_headers(trailers)))
         end

         send(owner, {:http2_response_sent, self()})

         if end_stream? do
           receive do
             :close -> :gen_tcp.close(socket)
           end
         else
           :gen_tcp.close(socket)
         end
       end},
      id: make_ref()
    )

    "http://127.0.0.1:#{port}/signed"
  end

  defp receive_request(socket, owner, capture_headers?) do
    assert {:ok, <<length::24, type::8, flags::8, _reserved::1, stream_id::31>>} =
             :gen_tcp.recv(socket, 9, 5_000)

    payload =
      if length > 0 do
        assert {:ok, payload} = :gen_tcp.recv(socket, length, 5_000)
        payload
      else
        ""
      end

    case {type, flags, stream_id} do
      {4, 0, 0} ->
        :ok = :gen_tcp.send(socket, frame(4, 1, 0, ""))
        receive_request(socket, owner, capture_headers?)

      {1, _, id} when id > 0 ->
        if capture_headers? do
          assert {:ok, headers, _table} = HPAX.decode(payload, HPAX.new(4_096))
          send(owner, {:http2_request_headers, headers})
        end

        id

      _ ->
        receive_request(socket, owner, capture_headers?)
    end
  end

  defp frame(type, flags, stream_id, payload) do
    <<byte_size(payload)::24, type::8, flags::8, 0::1, stream_id::31, payload::binary>>
  end

  defp encode_headers(headers) do
    {encoded, _table} = HPAX.encode(:no_store, headers, HPAX.new(4_096))
    IO.iodata_to_binary(encoded)
  end
end
