defmodule Zaq.Channels.FileValidationTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Agent.Tools.DataSource.AttachDocuments
  alias Zaq.Channels.{Api, Bridge, JidoChatBridge}
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Engine.Messages.Incoming.RoutingContext
  alias Zaq.Event

  defmodule Adapter do
    defp test_process, do: List.last(Process.get(:"$callers", [self()]))

    def validate_files(records, opts) do
      send(test_process(), {:validated, records, opts})

      case Enum.find(records, &(&1.size > opts[:max_file_size])) do
        nil ->
          :ok

        record ->
          {:error,
           {:file_too_large,
            %{filename: record.name, size: record.size, limit: opts[:max_file_size]}}}
      end
    end
  end

  defmodule Config do
    def get(:zaq, :channels, _default), do: %{mattermost: %{adapter: Adapter}}
  end

  defmodule Resolver do
    def bridge_for(:mattermost), do: JidoChatBridge

    def fetch_connection_details_for_config(config),
      do: Bridge.fetch_connection_details_for_config(config)
  end

  defmodule Router do
    def dispatch(%Event{request: %Outgoing{}} = event) do
      send(event.actor.test_pid, {:validation_event, event})
      event = %{event | opts: event.opts ++ [bridge_module: Resolver, config: Config]}
      Api.handle_event(event, :validate_files, %{})
    end
  end

  defmodule UnavailableRouter do
    def dispatch(_event), do: {:error, :no_channels_node}
  end

  defmodule LegacyAdapter do
    def capabilities, do: %{configurable_max_file_size: :native}
  end

  defmodule LegacyConfig do
    def get(:zaq, :channels, _default), do: %{mattermost: %{adapter: LegacyAdapter}}
  end

  setup do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "preflight-#{System.unique_integer([:positive])}",
        provider: "mattermost",
        kind: "retrieval",
        enabled: true,
        url: "https://preflight.example.invalid",
        token: "test-only-token",
        settings: %{"max_file_size" => 10}
      })
      |> Repo.insert!()

    incoming = %Incoming{
      content: "attach",
      provider: :mattermost,
      channel_id: "destination",
      routing_context: %RoutingContext{channel_config_id: config.id}
    }

    context = %{
      incoming: incoming,
      request_id: "request",
      state: %{requests: %{"request" => %{status: :pending}}},
      actor: %{person_id: 1, test_pid: self()},
      skip_permissions: true,
      node_router: Router
    }

    %{context: context}
  end

  test "authorized lazy Records reach the destination adapter through a synchronous event", %{
    context: context
  } do
    record = record(10)
    assert {:ok, %{records: [^record]}} = select_files("add", [record], context)
    assert_receive {:validation_event, %Event{} = event}
    assert event.actor == context.actor
    assert event.next_hop.type == :sync
    assert event.opts[:action] == :validate_files
    assert event.opts[:confidential]
    assert event.request.routing_context == context.incoming.routing_context
    assert_receive {:validated, [%Record{content: nil, size: 10}], opts}
    assert opts[:max_file_size] == 10
  end

  property "one oversized file rejects selection regardless of batch position", %{
    context: context
  } do
    check all(size <- integer(11..100_000), position <- integer(0..2), max_runs: 15) do
      records = List.insert_at([record(0), record(10)], position, record(size))
      assert {:error, error} = select_files("replace", records, context)
      assert inspect(error) =~ "file_too_large"
      assert_receive {:validated, ^records, opts}
      assert opts[:max_file_size] == 10
    end
  end

  test "remove and clear do not need destination validation", %{context: context} do
    assert {:ok, _} = select_files("remove", [record(100)], context)
    assert {:ok, _} = select_files("replace", [], context)
    refute_receive {:validation_event, _}
  end

  test "workflow Incoming without a provider defers validation until a destination is known", %{
    context: context
  } do
    incoming = %{context.incoming | provider: nil}
    assert {:ok, _} = select_files("add", [record(100)], %{context | incoming: incoming})
    refute_receive {:validation_event, _}
  end

  test "content is not sent to validation and successful selection retains the original", %{
    context: context
  } do
    record = %{record(1) | content: "a"}
    assert {:ok, %{records: [^record]}} = select_files("add", [record], context)
    assert_receive {:validated, [%Record{content: nil}], _}
  end

  test "failed authorization never reaches validation", %{context: context} do
    context = %{context | actor: nil, skip_permissions: false}
    assert {:error, _} = select_files("add", [record(1)], context)
    refute_receive {:validation_event, _}
  end

  test "routing failures return to the tool", %{context: context} do
    assert {:error, error} =
             select_files("add", [record(1)], %{context | node_router: UnavailableRouter})

    assert inspect(error) =~ "no_channels_node"
  end

  test "an invalid destination connector fails instead of validating with another connector", %{
    context: context
  } do
    incoming = %{context.incoming | routing_context: %RoutingContext{channel_config_id: -1}}
    assert {:error, error} = select_files("add", [record(1)], %{context | incoming: incoming})
    assert inspect(error) =~ "invalid_connector_id"
    refute_receive {:validated, _, _}
  end

  test "an adapter without validation accepts selection regardless of configurable limits" do
    outgoing = %Outgoing{body: "", provider: :mattermost, channel_id: "room"}

    assert :ok = JidoChatBridge.validate_files(outgoing, %{}, config: LegacyConfig)
  end

  defp select_files(operation, records, context),
    do: Jido.Exec.run(AttachDocuments, %{operation: operation, records: records}, context)

  defp record(size) do
    {:ok, record} =
      Provenance.seal(%Record{id: "file-#{size}", kind: :file, name: "file-#{size}", size: size})

    record
  end
end
