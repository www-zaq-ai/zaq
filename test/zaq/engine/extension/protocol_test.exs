defmodule Zaq.Engine.Extension.ProtocolTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.Extension.Protocol

  alias Zaq.Engine.Extension.Rpc.Gateway.V1.{
    GatewayEnvelope,
    GatewayHello,
    HealthResponse,
    ProtocolError,
    ZaqEnvelope
  }

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

  property "ready-state validation accepts only version one envelopes" do
    id = Ecto.UUID.generate()

    valid = %GatewayEnvelope{
      request_id: id,
      protocol_version: 1,
      payload: {:health_response, %HealthResponse{status: "ok"}}
    }

    assert :ok = Protocol.validate(valid)

    check all(version <- integer(2..4_294_967_295), max_runs: 50) do
      assert {:error, :incompatible_protocol} =
               Protocol.validate(%{valid | protocol_version: version})
    end

    assert {:error, :incompatible_protocol} = Protocol.validate(%{valid | protocol_version: 0})
  end

  test "a concrete unsupported version is rejected using a version-one envelope" do
    id = Ecto.UUID.generate()

    assert {:error, :incompatible_protocol} =
             Protocol.validate(%GatewayEnvelope{
               request_id: id,
               protocol_version: 2
             })

    assert %{
             request_id: ^id,
             protocol_version: 1,
             payload: {:error, %ProtocolError{code: :INCOMPATIBLE_PROTOCOL}}
           } = Protocol.reject(id, :incompatible_protocol)
  end

  property "rejections echo IDs only when bounded in UTF-8 bytes" do
    check all(
            unit <- member_of(["x", "é", "🐘", "x\u0301"]),
            count <- integer(1..256),
            max_runs: 50
          ) do
      id = String.duplicate(unit, count)
      expected_id = if byte_size(id) <= 128, do: id, else: ""
      frame = Protocol.reject(id, :invalid_envelope)

      assert frame.request_id == expected_id
      assert byte_size(ZaqEnvelope.encode(frame)) <= 1_024
    end
  end

  test "a single large grapheme cannot make its rejection exceed the negotiated floor" do
    id = "x" <> String.duplicate("\u0301", 512)
    frame = Protocol.reject(id, :invalid_envelope)
    assert frame.request_id == ""
    assert byte_size(ZaqEnvelope.encode(frame)) <= 1_024
  end
end
