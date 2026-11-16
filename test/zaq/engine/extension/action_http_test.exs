defmodule Zaq.Engine.Extension.ActionHttpTest do
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Extension

  alias Zaq.Engine.Extension.Rpc.Gateway.V1.{
    ActionLimits,
    ActionReceipt,
    ActionRequest,
    ExecuteAction,
    GatewayEnvelope,
    GatewayHello
  }

  alias Zaq.ExtensionGateway
  alias Zaq.System, as: SystemConfig

  defmodule ControlledHttp do
    @moduledoc false
    def init(parent), do: parent

    def call(conn, parent) do
      send(parent, {:http_waiting, self()})

      receive do
        :release ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, ~s({"private":"response-marker"}))
      after
        10_000 -> Plug.Conn.resp(conn, 504, "timeout")
      end
    end
  end

  setup context do
    {:ok, _} = SystemConfig.set_config("outbound_http.enabled", true)
    {:ok, _} = SystemConfig.set_config("outbound_http.block_loopback", false)
    parent = self()
    server = start_supervised!({Bandit, plug: {ControlledHttp, parent}, port: 0})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    directory = Path.join(System.tmp_dir!(), "zah-#{System.unique_integer([:positive])}")
    settings = ExtensionGateway.certificates!(directory)

    limits = %ActionLimits{
      max_concurrent: Map.get(context, :max_concurrent, 2),
      max_unreceipted_replies: 8,
      max_unreceipted_bytes: 1_048_576,
      max_timeout_ms: 5_000,
      max_json_depth: 32,
      max_reply_envelope_bytes: 262_144,
      receipt_timeout_ms: 5_000
    }

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

    runtime =
      start_supervised!({Extension, name: nil, settings: settings, reconnect_interval_ms: 20})

    on_exit(fn ->
      ExtensionGateway.stop(gateway)
      File.rm_rf!(directory)
    end)

    assert_receive {:gateway_request, ^gateway, _, _}, 2_000
    Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")
    %{gateway: gateway, runtime: runtime, url: "http://127.0.0.1:#{port}/private"}
  end

  test "a real Channels HTTP Action can wait while another invocation finishes without leaking either hop",
       context do
    %{gateway: gateway, url: url} = context

    http_id =
      invoke(
        gateway,
        "general.http_request",
        %{method: "GET", url: url, headers: %{"x-private" => "request-marker"}},
        :ASYNC
      )

    assert_receive {:gateway_action_reply, ^gateway, ^http_id,
                    %{sequence: 1, outcome: {:relayed, _}}},
                   2_000

    receipt(gateway, http_id, 1)
    assert_receive {:http_waiting, http}, 2_000
    math_id = invoke(gateway, "arithmetic.add", %{value: 2.0, amount: 3.0}, :SYNC)

    assert_receive {:gateway_action_reply, ^gateway, ^math_id,
                    %{sequence: 2, outcome: {:result_json, json}}},
                   2_000

    assert Jason.decode!(json) == %{"result" => 5.0}
    receipt(gateway, math_id, 2)
    send(http, :release)

    assert_receive {:gateway_action_reply, ^gateway, ^http_id,
                    %{sequence: 3, outcome: {:result_json, json}}},
                   2_000

    assert Jason.decode!(json)["body"] == %{"private" => "response-marker"}
    receipt(gateway, http_id, 3)
    refute_receive {:node_router_event, %Zaq.Event{request: %{request: %Zaq.HttpRequest{}}}}
    refute_receive {:node_router_event, %Zaq.Event{request: %Zaq.HttpRequest{}}}
  end

  @tag max_concurrent: 1
  test "deadline expiry sends one outcome but retains execution capacity until the real HTTP worker exits",
       context do
    %{gateway: gateway, runtime: runtime, url: url} = context
    id = invoke(gateway, "general.http_request", %{method: "GET", url: url}, :ASYNC, 500)

    assert_receive {:gateway_action_reply, ^gateway, ^id, %{sequence: 1, outcome: {:relayed, _}}},
                   2_000

    receipt(gateway, id, 1)
    assert_receive {:http_waiting, http}, 2_000

    worker =
      runtime
      |> :sys.get_state()
      |> Map.fetch!(:actions)
      |> Map.fetch!(:workers)
      |> Map.values()
      |> hd()

    monitor = Process.monitor(worker.pid)

    assert_receive {:gateway_action_reply, ^gateway, ^id,
                    %{sequence: 2, outcome: {:failure, failure}}},
                   2_000

    assert failure.code == :DEADLINE_EXCEEDED
    assert failure.effects_may_have_occurred
    receipt(gateway, id, 2)

    busy_id = invoke(gateway, "arithmetic.add", %{value: 2.0, amount: 3.0}, :SYNC)

    assert_receive {:gateway_action_reply, ^gateway, ^busy_id,
                    %{sequence: 3, outcome: {:failure, %{code: :RESOURCE_EXHAUSTED}}}},
                   2_000

    receipt(gateway, busy_id, 3)
    send(http, :release)
    assert_receive {:DOWN, ^monitor, :process, _, _}, 2_000
    refute_receive {:gateway_action_reply, ^gateway, ^id, _}
    next_id = invoke(gateway, "arithmetic.add", %{value: 2.0, amount: 3.0}, :SYNC)

    assert_receive {:gateway_action_reply, ^gateway, ^next_id,
                    %{sequence: 4, outcome: {:result_json, _}}},
                   2_000

    receipt(gateway, next_id, 4)
  end

  @tag max_concurrent: 1
  test "a reconnect fences an old HTTP completion and does not release its running-worker slot",
       context do
    %{gateway: gateway, runtime: runtime, url: url} = context
    id = invoke(gateway, "general.http_request", %{method: "GET", url: url}, :ASYNC)

    assert_receive {:gateway_action_reply, ^gateway, ^id, %{sequence: 1, outcome: {:relayed, _}}},
                   2_000

    receipt(gateway, id, 1)
    assert_receive {:http_waiting, http}, 2_000

    worker =
      runtime
      |> :sys.get_state()
      |> Map.fetch!(:actions)
      |> Map.fetch!(:workers)
      |> Map.values()
      |> hd()

    monitor = Process.monitor(worker.pid)
    assert_receive {:gateway_connected, ^gateway, first_connection}, 1_000
    receipt(gateway, id, 0)
    assert_receive {:gateway_rejection, ^gateway, %{code: :INVALID_ENVELOPE}}, 2_000
    assert_receive {:gateway_connected, ^gateway, next_connection}, 2_000
    assert first_connection != next_connection
    assert_receive {:gateway_request, ^gateway, ^next_connection, _}, 2_000
    busy_id = invoke(gateway, "arithmetic.add", %{value: 2.0, amount: 3.0}, :SYNC)

    assert_receive {:gateway_action_reply, ^gateway, ^busy_id,
                    %{sequence: 1, outcome: {:failure, %{code: :RESOURCE_EXHAUSTED}}}},
                   2_000

    receipt(gateway, busy_id, 1)
    send(http, :release)
    assert_receive {:DOWN, ^monitor, :process, _, _}, 2_000
    refute_receive {:gateway_action_reply, ^gateway, ^id, _}
    next_id = invoke(gateway, "arithmetic.add", %{value: 2.0, amount: 3.0}, :SYNC)

    assert_receive {:gateway_action_reply, ^gateway, ^next_id,
                    %{sequence: 2, outcome: {:result_json, _}}},
                   2_000

    receipt(gateway, next_id, 2)
  end

  defp invoke(gateway, key, params, mode, timeout_ms \\ 5_000) do
    id = Ecto.UUID.generate()

    ExtensionGateway.push(gateway, %GatewayEnvelope{
      request_id: id,
      protocol_version: 1,
      payload:
        {:action_request,
         %ActionRequest{
           timeout_ms: timeout_ms,
           operation:
             {:execute,
              %ExecuteAction{key: key, arguments_json: Jason.encode!(params), mode: mode}}
         }}
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
