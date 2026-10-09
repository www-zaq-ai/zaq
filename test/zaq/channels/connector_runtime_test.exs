defmodule Zaq.Channels.ConnectorRuntimeTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.Api
  alias Zaq.Event

  defmodule Runtime do
    def stop_runtime(config) do
      send(self(), {:runtime_stop, config})
      :ok
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

    request = %{before_config: config, after_config: %{config | enabled: false}}

    event =
      Event.new(request, :channels,
        opts: [
          action: :connector_sync_runtime,
          confidential: true,
          communication_runtime_module: Runtime
        ]
      )

    assert %{response: :ok} = Api.handle_event(event, :connector_sync_runtime, nil)
    assert_received {:runtime_stop, %{enabled: false, token: "resolved", id: 987_654}}

    event = %{event | opts: Keyword.delete(event.opts, :confidential)}

    assert %{response: {:error, :confidential_event_required}} =
             Api.handle_event(event, :connector_sync_runtime, nil)
  end

  test "mismatched connector scope and enabled after-state never execute stop" do
    config = %{id: 987_654, provider: "email:imap", kind: "retrieval", enabled: false}

    for after_config <- [
          %{config | id: 987_655},
          %{config | provider: "email:smtp"},
          %{config | kind: "data_source"},
          %{config | enabled: true}
        ] do
      event =
        Event.new(%{before_config: config, after_config: after_config}, :channels,
          opts: [
            action: :connector_sync_runtime,
            confidential: true,
            communication_runtime_module: Runtime
          ]
        )

      assert %{response: {:error, :connector_mismatch}} =
               Api.handle_event(event, :connector_sync_runtime, nil)

      refute_received {:runtime_stop, _}
    end
  end
end
