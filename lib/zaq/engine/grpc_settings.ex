defmodule Zaq.Engine.GrpcSettings do
  @moduledoc """
  Applies the persisted gRPC message limit before Engine services start.
  Saving the setting does not change a running node or renegotiate its streams.
  Invalid or unavailable storage is diagnosed and uses the bounded startup default.
  """

  require Logger

  alias Zaq.System, as: SystemConfig
  alias Zaq.System.GrpcConfig

  @doc "Loads the node-wide gRPC limit once during Engine startup, before opening streams."
  @spec load() :: :ok
  def load do
    bytes =
      case stored_limit() do
        {:ok, bytes} ->
          bytes

        {:error, _reason} ->
          Logger.warning(
            "Invalid or unavailable gRPC message limit; using the 64 MiB startup default"
          )

          GrpcConfig.default_max_message_bytes()
      end

    Application.put_env(:grpc, :max_message_length, bytes)
  end

  defp stored_limit do
    SystemConfig.get_grpc_max_message_bytes()
  rescue
    _ -> {:error, :configuration_unavailable}
  catch
    :exit, _ -> {:error, :configuration_unavailable}
  end
end
