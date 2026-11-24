defmodule Zaq.Engine.Extension.ActionStreamTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Extension

  alias Zaq.Engine.Extension.Rpc.Gateway.V1.{
    ActionLimits,
    ActionReceipt,
    ActionRequest,
    DescribeAction,
    ExecuteAction,
    GatewayEnvelope,
    GatewayHello,
    ListActions
  }

  alias Zaq.ExtensionGateway

  setup context do
    directory = Path.join(System.tmp_dir!(), "za-#{System.unique_integer([:positive])}")
    settings = ExtensionGateway.certificates!(directory)

    limits = %ActionLimits{
      max_concurrent: 2,
      max_unreceipted_replies: 8,
      max_unreceipted_bytes: 1_048_576,
      max_timeout_ms: 1_000,
      max_json_depth: 16,
      max_reply_envelope_bytes: 262_144,
      receipt_timeout_ms: 1_000
    }

    limits = struct!(limits, Map.get(context, :limits, %{}))

    gateway =
      ExtensionGateway.start!(directory,
        hello:
          {:hello,
           %GatewayHello{
             selected_version: 1,
             capabilities: ["health.v1", "actions.v1"],
             max_envelope_bytes: 262_144,
             action_limits: limits
           }}
      )

    action_supervisor = start_supervised!({Task.Supervisor, []})

    runtime =
      start_supervised!(
        {Extension,
         name: nil,
         settings: settings,
         reconnect_interval_ms: 1_000,
         action_supervisor: action_supervisor}
      )

    on_exit(fn ->
      ExtensionGateway.stop(gateway)
      File.rm_rf!(directory)
    end)

    assert_receive {:gateway_request, ^gateway, _, _}, 2_000
    %{gateway: gateway, runtime: runtime}
  end

  test "encrypted stream lists metadata, describes schemas and executes through Registry/Jido", %{
    gateway: gateway
  } do
    list_id = request(gateway, {:list, %ListActions{page_size: 2}})

    assert_receive {:gateway_action_reply, ^gateway, ^list_id,
                    %{sequence: 1, outcome: {:listed, page}}},
                   2_000

    assert length(page.actions) == 2
    refute Map.has_key?(hd(page.actions), :input_schema_json)
    receipt(gateway, list_id, 1)

    describe_id = request(gateway, {:describe, %DescribeAction{key: "arithmetic.add"}})

    assert_receive {:gateway_action_reply, ^gateway, ^describe_id,
                    %{sequence: 2, outcome: {:described, description}}},
                   2_000

    assert Jason.decode!(description.input_schema_json)["properties"]["amount"]
    receipt(gateway, describe_id, 2)

    execute_id =
      request(
        gateway,
        {:execute,
         %ExecuteAction{
           key: "arithmetic.add",
           arguments_json: ~s({"value":2.0,"amount":3.0}),
           mode: :SYNC
         }}
      )

    assert_receive {:gateway_action_reply, ^gateway, ^execute_id,
                    %{sequence: 3, outcome: {:result_json, json}}},
                   2_000

    assert Jason.decode!(json) == %{"result" => 5.0}
    receipt(gateway, execute_id, 3)
  end

  test "ASYNC relays before its terminal result and receipts each message", %{gateway: gateway} do
    id =
      request(
        gateway,
        {:execute,
         %ExecuteAction{
           key: "arithmetic.add",
           arguments_json: ~s({"value":1.0,"amount":2.0}),
           mode: :ASYNC
         }}
      )

    assert_receive {:gateway_action_reply, ^gateway, ^id, %{sequence: 1, outcome: {:relayed, _}}},
                   2_000

    receipt(gateway, id, 1)

    assert_receive {:gateway_action_reply, ^gateway, ^id,
                    %{sequence: 2, outcome: {:result_json, json}}},
                   2_000

    assert Jason.decode!(json) == %{"result" => 3.0}
    receipt(gateway, id, 2)
  end

  test "duplicate active IDs reject the stream rather than settling the original invocation twice",
       %{gateway: gateway} do
    id = request(gateway, {:list, %ListActions{}})
    assert_receive {:gateway_action_reply, ^gateway, ^id, %{sequence: 1}}, 2_000
    request(gateway, {:list, %ListActions{}}, id: id)
    assert_receive {:gateway_rejection, ^gateway, %{code: :INVALID_ENVELOPE}}, 2_000
    refute_receive {:gateway_action_reply, ^gateway, ^id, %{sequence: 2}}
  end

  @tag limits: %{max_unreceipted_replies: 2, max_unreceipted_bytes: 262_656}
  test "an unreceipting peer exhausts bounded credits instead of creating an unlimited send queue",
       %{gateway: gateway} do
    for sequence <- 1..2 do
      id = request(gateway, {:list, %ListActions{page_size: 1}})
      assert_receive {:gateway_action_reply, ^gateway, ^id, %{sequence: ^sequence}}, 2_000
    end

    request(gateway, {:list, %ListActions{page_size: 1}})
    assert_receive {:gateway_rejection, ^gateway, %{code: :RESOURCE_EXHAUSTED}}, 2_000
  end

  @tag limits: %{max_reply_envelope_bytes: 512}
  test "an oversized result is replaced by a bounded failure using its terminal reservation", %{
    gateway: gateway
  } do
    id = request(gateway, {:describe, %DescribeAction{key: "general.http_request"}})

    assert_receive {:gateway_action_reply, ^gateway, ^id,
                    %{sequence: 1, outcome: {:failure, failure}}},
                   2_000

    assert failure.code == :RESULT_TOO_LARGE
    receipt(gateway, id, 1)
    next_id = request(gateway, {:list, %ListActions{page_size: 1}})

    assert_receive {:gateway_action_reply, ^gateway, ^next_id,
                    %{sequence: 2, outcome: {:listed, _}}},
                   2_000

    receipt(gateway, next_id, 2)
  end

  test "a mismatched receipt is a protocol violation rather than a credit release", %{
    gateway: gateway
  } do
    id = request(gateway, {:list, %ListActions{page_size: 1}})
    assert_receive {:gateway_action_reply, ^gateway, ^id, %{sequence: 1}}, 2_000
    receipt(gateway, Ecto.UUID.generate(), 1)
    assert_receive {:gateway_rejection, ^gateway, %{code: :INVALID_ENVELOPE}}, 2_000
  end

  test "receipt expiry closes the stream and reconnects with fresh sequence and credit state", %{
    gateway: gateway
  } do
    id = request(gateway, {:list, %ListActions{page_size: 1}})
    assert_receive {:gateway_action_reply, ^gateway, ^id, %{sequence: 1}}, 2_000
    assert_receive {:gateway_connected, ^gateway, first_connection}, 1_000
    assert_receive {:gateway_connected, ^gateway, next_connection}, 4_000
    assert first_connection != next_connection
    assert_receive {:gateway_request, ^gateway, ^next_connection, _}, 2_000
    next_id = request(gateway, {:list, %ListActions{page_size: 1}})
    assert_receive {:gateway_action_reply, ^gateway, ^next_id, %{sequence: 1}}, 2_000
    receipt(gateway, next_id, 1)
  end

  defp request(gateway, operation, opts \\ []) do
    id = Keyword.get(opts, :id, Ecto.UUID.generate())

    ExtensionGateway.push(gateway, %GatewayEnvelope{
      request_id: id,
      protocol_version: 1,
      payload:
        {:action_request,
         %ActionRequest{timeout_ms: Keyword.get(opts, :timeout_ms, 1_000), operation: operation}}
    })

    id
  end

  defp receipt(gateway, id, sequence) do
    ExtensionGateway.push(gateway, %GatewayEnvelope{
      request_id: id,
      protocol_version: 1,
      payload: {:action_receipt, %ActionReceipt{sequence: sequence}}
    })
  end
end
