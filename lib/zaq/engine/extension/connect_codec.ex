defmodule Zaq.Engine.Extension.ConnectCodec do
  @moduledoc "Preserves framed Connect replies for the reader's byte limit check before decoding."

  @behaviour GRPC.Codec

  @impl true
  defdelegate name(), to: GRPC.Codec.Proto

  @impl true
  defdelegate encode(message, opts \\ []), to: GRPC.Codec.Proto

  @impl true
  def decode(bytes, _module), do: bytes
end
