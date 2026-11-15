defmodule Zaq.Engine.Extension.ProtocolTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.Extension.Protocol
  alias Zaq.Engine.Extension.Rpc.Gateway.V1.{GatewayEnvelope, GatewayHello}

  property "negotiation never raises the local ceiling or accepts an unimplemented version" do
    check all(
            peer_limit <- integer(1_024..4_294_967_295),
            version <- integer(1..10),
            max_runs: 50
          ) do
      id = Ecto.UUID.generate()

      frame = %GatewayEnvelope{
        request_id: id,
        protocol_version: version,
        payload:
          {:hello,
           %GatewayHello{
             selected_version: version,
             capabilities: ["health.v1"],
             max_envelope_bytes: peer_limit
           }}
      }

      if version == 1 do
        assert {:ok, min(peer_limit, Protocol.max_envelope_bytes())} ==
                 Protocol.negotiate(frame, id)
      else
        assert {:error, :incompatible_protocol} == Protocol.negotiate(frame, id)
      end
    end
  end
end
