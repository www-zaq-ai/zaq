defmodule Zaq.Engine.Extension.ActionWireTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.Extension.Rpc.Gateway.V1.{
    ActionDescription,
    ActionFailure,
    ActionList,
    ActionMetadata,
    ActionReceipt,
    ActionReply,
    ActionRequest,
    DescribeAction,
    ExecuteAction,
    GatewayEnvelope,
    ListActions,
    Relayed,
    ZaqEnvelope
  }

  test "shared independent field-map fixtures match Rust and Elixir in both directions" do
    fixtures =
      "test/support/extension_gateway/action-wire.json" |> File.read!() |> Jason.decode!()

    metadata = %ActionMetadata{key: "general.arithmetic", name: "Arithmetic"}

    operation = %ExecuteAction{
      key: "general.arithmetic",
      arguments_json: ~s({"n":9007199254740993}),
      mode: :SYNC
    }

    requests = %{
      "list" =>
        {:action_request, %ActionRequest{timeout_ms: 5_000, operation: {:list, %ListActions{}}}},
      "describe" =>
        {:action_request,
         %ActionRequest{
           timeout_ms: 5_000,
           operation: {:describe, %DescribeAction{key: metadata.key}}
         }},
      "sync" =>
        {:action_request, %ActionRequest{timeout_ms: 5_000, operation: {:execute, operation}}},
      "async" =>
        {:action_request,
         %ActionRequest{timeout_ms: 5_000, operation: {:execute, %{operation | mode: :ASYNC}}}},
      "receipt" => {:action_receipt, %ActionReceipt{sequence: 1}}
    }

    replies = [
      {"relayed", {:relayed, %Relayed{}}},
      {"listed", {:listed, %ActionList{actions: [metadata]}}},
      {"described",
       {:described,
        %ActionDescription{metadata: metadata, input_schema_json: ~s({"type":"object"})}}},
      {"result", {:result_json, ~s({ "body": "AP+A", "body_encoding": "base64" })}},
      {"failure",
       {:failure,
        %ActionFailure{
          code: :ACTION_FAILED,
          safe_message: "Action failed",
          effects_may_have_occurred: true
        }}}
    ]

    for {name, payload} <- requests do
      expected = %GatewayEnvelope{
        request_id: "00000000-0000-4000-8000-000000000001",
        protocol_version: 1,
        payload: payload
      }

      bytes = Base.decode16!(fixtures[name], case: :lower)
      assert GatewayEnvelope.decode(bytes) == expected
      assert GatewayEnvelope.encode(expected) == bytes
    end

    for {{name, outcome}, sequence} <- Enum.with_index(replies, 1) do
      expected = %ZaqEnvelope{
        request_id: "00000000-0000-4000-8000-000000000001",
        protocol_version: 1,
        payload: {:action_reply, %ActionReply{sequence: sequence, outcome: outcome}}
      }

      bytes = Base.decode16!(fixtures[name], case: :lower)
      assert ZaqEnvelope.decode(bytes) == expected
      assert ZaqEnvelope.encode(expected) == bytes
    end
  end

  property "execution JSON bytes and envelope correlation round-trip without numeric coercion" do
    check all(value <- integer(), max_runs: 30) do
      arguments = Jason.encode!(%{"value" => Integer.to_string(value)})

      frame = %GatewayEnvelope{
        request_id: Ecto.UUID.generate(),
        protocol_version: 1,
        payload:
          {:action_request,
           %ActionRequest{
             timeout_ms: 5_000,
             operation:
               {:execute,
                %ExecuteAction{key: "general.arithmetic", arguments_json: arguments, mode: :SYNC}}
           }}
      }

      assert frame == frame |> GatewayEnvelope.encode() |> GatewayEnvelope.decode()
    end
  end

  test "description carries schemas without adding them to list metadata" do
    metadata = %ActionMetadata{key: "general.arithmetic", name: "Arithmetic"}
    refute Map.has_key?(metadata, :input_schema_json)
    assert is_nil(metadata.version)
    description = %ActionDescription{metadata: metadata, input_schema_json: ~s({"type":"object"})}
    assert is_nil(description.output_schema_json)

    frame = %ZaqEnvelope{
      request_id: Ecto.UUID.generate(),
      protocol_version: 1,
      payload: {:action_reply, %ActionReply{sequence: 1, outcome: {:described, description}}}
    }

    assert frame == frame |> ZaqEnvelope.encode() |> ZaqEnvelope.decode()
  end
end
