defmodule Zaq.Engine.ConnectorArchivePersistenceTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  alias Zaq.Channels.Api
  alias Zaq.Engine.{ChannelConfig, ConnectorLifecycle}
  alias Zaq.Event
  alias Zaq.Types.EncryptedString

  defmodule Router do
    def dispatch(%Event{} = event) do
      assert event.opts[:confidential]
      send(self(), {:archive_runtime_event, event})
      if callback = Process.get(:before_archive_runtime_call), do: callback.(event)
      Api.handle_event(event, event.opts[:action], nil)
    end
  end

  defmodule RuntimeStub do
    def stop_runtime(config) do
      send(self(), {:runtime_sync, config.id, config.id})
      Process.get(:runtime_result, :ok)
    end
  end

  defmodule IngressStub do
    def delete_ingress_subscription(config, params) do
      send(self(), {:ingress_teardown, config.provider, params})
      Process.get(:ingress_result, {:ok, %{deleted: true}})
    end
  end

  setup do
    previous = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      mattermost: %{ingress_mode: :webhook},
      disk: %{ingress_mode: :polling}
    })

    on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)
    :ok
  end

  test "archives an exact live connector after ingress teardown and runtime sync" do
    config = insert_config("mattermost", "retrieval")
    assert {:ok, descriptor} = ConnectorLifecycle.context(config.id, "mattermost", "retrieval")

    assert {:ok,
            %{
              channel_config_id: id,
              status: :archived,
              ingress: :deleted,
              runtime: :synced
            }} =
             archive(descriptor_request(descriptor),
               communication_bridge_module: IngressStub,
               communication_runtime_module: RuntimeStub
             )

    assert id == config.id
    assert_received {:ingress_teardown, "mattermost", %{config_id: ^id, strict: true}}
    assert_received {:runtime_sync, ^id, ^id}
    refute Repo.get!(ChannelConfig, id).enabled
    assert Repo.get!(ChannelConfig, id).archived_at
  end

  test "teardown failures leave the connector live" do
    config = insert_config("mattermost", "retrieval")
    {:ok, descriptor} = ConnectorLifecycle.context(config.id, config.provider, config.kind)
    Process.put(:ingress_result, {:error, :provider_down})

    assert {:error, {:ingress_teardown_failed, :provider_down}} =
             archive(descriptor_request(descriptor),
               communication_bridge_module: IngressStub,
               communication_runtime_module: RuntimeStub
             )

    assert Repo.get!(ChannelConfig, config.id).archived_at == nil
    refute_received {:runtime_sync, _, _}
  end

  test "exact positive connector IDs accept strings but reject malformed scope before side effects" do
    config = insert_config("mattermost", "retrieval")

    assert {:ok, %{channel_config_id: id}} =
             ConnectorLifecycle.context(to_string(config.id), config.provider, config.kind)

    assert id == config.id

    for invalid <- [nil, 0, -1, "", "0", "-1", "#{id}junk", 1.5] do
      assert {:error, :connector_not_found} =
               ConnectorLifecycle.context(invalid, config.provider, config.kind)

      assert {:error, :connector_not_found} =
               archive(
                 %{channel_config_id: invalid, provider: config.provider, kind: config.kind},
                 []
               )
    end

    refute_received {:archive_runtime_event, _}
  end

  property "malformed connector ID strings fail closed without effects" do
    check all(
            invalid <- StreamData.string(:alphanumeric, min_length: 1, max_length: 12),
            not Regex.match?(~r/^[1-9][0-9]*$/, invalid),
            max_runs: 30
          ) do
      config = insert_config("mattermost", "retrieval")

      assert {:error, :connector_not_found} =
               ConnectorLifecycle.context(invalid, config.provider, config.kind)

      refute_received {:archive_runtime_event, _}
    end
  end

  test "stale descriptors and connector mismatches fail before side effects" do
    config = insert_config("mattermost", "retrieval")
    {:ok, descriptor} = ConnectorLifecycle.context(config.id, config.provider, config.kind)

    config |> Ecto.Changeset.change(name: "changed") |> Repo.update!()

    assert {:error, :stale_connector} =
             archive(descriptor_request(descriptor),
               communication_bridge_module: IngressStub
             )

    assert {:error, :connector_not_found} =
             ConnectorLifecycle.context(config.id, "discord", "retrieval")

    refute_received {:ingress_teardown, _, _}
  end

  test "archive retries skip destructive teardown and report pending runtime" do
    config = insert_config("mattermost", "retrieval")
    {:ok, descriptor} = ConnectorLifecycle.context(config.id, config.provider, config.kind)

    {:ok, first} =
      archive(descriptor_request(descriptor),
        communication_bridge_module: IngressStub,
        communication_runtime_module: RuntimeStub
      )

    assert first.status == :archived
    assert_received {:ingress_teardown, _, _}
    {:ok, retry_descriptor} = ConnectorLifecycle.context(config.id, config.provider, config.kind)
    Process.put(:runtime_result, {:error, :runtime_down})

    assert {:ok,
            %{
              status: :already_archived,
              ingress: :already_archived,
              runtime: {:pending, :runtime_down}
            }} =
             archive(descriptor_request(retry_descriptor),
               communication_bridge_module: IngressStub,
               communication_runtime_module: RuntimeStub
             )

    refute_received {:ingress_teardown, _, _}
    assert_received {:runtime_sync, id, id}
    assert id == config.id
    assert Repo.get!(ChannelConfig, config.id).archived_at
  end

  test "runtime unexpected response is pending after the archive commits" do
    config = insert_config("mattermost", "retrieval")
    {:ok, descriptor} = ConnectorLifecycle.context(config.id, config.provider, config.kind)
    Process.put(:runtime_result, :unexpected)

    assert {:ok, %{status: :archived, runtime: {:pending, {:unexpected_response, :unexpected}}}} =
             archive(descriptor_request(descriptor),
               communication_bridge_module: IngressStub,
               communication_runtime_module: RuntimeStub
             )

    assert Repo.get!(ChannelConfig, config.id).archived_at
    assert_received {:ingress_teardown, _, _}
  end

  test "data-source leaf skips communication ingress and uses its runtime owner" do
    config = insert_config("disk", "data_source")
    {:ok, descriptor} = ConnectorLifecycle.context(config.id, config.provider, config.kind)

    assert {:ok, %{status: :archived, ingress: :not_required, runtime: :synced}} =
             archive(descriptor_request(descriptor),
               data_source_runtime_module: RuntimeStub,
               communication_bridge_module: IngressStub
             )

    refute_received {:ingress_teardown, _, _}
    assert_received {:runtime_sync, _, _}
  end

  test "an edit during provider teardown fails the locked revision check without archiving" do
    config = insert_config("mattermost", "retrieval")
    {:ok, descriptor} = ConnectorLifecycle.context(config.id, config.provider, config.kind)

    Process.put(:before_archive_runtime_call, fn event ->
      if event.opts[:action] == :connector_teardown_ingress do
        config |> Ecto.Changeset.change(name: "edited during teardown") |> Repo.update!()
      end
    end)

    assert {:error, :stale_connector} =
             archive(descriptor_request(descriptor),
               communication_bridge_module: IngressStub,
               communication_runtime_module: RuntimeStub
             )

    refute Repo.get!(ChannelConfig, config.id).archived_at
    refute_received {:runtime_sync, _, _}
  end

  test "archive result is secret-free while transport receives the exact resolved connector" do
    config = insert_config("mattermost", "retrieval")
    sibling = insert_config("mattermost", "retrieval")
    {:ok, descriptor} = ConnectorLifecycle.context(config.id, config.provider, config.kind)

    assert {:ok, result} =
             archive(descriptor_request(descriptor),
               communication_bridge_module: IngressStub,
               communication_runtime_module: RuntimeStub
             )

    id = config.id

    assert_received {:archive_runtime_event,
                     %Event{
                       request: %{config: %{id: ^id, token: token}},
                       actor: %{user_id: 1},
                       opts: opts
                     }}

    assert {:ok, ^token} = EncryptedString.decrypt(config.token)
    assert opts[:confidential]
    assert opts[:action] == :connector_teardown_ingress
    refute Map.has_key?(result, :token)
    refute Map.has_key?(result, :config)
    refute Repo.get!(ChannelConfig, sibling.id).archived_at
  end

  defp archive(request, opts) do
    ConnectorLifecycle.archive(request, %{user_id: 1}, Keyword.put(opts, :router, Router))
  end

  defp descriptor_request(descriptor) do
    %{
      channel_config_id: descriptor.channel_config_id,
      provider: descriptor.provider,
      kind: descriptor.kind,
      revision: descriptor.revision
    }
  end

  defp insert_config(provider, kind) do
    value = System.unique_integer([:positive])

    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "#{provider}-#{value}",
      provider: provider,
      kind: kind,
      enabled: true,
      url: "https://#{value}.example.invalid",
      token: "token-#{value}",
      settings:
        if(provider == "disk",
          do: %{"volumes" => [%{"name" => "v", "path" => "archive-test"}]},
          else: %{}
        )
    })
    |> Repo.insert!()
  end
end
