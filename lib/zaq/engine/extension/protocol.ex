defmodule Zaq.Engine.Extension.Protocol do
  @moduledoc false

  alias Zaq.Engine.Extension.Rpc.Gateway.V1.{
    GatewayEnvelope,
    GatewayHello,
    HealthRequest,
    ProtocolError,
    ZaqEnvelope,
    ZaqHello
  }

  alias Zaq.Engine.Extension.ActionProtocol
  alias Zaq.System.GrpcConfig

  @version 1
  @capabilities ["health.v1", "actions.v1"]

  @doc "The local encoded-envelope ceiling, also enforced by the gRPC frame limit."
  @spec max_envelope_bytes() :: pos_integer()
  def max_envelope_bytes,
    do: Application.get_env(:grpc, :max_message_length, GrpcConfig.default_max_message_bytes())

  @doc "Offers supported versions and capabilities; no operation is enabled before negotiation."
  @spec hello(String.t()) :: ZaqEnvelope.t()
  def hello(id) do
    envelope(
      id,
      {:hello,
       %ZaqHello{
         supported_versions: [@version],
         capabilities: @capabilities,
         max_envelope_bytes: max_envelope_bytes(),
         action_limits: ActionProtocol.offer(max_envelope_bytes())
       }}
    )
  end

  @doc "Validates the gateway's correlated negotiation response and selects the smaller byte limit."
  @spec negotiate(GatewayEnvelope.t(), String.t()) :: {:ok, pos_integer()} | {:error, atom()}
  def negotiate(
        %GatewayEnvelope{
          request_id: id,
          protocol_version: @version,
          payload: {:hello, %GatewayHello{selected_version: @version} = hello}
        },
        id
      ) do
    if "health.v1" in hello.capabilities and hello.max_envelope_bytes >= 1_024 do
      {:ok, min(hello.max_envelope_bytes, max_envelope_bytes())}
    else
      {:error, :incompatible_protocol}
    end
  end

  def negotiate(_frame, _id), do: {:error, :incompatible_protocol}

  @doc "Builds an in-stream liveness probe. Its identifier must be echoed by the gateway."
  @spec health_request(String.t()) :: ZaqEnvelope.t()
  def health_request(id), do: envelope(id, {:health_request, %HealthRequest{}})

  @doc "Checks decoded envelope metadata without interpreting future operation variants."
  @spec validate(GatewayEnvelope.t()) :: :ok | {:error, atom()}
  def validate(%GatewayEnvelope{request_id: id, protocol_version: @version}) do
    if byte_size(id) in 1..128, do: :ok, else: {:error, :invalid_envelope}
  end

  def validate(_frame), do: {:error, :incompatible_protocol}

  @doc "Rejects a control or operation envelope explicitly, without acknowledging execution."
  @spec reject(String.t(), atom()) :: ZaqEnvelope.t()
  def reject(id, reason) do
    code =
      case reason do
        :unsupported_operation -> :UNSUPPORTED_OPERATION
        :incompatible_protocol -> :INCOMPATIBLE_PROTOCOL
        :resource_exhausted -> :RESOURCE_EXHAUSTED
        _ -> :INVALID_ENVELOPE
      end

    envelope(String.slice(id, 0, 128), {:error, %ProtocolError{code: code}})
  end

  defp envelope(id, payload),
    do: %ZaqEnvelope{request_id: id, protocol_version: @version, payload: payload}
end
