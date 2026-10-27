defmodule Zaq.Channels.ConnectorRuntimeTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.Api
  alias Zaq.Channels.ConnectorRuntime
  alias Zaq.Engine.Api, as: EngineApi
  alias Zaq.Event

  defmodule Runtime do
    def before_disable(config, _actor, _opts) do
      send(self(), {:prepare, config.id})

      case Process.get(:prepare_result, :ok) do
        :raise -> raise "provider unavailable"
        :exit -> exit(:provider_unavailable)
        other -> other
      end
    end

    def sync_config_runtime(_before, %{enabled: false} = after_config),
      do: stop_runtime(after_config)

    def sync_config_runtime(before, after_config) do
      send(self(), {:runtime_start, before, after_config})
      Process.get(:runtime_result, :ok)
    end

    def stop_runtime(config) do
      send(self(), {:runtime_stop, config})
      Process.get(:runtime_result, :ok)
    end
  end

  test "enable acceptance defers runtime until eligibility is persisted" do
    before = %{id: 3, provider: "example", kind: "retrieval", enabled: false}
    after_config = %{before | enabled: true}
    request = %{before_config: before, after_config: after_config, phase: :before_persist}
    opts = [runtime_module: Runtime, communication_runtime_module: Runtime]

    assert {:ok,
            %{
              transition: :confirmed,
              runtime: {:pending, :configuration_required},
              continuation: :after_persist
            }} =
             ConnectorRuntime.sync_runtime(request, %{}, opts)

    refute_received {:runtime_start, _, _}

    assert {:ok, %{transition: :confirmed, runtime: :complete, continuation: :none}} =
             ConnectorRuntime.sync_runtime(%{request | phase: :after_persist}, %{}, opts)

    assert_received {:runtime_start, ^before, ^after_config}
  end

  test "only Channels interprets preparation and shutdown outcomes" do
    before = %{id: 4, provider: "example", kind: "retrieval", enabled: true}

    request = %{
      before_config: before,
      after_config: %{before | enabled: false},
      phase: :before_persist
    }

    opts = [runtime_module: Runtime, communication_runtime_module: Runtime]

    for {failure, reason} <- [
          {{:error, :logout_failed}, :failed},
          {:raise, :unavailable},
          {:exit, :unavailable}
        ] do
      Process.put(:prepare_result, failure)
      assert {:error, ^reason} = ConnectorRuntime.sync_runtime(request, %{}, opts)
      refute_received {:runtime_stop, _}
    end

    Process.put(:prepare_result, :ok)
    Process.put(:runtime_result, {:error, :offline})

    assert {:ok,
            %{transition: :confirmed, runtime: {:pending, :unavailable}, continuation: :none}} =
             ConnectorRuntime.sync_runtime(request, %{}, opts)

    assert_received {:runtime_stop, %{id: 4}}
  end

  test "invalid requests never prepare or confirm a transition" do
    config = %{id: 5, provider: "example", kind: "retrieval", enabled: true}

    request = %{
      before_config: config,
      after_config: %{config | enabled: false},
      phase: :before_persist
    }

    opts = [runtime_module: Runtime, communication_runtime_module: Runtime]

    for invalid <- [
          %{request | phase: :invalid},
          Map.put(request, :intent, :invalid),
          %{request | before_config: %{config | enabled: nil}}
        ] do
      assert {:error, :invalid_request} =
               ConnectorRuntime.sync_runtime(invalid, %{}, opts)
    end

    refute_received {:prepare, _}
  end

  test "saved-binding runtime context requires both confidentiality and capability" do
    request = %{channel_config_id: 987_654, provider: "whatsapp", kind: "retrieval"}

    for opts <- [[], [confidential: true], [connector_runtime: true]] do
      event = Event.new(request, :engine, opts: opts)

      assert %{response: {:error, :unauthorized}} =
               EngineApi.handle_event(event, :connector_runtime_context, nil)
    end
  end

  test "provider infrastructure and legacy unbound configurations pass through unchanged" do
    for target <- [
          {:provider, :whatsapp},
          %{id: 1, provider: "telegram", kind: "retrieval", settings: %{}}
        ] do
      assert {:ok, ^target} = ConnectorRuntime.current_config(target)
    end
  end

  test "archive runtime leaf consumes supplied configuration without Repo or current BO lookup" do
    config = %{
      id: 987_654,
      provider: "email:imap",
      kind: "retrieval",
      enabled: true,
      token: "resolved"
    }

    request = %{
      before_config: config,
      after_config: %{config | enabled: false},
      phase: :before_persist
    }

    event =
      Event.new(request, :channels,
        opts: [
          action: :connector_sync_runtime,
          confidential: true,
          communication_runtime_module: Runtime
        ]
      )

    assert %{response: {:ok, %{transition: :confirmed, runtime: :complete}}} =
             Api.handle_event(event, :connector_sync_runtime, nil)

    assert_received {:runtime_stop, %{enabled: false, token: "resolved", id: 987_654}}

    event = %{event | opts: Keyword.delete(event.opts, :confidential)}

    assert %{response: {:error, :confidential_event_required}} =
             Api.handle_event(event, :connector_sync_runtime, nil)
  end

  test "mismatched connector scope never executes stop" do
    config = %{id: 987_654, provider: "email:imap", kind: "retrieval", enabled: false}

    for after_config <- [
          %{config | id: 987_655},
          %{config | provider: "email:smtp"},
          %{config | kind: "data_source"}
        ] do
      event =
        Event.new(
          %{before_config: config, after_config: after_config, phase: :before_persist},
          :channels,
          opts: [
            action: :connector_sync_runtime,
            confidential: true,
            communication_runtime_module: Runtime
          ]
        )

      assert %{response: {:error, :invalid_request}} =
               Api.handle_event(event, :connector_sync_runtime, nil)

      refute_received {:runtime_stop, _}
    end
  end
end
