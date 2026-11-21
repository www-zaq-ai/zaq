defmodule Zaq.System.GrpcConfig do
  @moduledoc """
  Units, default and validation for the global gRPC encoded-message limit.
  BO accepts whole MiB; storage and gRPC use bytes. The limit must fit the
  unsigned 32-bit size advertised by the Extension protocol.
  """

  alias Zaq.Utils.ParseUtils

  @mib 1_048_576
  @default_bytes 64 * @mib
  @max_mib div(4_294_967_295, @mib)

  @doc "The 64 MiB startup default, in bytes."
  @spec default_max_message_bytes() :: pos_integer()
  def default_max_message_bytes, do: @default_bytes

  @doc "The largest whole-MiB value that fits the wire size field."
  @spec max_message_mib() :: pos_integer()
  def max_message_mib, do: @max_mib

  @doc "Decodes an existing row's byte value; malformed and null values are invalid."
  @spec from_storage(term()) :: {:ok, pos_integer()} | {:error, :invalid_grpc_max_message_size}
  def from_storage(value) do
    with {:ok, bytes} <- ParseUtils.parse_int_strict(value),
         true <- bytes >= @mib and bytes <= @max_mib * @mib and rem(bytes, @mib) == 0 do
      {:ok, bytes}
    else
      _ -> {:error, :invalid_grpc_max_message_size}
    end
  end

  @doc "Converts a complete positive whole-MiB input to validated bytes."
  @spec from_mib(term()) :: {:ok, pos_integer()} | {:error, :invalid_grpc_max_message_size}
  def from_mib(value) do
    with {:ok, mib} <- ParseUtils.parse_int_strict(value),
         true <- mib in 1..@max_mib do
      {:ok, mib * @mib}
    else
      _ -> {:error, :invalid_grpc_max_message_size}
    end
  end
end
