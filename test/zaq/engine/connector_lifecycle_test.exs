defmodule Zaq.Engine.ConnectorLifecycleTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.ConnectorLifecycle
  alias Zaq.Event

  defmodule Router do
    def dispatch(%Event{opts: opts} = event) do
      send(self(), {:channels_call, opts[:action], event.request})

      supplied = event.request[:config] || event.request[:after_config]
      config = Zaq.Repo.get!(ChannelConfig, supplied.id)
      state = {opts[:action], config.enabled, config.archived_at}
      Process.put(:lifecycle_states, Process.get(:lifecycle_states, []) ++ [state])

      response =
        case {opts[:action], Process.get(:router_mode)} do
          {_, :raise} ->
            raise "router failed"

          {_, :exit} ->
            exit(:router_exit)

          {:connector_teardown_ingress, _} ->
            Process.get(:teardown_response, {:ok, :not_required})

          {:connector_prepare_disable, _} ->
            Process.get(:disable_response, :ok)

          {:connector_sync_runtime, _} ->
            if callback = Process.get(:on_runtime_stop), do: callback.()
            Process.get(:runtime_response, :ok)
        end

      if Process.get(:router_mode) == :non_event do
        response
      else
        %{event | response: response}
      end
    end
  end

  defmodule DataSourcesStub do
    def stop_config_watch_channels(id) do
      send(self(), {:stop_watches, id})
      Process.get(:stop_response, {:ok, 2})
    end

    def reconcile_archived_config_watches(id) do
      send(self(), {:reconcile_watches, id})
      Process.get(:reconcile_response, {:ok, 1})
    end
  end

  setup do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "archive-watch",
        provider: "disk",
        kind: "data_source",
        enabled: true,
        settings: %{"volumes" => [%{"name" => "v", "path" => "archive-test"}]}
      })
      |> Repo.insert!()

    Process.put(:config_id, config.id)
    %{config: config}
  end

  test "data-source archive orders watch stop, Channels archive and reconciliation" do
    assert {:ok, result} = archive()

    id = Process.get(:config_id)
    assert result.channel_config_id == id
    assert result.watch_teardown == %{status: :stopped, count: 2}
    assert result.cleanup == %{status: :scheduled, count: 1}

    assert_received {:stop_watches, ^id}
    assert_received {:channels_call, :connector_teardown_ingress, %{config: %{id: ^id}}}

    assert_received {:channels_call, :connector_sync_runtime,
                     %{after_config: %{id: ^id, enabled: false}}}

    assert_received {:reconcile_watches, ^id}
  end

  test "partial watch teardown stops before Channels archive" do
    Process.put(:stop_response, {:error, [{7, :provider_down}]})

    assert {:error, {:watch_teardown_failed, [{7, :provider_down}]}} = archive()
    refute_received {:channels_call, :connector_teardown_ingress, _}
    refute_received {:channels_call, :connector_sync_runtime, _}
    refute_received {:reconcile_watches, _}
  end

  test "post-archive cleanup failures are truthful pending warnings" do
    Process.put(:reconcile_response, {:error, :queue_down})

    assert {:ok, %{status: :archived, cleanup: %{status: :pending, reason: :queue_down}}} =
             archive()
  end

  test "communication connectors skip Engine watch operations" do
    config = Repo.get!(ChannelConfig, Process.get(:config_id))
    config |> Ecto.Changeset.change(kind: "retrieval") |> Repo.update!()

    assert {:ok, %{watch_teardown: %{status: :not_required}, cleanup: %{status: :not_required}}} =
             archive()

    refute_received {:stop_watches, _}
    refute_received {:reconcile_watches, _}
  end

  test "archive accepts saved config IDs and rejects invalid requests without dispatch" do
    config = Repo.get!(ChannelConfig, Process.get(:config_id))
    config |> Ecto.Changeset.change(kind: "retrieval") |> Repo.update!()

    assert {:ok, %{channel_config_id: id, status: :archived}} =
             ConnectorLifecycle.archive(
               %{channel_config_id: to_string(config.id), provider: "disk", kind: "retrieval"},
               %{user_id: 1},
               router: Router
             )

    assert id == config.id
    refute Repo.get!(ChannelConfig, id).enabled
    assert_received {:channels_call, :connector_teardown_ingress, _}
    assert_received {:channels_call, :connector_prepare_disable, _}
    assert_received {:channels_call, :connector_sync_runtime, _}
    assert {:error, :invalid_request} = ConnectorLifecycle.archive(:not_a_map, %{user_id: 1}, [])

    assert {:error, :invalid_request} =
             ConnectorLifecycle.archive(%{}, %{user_id: 1}, :not_a_list)

    refute_received {:channels_call, _, _}
  end

  test "already-archived data-source retry skips watch teardown and continues reconciliation and runtime sync" do
    config = Repo.get!(ChannelConfig, Process.get(:config_id))
    assert {:ok, %{status: :archived}} = archive()
    assert_received {:channels_call, :connector_teardown_ingress, _}
    assert_received {:channels_call, :connector_sync_runtime, _}
    assert_received {:reconcile_watches, first_id}
    assert first_id == config.id

    {:ok, fresh_descriptor} = ConnectorLifecycle.context(config.id, config.provider, config.kind)
    assert fresh_descriptor.archived?

    assert {:ok, result} =
             ConnectorLifecycle.archive(
               Map.take(fresh_descriptor, [:channel_config_id, :provider, :kind, :revision]),
               %{user_id: 1},
               router: Router,
               data_sources_module: DataSourcesStub
             )

    assert result.status == :already_archived
    assert result.watch_teardown == %{status: :already_archived, count: 0}
    assert result.cleanup == %{status: :scheduled, count: 1}
    assert result.runtime == :synced

    assert_received {:stop_watches, id}
    assert id == config.id
    refute_received {:stop_watches, ^id}
    assert_received {:reconcile_watches, ^id}
    assert_received {:channels_call, :connector_sync_runtime, %{after_config: %{id: ^id}}}
    refute_received {:channels_call, :connector_teardown_ingress, _}
  end

  test "runtime {:ok, :stopped} response counts as synced" do
    config = Repo.get!(ChannelConfig, Process.get(:config_id))
    config |> Ecto.Changeset.change(kind: "retrieval") |> Repo.update!()
    Process.put(:runtime_response, {:ok, :stopped})
    request = %{channel_config_id: config.id, provider: "disk", kind: "retrieval"}

    assert {:ok, %{runtime: :synced}} =
             ConnectorLifecycle.archive(request, %{user_id: 1}, router: Router)
  end

  test "router ingress error and unexpected response keep connector live" do
    config = Repo.get!(ChannelConfig, Process.get(:config_id))
    config |> Ecto.Changeset.change(kind: "retrieval") |> Repo.update!()

    for {response, expected} <- [
          {{:error, :provider_down}, {:error, {:ingress_teardown_failed, :provider_down}}},
          {:unexpected, {:error, {:ingress_teardown_failed, {:unexpected_response, :unexpected}}}}
        ] do
      Process.put(:teardown_response, response)
      request = %{channel_config_id: config.id, provider: "disk", kind: "retrieval"}
      assert ^expected = ConnectorLifecycle.archive(request, %{user_id: 1}, router: Router)
      assert Repo.get!(ChannelConfig, config.id).archived_at == nil
      refute_received {:channels_call, :connector_sync_runtime, _}
    end
  end

  test "unexpected runtime response leaves the connector disabled without archiving" do
    config = Repo.get!(ChannelConfig, Process.get(:config_id))
    config |> Ecto.Changeset.change(kind: "retrieval") |> Repo.update!()
    Process.put(:runtime_response, :unexpected)
    request = %{channel_config_id: config.id, provider: "disk", kind: "retrieval"}

    assert {:error, {:runtime_stop_failed, {:unexpected_response, :unexpected}}} =
             ConnectorLifecycle.archive(request, %{user_id: 1}, router: Router)

    refute Repo.get!(ChannelConfig, config.id).archived_at
    refute Repo.get!(ChannelConfig, config.id).enabled
  end

  property "every adapter is disabled and stopped before archive persistence" do
    check all(
            provider <-
              member_of(
                ~w(whatsapp mattermost telegram slack disk web_widget email:smtp email:imap)
              )
          ) do
      config =
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: "ordered",
          enabled: false,
          provider: provider,
          kind: "retrieval",
          url: "https://example.test",
          token: "test-token",
          settings: %{"imap" => %{"selected_mailboxes" => ["INBOX"]}}
        })
        |> Repo.insert!()
        |> Ecto.Changeset.change(enabled: true)
        |> Repo.update!()

      Process.put(:lifecycle_states, [])

      assert {:ok, %{status: :archived, runtime: :synced}} =
               ConnectorLifecycle.archive(
                 %{channel_config_id: config.id, provider: provider, kind: "retrieval"},
                 %{user_id: 1},
                 router: Router
               )

      assert Process.get(:lifecycle_states) == [
               {:connector_teardown_ingress, true, nil},
               {:connector_prepare_disable, true, nil},
               {:connector_sync_runtime, false, nil}
             ]

      assert Repo.get!(ChannelConfig, config.id).archived_at
      refute Repo.get!(ChannelConfig, config.id).enabled
    end
  end

  test "adapter disable failure preserves enablement and prevents runtime stop", %{config: config} do
    Process.put(:disable_response, {:error, :logout_failed})
    assert {:error, {:disable_failed, :logout_failed}} = archive()
    assert Repo.get!(ChannelConfig, config.id).enabled
    refute Repo.get!(ChannelConfig, config.id).archived_at
    refute_received {:channels_call, :connector_sync_runtime, _}
  end

  test "runtime stop failure can retry deletion without repeating adapter logout", %{
    config: config
  } do
    Process.put(:runtime_response, {:error, :unavailable})
    assert {:error, {:runtime_stop_failed, :unavailable}} = archive()
    assert_received {:channels_call, :connector_prepare_disable, _}
    refute Repo.get!(ChannelConfig, config.id).enabled
    refute Repo.get!(ChannelConfig, config.id).archived_at

    Process.put(:runtime_response, :ok)
    assert {:ok, %{status: :archived}} = archive()
    refute_received {:channels_call, :connector_prepare_disable, _}
    assert Repo.get!(ChannelConfig, config.id).archived_at
  end

  test "re-enabling during runtime shutdown prevents archival", %{config: config} do
    Process.put(:on_runtime_stop, fn ->
      Repo.get!(ChannelConfig, config.id)
      |> Ecto.Changeset.change(enabled: true)
      |> Repo.update!()
    end)

    assert {:error, :stale_connector} = archive()
    assert Repo.get!(ChannelConfig, config.id).enabled
    refute Repo.get!(ChannelConfig, config.id).archived_at
  end

  test "router non-event, raise, and exit at ingress fail closed" do
    config = Repo.get!(ChannelConfig, Process.get(:config_id))
    config |> Ecto.Changeset.change(kind: "retrieval") |> Repo.update!()
    request = %{channel_config_id: config.id, provider: "disk", kind: "retrieval"}

    for mode <- [:non_event, :raise, :exit] do
      Process.put(:router_mode, mode)

      assert {:error, {:ingress_teardown_failed, :channels_unavailable}} =
               ConnectorLifecycle.archive(request, %{user_id: 1}, router: Router)

      assert Repo.get!(ChannelConfig, config.id).archived_at == nil
      refute_received {:channels_call, :connector_sync_runtime, _}
    end
  end

  defp archive do
    ConnectorLifecycle.archive(
      %{
        channel_config_id: Process.get(:config_id),
        provider: "disk",
        kind: Repo.get!(ChannelConfig, Process.get(:config_id)).kind
      },
      %{user_id: 1},
      router: Router,
      data_sources_module: DataSourcesStub
    )
  end
end
