defmodule Zaq.Engine.Extension.ActionProtocolTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.Extension.{ActionJson, ActionProtocol}
  alias Zaq.Engine.Extension.Rpc.Gateway.V1.GatewayHello

  test "health-only negotiation never enables Actions and selected limits must be explicit and consistent" do
    assert {:ok, nil} =
             ActionProtocol.negotiate(%GatewayHello{capabilities: ["health.v1"]}, 262_144)

    assert {:error, :invalid_envelope} =
             ActionProtocol.negotiate(%GatewayHello{capabilities: ["actions.v1"]}, 262_144)

    offered = ActionProtocol.offer(262_144)

    for changes <- [
          %{max_concurrent: 0},
          %{max_json_depth: 65},
          %{max_unreceipted_replies: 1},
          %{max_unreceipted_bytes: 262_144},
          %{max_reply_envelope_bytes: 511},
          %{receipt_timeout_ms: 999},
          %{max_timeout_ms: 60_001}
        ] do
      hello = %GatewayHello{
        capabilities: ["health.v1", "actions.v1"],
        action_limits: struct!(offered, changes)
      }

      assert {:error, :invalid_envelope} = ActionProtocol.negotiate(hello, 262_144)
    end
  end

  property "UUID validation requires lowercase canonical RFC4122 version four identifiers" do
    check all(_ <- integer(), max_runs: 30) do
      id = Ecto.UUID.generate()
      assert ActionProtocol.valid_id?(id)
      refute ActionProtocol.valid_id?(String.replace(id, "-", ""))
      refute ActionProtocol.valid_id?(String.replace_prefix(id, binary_part(id, 0, 1), "G"))
      refute ActionProtocol.valid_id?(binary_part(id, 0, 14) <> "1" <> binary_part(id, 15, 21))
    end
  end

  property "JSON depth counts only containers and is checked before decode" do
    check all(depth <- integer(1..40), max_runs: 40) do
      json =
        String.duplicate(~s({"nested":), depth) <>
          ~s("[braces]\\\"{}") <> String.duplicate("}", depth)

      assert {:ok, _} = ActionJson.decode_object(json, depth)
      assert :error = ActionJson.decode_object(json, depth - 1)
    end
  end

  test "result encoding refuses opaque values and malformed UTF-8 without stringification" do
    for value <- [
          self(),
          make_ref(),
          {:tuple, 1},
          Date.utc_today(),
          <<255>>,
          %{"a" => 2, a: 1}
        ] do
      assert :error = ActionJson.encode(value, 32)
    end

    assert {:ok, ~s({"body":"AP+A"})} = ActionJson.encode(%{body: "AP+A"}, 1)
    assert {:ok, ~s({"status":"ok"})} = ActionJson.encode(%{status: :ok}, 1)
    assert :error = ActionJson.encode(%{nested: %{}}, 1)
    assert :error = ActionJson.decode_object(~s({"key":1,"key":2}), 32)
    assert :error = ActionJson.decode_object(~s({"nested":{"key":1,"key":2}}), 32)

    assert {:error, :too_large} =
             ActionJson.encode(%{body: String.duplicate("x", 1_000)}, 32, 512)
  end
end
