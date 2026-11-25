defmodule Zaq.Engine.Extension.ActionProtocolTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.Extension.{ActionJson, ActionProtocol, Invocation}
  alias Zaq.Engine.Extension.Rpc.Gateway.V1.GatewayHello

  alias Zaq.Engine.Extension.Rpc.Gateway.V1.{
    ActionRequest,
    ExecuteAction,
    ListActions
  }

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

  test "action requests round-trip explicit modes and reject unspecified or unknown modes" do
    offered = %{ActionProtocol.offer(262_144) | max_timeout_ms: 1_000}

    for mode <- [:SYNC, :ASYNC] do
      request =
        %ActionRequest{
          timeout_ms: 100,
          operation: {:execute, %ExecuteAction{mode: mode, key: "example"}}
        }
        |> ActionRequest.encode()
        |> ActionRequest.decode()

      assert {:ok, _invocation, ^mode} = ActionProtocol.invocation(request, offered)
    end

    request =
      %ActionRequest{
        timeout_ms: 100,
        operation: {:execute, %ExecuteAction{mode: 99, key: "example"}}
      }
      |> ActionRequest.encode()
      |> ActionRequest.decode()

    assert {:execute, %ExecuteAction{mode: 99}} = request.operation
    assert {:error, :INVALID_ARGUMENT} = ActionProtocol.invocation(request, offered)

    unspecified =
      %ActionRequest{
        timeout_ms: 100,
        operation: {:execute, %ExecuteAction{mode: 0, key: "example"}}
      }
      |> ActionRequest.encode()
      |> ActionRequest.decode()

    assert {:execute, %ExecuteAction{mode: :MODE_UNSPECIFIED}} = unspecified.operation
    assert {:error, :INVALID_ARGUMENT} = ActionProtocol.invocation(unspecified, offered)
  end

  property "action request timeout bounds follow the negotiated maximum" do
    offered = %{ActionProtocol.offer(262_144) | max_timeout_ms: 1_000}

    for timeout_ms <- [0, 1_001] do
      request =
        %ActionRequest{
          timeout_ms: timeout_ms,
          operation: {:list, %ListActions{page_size: 2, page_token: "cursor"}}
        }
        |> ActionRequest.encode()
        |> ActionRequest.decode()

      assert {:error, :INVALID_ARGUMENT} = ActionProtocol.invocation(request, offered)
    end

    check all(maximum <- integer(1..60_000), max_runs: 40) do
      limits = %{offered | max_timeout_ms: maximum}

      for timeout_ms <- [1, maximum] do
        request =
          %ActionRequest{
            timeout_ms: timeout_ms,
            operation: {:list, %ListActions{page_size: 2, page_token: "cursor"}}
          }
          |> ActionRequest.encode()
          |> ActionRequest.decode()

        assert {:ok, %Invocation{operation: :list, page_size: 2, page_token: "cursor"}, :SYNC} =
                 ActionProtocol.invocation(request, limits)
      end

      for timeout_ms <- [0, maximum + 1] do
        request =
          %ActionRequest{
            timeout_ms: timeout_ms,
            operation: {:list, %ListActions{page_size: 2, page_token: "cursor"}}
          }
          |> ActionRequest.encode()
          |> ActionRequest.decode()

        assert {:error, :INVALID_ARGUMENT} = ActionProtocol.invocation(request, limits)
      end
    end
  end

  test "absent and future operations decode as unsupported" do
    offered = %{ActionProtocol.offer(262_144) | max_timeout_ms: 1_000}
    request = %ActionRequest{timeout_ms: 100}
    decoded = request |> ActionRequest.encode() |> ActionRequest.decode()
    assert decoded.operation == nil
    assert {:error, :unsupported_operation} = ActionProtocol.invocation(decoded, offered)

    future =
      %{request | __unknown_fields__: [{13, 2, <<>>}]}
      |> ActionRequest.encode()
      |> ActionRequest.decode()

    assert future.operation == nil
    assert future.__unknown_fields__ == [{13, 2, <<>>}]
    assert {:error, :unsupported_operation} = ActionProtocol.invocation(future, offered)
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

  describe "nested JSON values" do
    test "decodes nested arrays and objects recursively" do
      assert {:ok, %{"items" => [%{"id" => 7, "tags" => ["a", nil]}, [%{"id" => 9}, false], []]}} =
               ActionJson.decode_object(
                 ~s({"items":[{"id":7,"tags":["a",null]},[{"id":9},false],[]]}),
                 4
               )
    end

    test "rejects duplicate keys in a nested array object" do
      assert :error =
               ActionJson.decode_object(~s({"items":[{"id":1},[{"id":2,"id":3}]]}), 4)
    end

    property "decoding enforces exact depth for mixed containers" do
      check all({value, depth} <- mixed_json_at_depth(), max_runs: 30) do
        assert {:ok, ^value} = ActionJson.decode_object(Jason.encode!(value), depth)
        assert :error = ActionJson.decode_object(Jason.encode!(value), depth - 1)
      end
    end

    property "encoding enforces exact depth for mixed containers" do
      check all({value, depth} <- mixed_json_at_depth(), max_runs: 30) do
        assert {:ok, encoded} = ActionJson.encode(value, depth)
        assert Jason.decode!(encoded) == value
        assert :error = ActionJson.encode(value, depth - 1)
      end
    end

    test "encoding improper iodata returns an error" do
      assert :error = ActionJson.encode(%{"body" => ["head" | "tail"]}, 32)
    end
  end

  defp mixed_json_at_depth do
    gen all(
          depth <- integer(2..64),
          leaf <-
            one_of([
              integer(-1_000_000..1_000_000),
              boolean(),
              constant(nil),
              string(:printable, max_length: 20),
              constant(~s([]{}"\\))
            ]),
          wrappers <- list_of(member_of([:object, :array]), length: depth - 2)
        ) do
      nested =
        Enum.reduce(wrappers, [leaf], fn
          :object, value -> %{"nested" => value}
          :array, value -> [value]
        end)

      value = %{"root" => nested}
      {value, depth}
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
