defmodule Zaq.Engine.DataSourcesTest do
  use Zaq.DataCase, async: false
  use Oban.Testing, repo: Zaq.Repo

  import Ecto.Query

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.DataSources
  alias Zaq.Engine.DataSources.WatchChannel
  alias Zaq.Engine.DataSources.WatchChannelRenewalWorker
  alias Zaq.Engine.DataSourcesTest
  alias Zaq.Repo
  alias Zaq.System

  defmodule StubRenewalNodeRouter do
    alias Zaq.Engine.DataSources

    def dispatch(%{opts: [action: :data_source_watch_item]} = event) do
      send(self(), {:renewal_watch_item, event.request})
      :ok = DataSourcesTest.persist_replacement_watch_channel(event.request)
      %{event | response: {:ok, %{channel_id: "new-channel-1"}}}
    end

    def dispatch(%{opts: [action: :data_source_unwatch_item]} = event) do
      send(self(), {:renewal_unwatch_item, event.request})
      %{event | response: {:ok, %{status: "unwatched"}}}
    end

    def dispatch(event), do: %{event | response: {:error, :unexpected_event}}
  end

  defmodule StubRenewalUnwatchErrorNodeRouter do
    def dispatch(%{opts: [action: :data_source_watch_item]} = event) do
      send(self(), {:renewal_watch_item, event.request})
      :ok = DataSourcesTest.persist_replacement_watch_channel(event.request)
      %{event | response: {:ok, %{channel_id: "new-channel-1"}}}
    end

    def dispatch(%{opts: [action: :data_source_unwatch_item]} = event) do
      send(self(), {:renewal_unwatch_item, event.request})
      %{event | response: {:error, :unwatch_failed}}
    end

    def dispatch(event), do: %{event | response: {:error, :unexpected_event}}
  end

  defmodule StubRenewalUnwatchUnexpectedNodeRouter do
    def dispatch(%{opts: [action: :data_source_watch_item]} = event) do
      send(self(), {:renewal_watch_item, event.request})
      :ok = DataSourcesTest.persist_replacement_watch_channel(event.request)
      %{event | response: {:ok, %{channel_id: "new-channel-1"}}}
    end

    def dispatch(%{opts: [action: :data_source_unwatch_item]} = event) do
      send(self(), {:renewal_unwatch_item, event.request})
      %{event | response: :unexpected_unwatch_response}
    end

    def dispatch(event), do: %{event | response: {:error, :unexpected_event}}
  end

  defmodule StubRenewalWatchErrorNodeRouter do
    def dispatch(%{opts: [action: :data_source_watch_item]} = event) do
      send(self(), {:renewal_watch_item, event.request})
      %{event | response: {:error, :watch_failed}}
    end

    def dispatch(%{opts: [action: :data_source_unwatch_item]} = event) do
      send(self(), {:renewal_unwatch_item, event.request})
      %{event | response: {:ok, %{status: "unwatched"}}}
    end

    def dispatch(event), do: %{event | response: {:error, :unexpected_event}}
  end

  defmodule StubRenewalWatchMissingChannelIdNodeRouter do
    def dispatch(%{opts: [action: :data_source_watch_item]} = event) do
      send(self(), {:renewal_watch_item, event.request})
      %{event | response: {:ok, %{}}}
    end

    def dispatch(%{opts: [action: :data_source_unwatch_item]} = event) do
      send(self(), {:renewal_unwatch_item, event.request})
      %{event | response: {:ok, %{status: "unwatched"}}}
    end

    def dispatch(event), do: %{event | response: {:error, :unexpected_event}}
  end

  defmodule StubRenewalWatchUnexpectedNodeRouter do
    def dispatch(%{opts: [action: :data_source_watch_item]} = event) do
      send(self(), {:renewal_watch_item, event.request})
      %{event | response: :unexpected_watch_response}
    end

    def dispatch(%{opts: [action: :data_source_unwatch_item]} = event) do
      send(self(), {:renewal_unwatch_item, event.request})
      %{event | response: {:ok, %{status: "unwatched"}}}
    end

    def dispatch(event), do: %{event | response: {:error, :unexpected_event}}
  end

  defmodule StubIngestionOkNodeRouter do
    def dispatch(%{opts: [action: :process_data_source_changes]} = event) do
      send(self(), {:ingestion_process_data_source_changes, event.request})
      %{event | response: :ok}
    end

    def dispatch(event), do: %{event | response: {:error, {:unexpected_event, event.opts}}}
  end

  defmodule StubIngestionErrorNodeRouter do
    def dispatch(%{opts: [action: :process_data_source_changes]} = event) do
      send(self(), {:ingestion_process_data_source_changes, event.request})
      %{event | response: {:error, :ingestion_failed}}
    end

    def dispatch(event), do: %{event | response: {:error, {:unexpected_event, event.opts}}}
  end

  defmodule StubIngestionUnexpectedNodeRouter do
    def dispatch(%{opts: [action: :process_data_source_changes]} = event) do
      send(self(), {:ingestion_process_data_source_changes, event.request})
      %{event | response: :unexpected_ingestion_response}
    end

    def dispatch(event), do: %{event | response: {:error, {:unexpected_event, event.opts}}}
  end

  defp insert_data_source_config do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "Google Drive",
      provider: "google_drive",
      kind: "data_source",
      settings: %{}
    })
    |> Repo.insert!()
  end

  defp watch_attrs(config, overrides \\ %{}) do
    Map.merge(
      %{
        config_id: config.id,
        provider: "google_drive",
        target_source: "data_source/google_drive/#{config.id}/folder-1",
        target_provider_id: "folder-1",
        target_kind: "collection",
        channel_id: "channel-1",
        resource_id: "resource-1",
        checkpoint: "checkpoint-1"
      },
      overrides
    )
  end

  def persist_replacement_watch_channel(request, channel_id \\ "new-channel-1") do
    params = Map.get(request, :params) || Map.get(request, "params") || %{}
    provider = Map.get(request, :provider) || Map.get(request, "provider")

    {:ok, _watch_channel} =
      DataSources.upsert_watch_channel(%{
        config_id: params.config_id,
        provider: to_string(provider),
        target_source: params.target_source,
        target_provider_id: params.target_provider_id,
        target_kind: params.kind,
        channel_id: channel_id,
        resource_id: "new-resource-1",
        checkpoint: params.checkpoint,
        expiration_at: DateTime.utc_now() |> DateTime.add(86_400, :second),
        metadata: %{"watch" => %{}}
      })

    :ok
  end

  defp with_engine_data_sources_env(router_module, base_url, fun) do
    previous_router = Application.get_env(:zaq, :engine_data_sources_node_router_module)
    previous_base_url = System.get_global_base_url()

    case router_module do
      nil -> Application.delete_env(:zaq, :engine_data_sources_node_router_module)
      module -> Application.put_env(:zaq, :engine_data_sources_node_router_module, module)
    end

    :ok = System.set_global_base_url(base_url)

    try do
      fun.()
    after
      :ok = System.set_global_base_url(previous_base_url)

      case previous_router do
        nil -> Application.delete_env(:zaq, :engine_data_sources_node_router_module)
        module -> Application.put_env(:zaq, :engine_data_sources_node_router_module, module)
      end
    end
  end

  test "upsert_watch_channel creates and updates provider runtime state" do
    config = insert_data_source_config()

    assert {:ok, %WatchChannel{} = watch_channel} =
             DataSources.upsert_watch_channel(watch_attrs(config))

    assert watch_channel.checkpoint == "checkpoint-1"

    assert {:ok, %WatchChannel{} = updated} =
             DataSources.upsert_watch_channel(watch_attrs(config, %{checkpoint: "checkpoint-2"}))

    assert updated.id == watch_channel.id
    assert updated.checkpoint == "checkpoint-2"
  end

  test "upsert_watch_channel stores JSON-safe string values in watch metadata" do
    config = insert_data_source_config()

    assert {:ok, %WatchChannel{} = watch_channel} =
             DataSources.upsert_watch_channel(
               watch_attrs(config, %{
                 provider: :google_drive,
                 target_provider_id: 123,
                 target_kind: :collection,
                 metadata: %{watch: %{provider: :stale}}
               })
             )

    assert watch_channel.metadata["watch"] == %{
             "provider" => "google_drive",
             "channel_id" => "channel-1",
             "resource_id" => "resource-1",
             "file_id" => "123",
             "collection_id" => "123",
             "kind" => "collection",
             "checkpoint" => "checkpoint-1"
           }
  end

  test "upsert_watch_channel parses provider expiration and schedules renewal" do
    config = insert_data_source_config()

    expiration_ms =
      DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.to_unix(:millisecond)

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, %WatchChannel{} = watch_channel} =
               DataSources.upsert_watch_channel(
                 watch_attrs(config, %{
                   expiration_at: Integer.to_string(expiration_ms),
                   metadata: %{"watch" => %{}}
                 })
               )

      assert %DateTime{} = watch_channel.expiration_at
      assert DateTime.to_unix(watch_channel.expiration_at) == div(expiration_ms, 1_000)

      assert [job] = all_enqueued(worker: WatchChannelRenewalWorker)
      assert job.args == %{"watch_channel_id" => watch_channel.id}

      assert DateTime.diff(job.scheduled_at, watch_channel.expiration_at, :second) == -3_600
    end)
  end

  test "resolve_watch_channel finds by provider channel and resource" do
    config = insert_data_source_config()
    {:ok, watch_channel} = DataSources.upsert_watch_channel(watch_attrs(config))

    assert {:ok, resolved} =
             DataSources.resolve_watch_channel(%{
               provider: "google_drive",
               channel_id: "channel-1",
               resource_id: "resource-1"
             })

    assert resolved.id == watch_channel.id
  end

  test "resolve_watch_channel reuses existing changes watcher for config-level lookup" do
    config = insert_data_source_config()

    {:ok, watch_channel} =
      DataSources.upsert_watch_channel(
        watch_attrs(config, %{
          target_source: "data_source/google_drive/#{config.id}/folder-1",
          target_provider_id: "changes",
          target_kind: "collection"
        })
      )

    assert {:ok, resolved} =
             DataSources.resolve_watch_channel(%{
               provider: "google_drive",
               config_id: config.id,
               target_source: "data_source/google_drive/#{config.id}",
               target_provider_id: "changes"
             })

    assert resolved.id == watch_channel.id
  end

  test "resolve_watch_channel does not reuse expired watch channels" do
    config = insert_data_source_config()

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, _watch_channel} =
        DataSources.upsert_watch_channel(
          watch_attrs(config, %{
            target_source: "data_source/google_drive/#{config.id}",
            target_provider_id: "changes",
            target_kind: "collection",
            expiration_at: DateTime.utc_now() |> DateTime.add(-60, :second)
          })
        )
    end)

    assert {:error, :watch_channel_not_found} =
             DataSources.resolve_watch_channel(%{
               provider: "google_drive",
               config_id: config.id,
               target_source: "data_source/google_drive/#{config.id}",
               target_provider_id: "changes"
             })
  end

  test "renew_watch_channel creates replacement, stops provider watch, and deletes old row" do
    previous_router = Application.get_env(:zaq, :engine_data_sources_node_router_module)
    previous_base_url = System.get_global_base_url()
    Application.put_env(:zaq, :engine_data_sources_node_router_module, StubRenewalNodeRouter)
    :ok = System.set_global_base_url("https://renewed.example/base/")

    on_exit(fn ->
      :ok = System.set_global_base_url(previous_base_url)

      case previous_router do
        nil -> Application.delete_env(:zaq, :engine_data_sources_node_router_module)
        module -> Application.put_env(:zaq, :engine_data_sources_node_router_module, module)
      end
    end)

    config = insert_data_source_config()

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, old_watch_channel} =
        DataSources.upsert_watch_channel(
          watch_attrs(config, %{
            target_source: "data_source/google_drive/#{config.id}",
            target_provider_id: "changes",
            target_kind: "collection",
            channel_id: "old-channel-1",
            resource_id: "old-resource-1",
            expiration_at: DateTime.utc_now() |> DateTime.add(3_600, :second),
            metadata: %{"watch" => %{}}
          })
        )

      assert {:ok, %WatchChannel{} = new_watch_channel} =
               DataSources.renew_watch_channel(old_watch_channel.id)

      assert new_watch_channel.channel_id == "new-channel-1"
      assert new_watch_channel.checkpoint == old_watch_channel.checkpoint
      assert Repo.get(WatchChannel, old_watch_channel.id) == nil

      assert_received {:renewal_watch_item,
                       %{
                         provider: "google_drive",
                         params: %{
                           config_id: config_id,
                           force_new_watch_channel: true,
                           webhook_url:
                             "https://renewed.example/base/channels/webhook/data_source/google_drive"
                         }
                       }}

      assert config_id == config.id

      assert_received {:renewal_unwatch_item,
                       %{
                         provider: "google_drive",
                         params: %{
                           channel_id: "old-channel-1",
                           resource_id: "old-resource-1"
                         }
                       }}
    end)
  end

  test "renew_watch_channel fails without global base URL" do
    previous_base_url = System.get_global_base_url()
    :ok = System.set_global_base_url(nil)

    on_exit(fn -> :ok = System.set_global_base_url(previous_base_url) end)

    config = insert_data_source_config()

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, old_watch_channel} =
        DataSources.upsert_watch_channel(
          watch_attrs(config, %{
            target_source: "data_source/google_drive/#{config.id}",
            target_provider_id: "changes",
            target_kind: "collection",
            channel_id: "old-channel-1",
            resource_id: "old-resource-1",
            expiration_at: DateTime.utc_now() |> DateTime.add(3_600, :second)
          })
        )

      assert {:error, :missing_global_base_url} =
               DataSources.renew_watch_channel(old_watch_channel.id)

      assert Repo.get(WatchChannel, old_watch_channel.id)
    end)
  end

  test "process_watch_changes advances checkpoint metadata copy" do
    config = insert_data_source_config()

    {:ok, watch_channel} =
      DataSources.upsert_watch_channel(
        watch_attrs(config, %{
          metadata: %{"watch" => %{"checkpoint" => "checkpoint-1"}}
        })
      )

    assert {:ok, %{jobs: [], removed: 0}} =
             DataSources.process_watch_changes(%{
               watch_channel_id: watch_channel.id,
               checkpoint: "checkpoint-1",
               next_checkpoint: "checkpoint-2"
             })

    updated = Repo.get!(WatchChannel, watch_channel.id)
    assert updated.checkpoint == "checkpoint-2"
    assert updated.metadata["watch"]["checkpoint"] == "checkpoint-2"
  end

  test "resolve_watch_channel returns not found for unknown provider or channel" do
    config = insert_data_source_config()
    {:ok, _watch_channel} = DataSources.upsert_watch_channel(watch_attrs(config))

    assert {:error, :watch_channel_not_found} =
             DataSources.resolve_watch_channel(%{provider: "missing", channel_id: "channel-1"})

    assert {:error, :watch_channel_not_found} =
             DataSources.resolve_watch_channel(%{
               provider: "google_drive",
               channel_id: "missing"
             })
  end

  test "resolve_watch_channel requires exact target_source for non-changes lookup" do
    config = insert_data_source_config()

    {:ok, _watch_channel} =
      DataSources.upsert_watch_channel(
        watch_attrs(config, %{
          target_source: "data_source/google_drive/#{config.id}/folder-1",
          target_provider_id: "folder-1",
          target_kind: "collection"
        })
      )

    assert {:error, :watch_channel_not_found} =
             DataSources.resolve_watch_channel(%{
               provider: "google_drive",
               config_id: config.id,
               target_source: "data_source/google_drive/#{config.id}",
               target_provider_id: "folder-1"
             })
  end

  test "resolve_watch_channel filters numeric config_id strings and ignores invalid ids" do
    config = insert_data_source_config()

    other_config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Other Drive",
        provider: "slack",
        kind: "data_source",
        settings: %{}
      })
      |> Repo.insert!()

    {:ok, _older_watch_channel} =
      DataSources.upsert_watch_channel(
        watch_attrs(config, %{
          target_source: "data_source/google_drive/shared-target",
          target_provider_id: "folder-1",
          target_kind: "collection",
          channel_id: "channel-1"
        })
      )

    {:ok, newer_watch_channel} =
      DataSources.upsert_watch_channel(
        watch_attrs(config, %{
          config_id: other_config.id,
          target_source: "data_source/google_drive/shared-target",
          target_provider_id: "folder-1",
          target_kind: "collection",
          channel_id: "channel-2"
        })
      )

    {:ok, older_watch_channel} =
      DataSources.upsert_watch_channel(
        watch_attrs(config, %{
          target_source: "data_source/google_drive/shared-target",
          target_provider_id: "folder-1",
          target_kind: "collection",
          channel_id: "channel-1",
          checkpoint: "checkpoint-2"
        })
      )

    Repo.update_all(
      from(w in WatchChannel, where: w.id == ^newer_watch_channel.id),
      set: [updated_at: ~U[2026-01-01 00:00:00Z]]
    )

    Repo.update_all(
      from(w in WatchChannel, where: w.id == ^older_watch_channel.id),
      set: [updated_at: ~U[2026-01-02 00:00:00Z]]
    )

    assert {:ok, resolved} =
             DataSources.resolve_watch_channel(%{
               provider: "google_drive",
               config_id: Integer.to_string(config.id),
               target_source: "data_source/google_drive/shared-target",
               target_provider_id: "folder-1"
             })

    assert resolved.id == older_watch_channel.id

    assert {:ok, resolved} =
             DataSources.resolve_watch_channel(%{
               provider: "google_drive",
               config_id: "invalid",
               target_source: "data_source/google_drive/shared-target",
               target_provider_id: "folder-1"
             })

    assert resolved.id == older_watch_channel.id

    assert {:ok, resolved} =
             DataSources.resolve_watch_channel(%{
               provider: "google_drive",
               target_source: "data_source/google_drive/shared-target",
               target_provider_id: "folder-1"
             })

    assert resolved.id == older_watch_channel.id
  end

  test "resolve_watch_channel ignores blank resource filters" do
    config = insert_data_source_config()
    {:ok, watch_channel} = DataSources.upsert_watch_channel(watch_attrs(config))

    assert {:ok, resolved} =
             DataSources.resolve_watch_channel(%{
               provider: "google_drive",
               channel_id: "channel-1",
               resource_id: ""
             })

    assert resolved.id == watch_channel.id
  end

  test "mark_watch_channel_stopped clears last_error" do
    config = insert_data_source_config()

    {:ok, watch_channel} =
      DataSources.upsert_watch_channel(watch_attrs(config))

    assert {:ok, %WatchChannel{} = stopped} =
             DataSources.mark_watch_channel_stopped(watch_channel.id)

    assert stopped.status == "stopped"
  end

  test "mark_watch_channel_error returns not found for missing id" do
    assert {:error, :watch_channel_not_found} = DataSources.mark_watch_channel_error(-1, :boom)
  end

  test "process_watch_changes returns missing_watch_channel_id for empty request" do
    assert {:error, :missing_watch_channel_id} = DataSources.process_watch_changes(%{})
  end

  test "process_watch_changes marks ingestion errors and unexpected responses" do
    config = insert_data_source_config()

    with_engine_data_sources_env(StubIngestionErrorNodeRouter, System.get_global_base_url(), fn ->
      {:ok, watch_channel} =
        DataSources.upsert_watch_channel(
          watch_attrs(config, %{
            metadata: %{"watch" => %{checkpoint: "checkpoint-1"}}
          })
        )

      assert {:error, :ingestion_failed} =
               DataSources.process_watch_changes(%{
                 watch_channel_id: watch_channel.id,
                 checkpoint: "checkpoint-1",
                 signals: [%{"kind" => "signal"}],
                 records: [%{"id" => "record-1"}],
                 delivery: %{attempt: 1},
                 trigger_id: "trigger-1"
               })

      updated = Repo.get!(WatchChannel, watch_channel.id)
      assert updated.status == "error"
      assert updated.last_error == ":ingestion_failed"
    end)

    with_engine_data_sources_env(
      StubIngestionUnexpectedNodeRouter,
      System.get_global_base_url(),
      fn ->
        {:ok, watch_channel} =
          DataSources.upsert_watch_channel(
            watch_attrs(config, %{
              metadata: %{"watch" => %{checkpoint: "checkpoint-1"}}
            })
          )

        assert {:error, :unexpected_ingestion_response} =
                 DataSources.process_watch_changes(%{
                   watch_channel_id: watch_channel.id,
                   checkpoint: "checkpoint-1"
                 })

        updated = Repo.get!(WatchChannel, watch_channel.id)
        assert updated.status == "error"
        assert updated.last_error == ":unexpected_ingestion_response"
      end
    )
  end

  test "process_watch_changes keeps checkpoint unchanged when no next_checkpoint is given" do
    config = insert_data_source_config()

    with_engine_data_sources_env(StubIngestionOkNodeRouter, System.get_global_base_url(), fn ->
      {:ok, watch_channel} =
        DataSources.upsert_watch_channel(
          watch_attrs(config, %{
            checkpoint: "checkpoint-1",
            metadata: %{"watch" => %{checkpoint: "checkpoint-1"}}
          })
        )

      target_source = "data_source/google_drive/#{config.id}/folder-1"
      config_id = config.id

      assert {:ok, :ok} =
               DataSources.process_watch_changes(%{
                 watch_channel_id: watch_channel.id,
                 checkpoint: "checkpoint-1",
                 signals: [%{"kind" => "signal"}],
                 records: [%{"id" => "record-1"}],
                 delivery: %{attempt: 1},
                 trigger_id: "trigger-1"
               })

      assert_receive {:ingestion_process_data_source_changes,
                      %{
                        provider: "google_drive",
                        config_id: ^config_id,
                        target_source: ^target_source,
                        target_provider_id: "folder-1",
                        target_kind: "collection",
                        signals: [%{"kind" => "signal"}],
                        records: [%{"id" => "record-1"}],
                        delivery: %{attempt: 1},
                        trigger_id: "trigger-1"
                      }}

      updated = Repo.get!(WatchChannel, watch_channel.id)
      assert updated.checkpoint == "checkpoint-1"
      assert updated.status == "active"
      assert updated.last_error == nil
    end)
  end

  test "renew_watch_channel returns :ok for stopped or errored channels and keeps row" do
    config = insert_data_source_config()

    Enum.each(["stopped", "error"], fn status ->
      with_engine_data_sources_env(StubRenewalNodeRouter, "https://renewed.example/base/", fn ->
        Oban.Testing.with_testing_mode(:manual, fn ->
          {:ok, watch_channel} =
            DataSources.upsert_watch_channel(
              watch_attrs(config, %{
                status: status,
                target_source: "data_source/google_drive/#{config.id}",
                target_provider_id: "changes",
                target_kind: "collection",
                channel_id: "#{status}-channel",
                resource_id: "#{status}-resource",
                expiration_at: DateTime.utc_now() |> DateTime.add(3_600, :second),
                metadata: %{"watch" => %{}}
              })
            )

          assert :ok = DataSources.renew_watch_channel(watch_channel.id)
          assert Repo.get(WatchChannel, watch_channel.id)
        end)
      end)
    end)
  end

  test "renew_watch_channel rejects invalid upsert target_kind without scheduling renewal" do
    config = insert_data_source_config()

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:error, %Ecto.Changeset{} = changeset} =
               DataSources.upsert_watch_channel(
                 watch_attrs(config, %{
                   target_kind: "invalid",
                   expiration_at: DateTime.utc_now() |> DateTime.add(3_600, :second),
                   metadata: %{"watch" => %{}}
                 })
               )

      refute changeset.valid?
      assert [] = all_enqueued(worker: WatchChannelRenewalWorker)
    end)
  end

  test "renew_watch_channel returns replacement not persisted and missing channel id errors" do
    config = insert_data_source_config()

    with_engine_data_sources_env(
      StubRenewalWatchMissingChannelIdNodeRouter,
      "https://renewed.example/base/",
      fn ->
        Oban.Testing.with_testing_mode(:manual, fn ->
          {:ok, old_watch_channel} =
            DataSources.upsert_watch_channel(
              watch_attrs(config, %{
                target_source: "data_source/google_drive/#{config.id}",
                target_provider_id: "changes",
                target_kind: "collection",
                channel_id: "old-channel-missing",
                resource_id: "old-resource-missing",
                expiration_at: DateTime.utc_now() |> DateTime.add(3_600, :second),
                metadata: %{"watch" => %{}}
              })
            )

          assert {:error, :replacement_watch_channel_missing_channel_id} =
                   DataSources.renew_watch_channel(old_watch_channel.id)

          assert Repo.get(WatchChannel, old_watch_channel.id)
        end)
      end
    )

    with_engine_data_sources_env(
      StubRenewalWatchErrorNodeRouter,
      "https://renewed.example/base/",
      fn ->
        Oban.Testing.with_testing_mode(:manual, fn ->
          {:ok, old_watch_channel} =
            DataSources.upsert_watch_channel(
              watch_attrs(config, %{
                target_source: "data_source/google_drive/#{config.id}",
                target_provider_id: "changes",
                target_kind: "collection",
                channel_id: "old-channel-watch-error",
                resource_id: "old-resource-watch-error",
                expiration_at: DateTime.utc_now() |> DateTime.add(3_600, :second),
                metadata: %{"watch" => %{}}
              })
            )

          assert {:error, :watch_failed} = DataSources.renew_watch_channel(old_watch_channel.id)
          assert Repo.get(WatchChannel, old_watch_channel.id)
        end)
      end
    )

    with_engine_data_sources_env(
      StubRenewalWatchUnexpectedNodeRouter,
      "https://renewed.example/base/",
      fn ->
        Oban.Testing.with_testing_mode(:manual, fn ->
          {:ok, old_watch_channel} =
            DataSources.upsert_watch_channel(
              watch_attrs(config, %{
                target_source: "data_source/google_drive/#{config.id}",
                target_provider_id: "changes",
                target_kind: "collection",
                channel_id: "old-channel-watch-unexpected",
                resource_id: "old-resource-watch-unexpected",
                expiration_at: DateTime.utc_now() |> DateTime.add(3_600, :second),
                metadata: %{"watch" => %{}}
              })
            )

          assert {:error, :unexpected_watch_response} =
                   DataSources.renew_watch_channel(old_watch_channel.id)

          assert Repo.get(WatchChannel, old_watch_channel.id)
        end)
      end
    )

    with_engine_data_sources_env(
      StubRenewalUnwatchErrorNodeRouter,
      "https://renewed.example/base/",
      fn ->
        Oban.Testing.with_testing_mode(:manual, fn ->
          {:ok, old_watch_channel} =
            DataSources.upsert_watch_channel(
              watch_attrs(config, %{
                target_source: "data_source/google_drive/#{config.id}",
                target_provider_id: "changes",
                target_kind: "collection",
                channel_id: "old-channel-unwatch-error",
                resource_id: "old-resource-unwatch-error",
                expiration_at: DateTime.utc_now() |> DateTime.add(3_600, :second),
                metadata: %{"watch" => %{}}
              })
            )

          assert {:error, :unwatch_failed} = DataSources.renew_watch_channel(old_watch_channel.id)
          assert Repo.get(WatchChannel, old_watch_channel.id)
        end)
      end
    )

    with_engine_data_sources_env(
      StubRenewalUnwatchUnexpectedNodeRouter,
      "https://renewed.example/base/",
      fn ->
        Oban.Testing.with_testing_mode(:manual, fn ->
          {:ok, old_watch_channel} =
            DataSources.upsert_watch_channel(
              watch_attrs(config, %{
                target_source: "data_source/google_drive/#{config.id}",
                target_provider_id: "changes",
                target_kind: "collection",
                channel_id: "old-channel-unwatch-unexpected",
                resource_id: "old-resource-unwatch-unexpected",
                expiration_at: DateTime.utc_now() |> DateTime.add(3_600, :second),
                metadata: %{"watch" => %{}}
              })
            )

          assert {:error, :unexpected_unwatch_response} =
                   DataSources.renew_watch_channel(old_watch_channel.id)

          assert Repo.get(WatchChannel, old_watch_channel.id)
        end)
      end
    )
  end

  describe "WatchChannelRenewalWorker.perform/1" do
    test "successful renewal returns ok and swaps the watch channel" do
      config = insert_data_source_config()

      with_engine_data_sources_env(StubRenewalNodeRouter, "https://renewed.example/base/", fn ->
        Oban.Testing.with_testing_mode(:manual, fn ->
          {:ok, old_watch_channel} =
            DataSources.upsert_watch_channel(
              watch_attrs(config, %{
                target_source: "data_source/google_drive/#{config.id}",
                target_provider_id: "changes",
                target_kind: "collection",
                channel_id: "old-channel-1",
                resource_id: "old-resource-1",
                expiration_at: DateTime.utc_now() |> DateTime.add(3_600, :second),
                metadata: %{"watch" => %{}}
              })
            )

          target_source = "data_source/google_drive/#{config.id}"
          config_id = config.id

          assert :ok =
                   perform_job(WatchChannelRenewalWorker, %{
                     watch_channel_id: old_watch_channel.id
                   })

          assert Repo.get(WatchChannel, old_watch_channel.id) == nil

          assert %WatchChannel{channel_id: "new-channel-1"} =
                   Repo.get_by!(WatchChannel,
                     provider: "google_drive",
                     channel_id: "new-channel-1"
                   )

          assert_received {:renewal_watch_item,
                           %{
                             provider: "google_drive",
                             params: %{
                               force_new_watch_channel: true,
                               target_source: ^target_source,
                               config_id: ^config_id,
                               target_provider_id: "changes"
                             }
                           }}

          assert_received {:renewal_unwatch_item,
                           %{
                             provider: "google_drive",
                             params: %{
                               channel_id: "old-channel-1",
                               resource_id: "old-resource-1"
                             }
                           }}
        end)
      end)
    end

    test "inactive or stopped renewal jobs no-op" do
      config = insert_data_source_config()

      with_engine_data_sources_env(StubRenewalNodeRouter, "https://renewed.example/base/", fn ->
        Oban.Testing.with_testing_mode(:manual, fn ->
          Enum.each(["stopped", "error"], fn status ->
            {:ok, watch_channel} =
              DataSources.upsert_watch_channel(
                watch_attrs(config, %{
                  status: status,
                  target_source: "data_source/google_drive/#{config.id}",
                  target_provider_id: "changes",
                  target_kind: "collection",
                  channel_id: "#{status}-channel",
                  resource_id: "#{status}-resource",
                  expiration_at: DateTime.utc_now() |> DateTime.add(3_600, :second),
                  metadata: %{"watch" => %{}}
                })
              )

            assert :ok =
                     perform_job(WatchChannelRenewalWorker, %{watch_channel_id: watch_channel.id})

            assert Repo.get(WatchChannel, watch_channel.id)
          end)

          refute_received {:renewal_watch_item, _}
          refute_received {:renewal_unwatch_item, _}
        end)
      end)
    end

    test "missing channel id jobs no-op" do
      assert :ok = perform_job(WatchChannelRenewalWorker, %{watch_channel_id: -1})
    end

    test "missing global base url returns error" do
      config = insert_data_source_config()

      with_engine_data_sources_env(StubRenewalNodeRouter, nil, fn ->
        Oban.Testing.with_testing_mode(:manual, fn ->
          {:ok, old_watch_channel} =
            DataSources.upsert_watch_channel(
              watch_attrs(config, %{
                target_source: "data_source/google_drive/#{config.id}",
                target_provider_id: "changes",
                target_kind: "collection",
                channel_id: "old-channel-no-base-url",
                resource_id: "old-resource-no-base-url",
                expiration_at: DateTime.utc_now() |> DateTime.add(3_600, :second),
                metadata: %{"watch" => %{}}
              })
            )

          assert {:error, :missing_global_base_url} =
                   perform_job(WatchChannelRenewalWorker, %{
                     watch_channel_id: old_watch_channel.id
                   })

          assert Repo.get(WatchChannel, old_watch_channel.id)
        end)
      end)
    end

    test "malformed jobs are ignored" do
      assert :ok = WatchChannelRenewalWorker.perform(%Oban.Job{args: %{}})
    end
  end

  test "upsert_watch_channel keeps non-map metadata empty" do
    config = insert_data_source_config()

    {:ok, watch_channel} =
      DataSources.upsert_watch_channel(watch_attrs(config, %{metadata: "legacy"}))

    assert watch_channel.metadata == %{}
  end

  test "upsert_watch_channel stringifies integer fields and ignores unsupported last_error" do
    config = insert_data_source_config()

    {:ok, watch_channel} =
      DataSources.upsert_watch_channel(%{
        config_id: config.id,
        provider: :google_drive,
        target_source: 123,
        target_provider_id: 456,
        target_kind: :collection,
        channel_id: 789,
        resource_id: 101_112,
        resource_uri: 131_415,
        checkpoint: 161_718,
        last_error: %{unsupported: true},
        metadata: %{"watch" => %{}}
      })

    assert watch_channel.provider == "google_drive"
    assert watch_channel.target_source == "123"
    assert watch_channel.target_provider_id == "456"
    assert watch_channel.channel_id == "789"
    assert watch_channel.resource_id == "101112"
    assert watch_channel.resource_uri == "131415"
    assert watch_channel.checkpoint == "161718"
    assert watch_channel.last_error == nil
  end

  test "upsert_watch_channel parses integer and ISO8601 expirations" do
    config = insert_data_source_config()

    {:ok, seconds_watch_channel} =
      DataSources.upsert_watch_channel(
        watch_attrs(config, %{expiration_at: 1_700_000_000, metadata: %{"watch" => %{}}})
      )

    assert %DateTime{} = seconds_watch_channel.expiration_at
    assert DateTime.to_unix(seconds_watch_channel.expiration_at) == 1_700_000_000

    {:ok, milliseconds_watch_channel} =
      DataSources.upsert_watch_channel(
        watch_attrs(config, %{
          channel_id: "channel-ms",
          expiration_at: 1_700_000_000_000,
          metadata: %{"watch" => %{}}
        })
      )

    assert %DateTime{} = milliseconds_watch_channel.expiration_at

    assert DateTime.to_unix(milliseconds_watch_channel.expiration_at) ==
             div(1_700_000_000_000, 1_000)

    {:ok, iso_watch_channel} =
      DataSources.upsert_watch_channel(
        watch_attrs(config, %{
          channel_id: "channel-iso",
          expiration_at: "2026-07-22T12:34:56Z",
          metadata: %{"watch" => %{}}
        })
      )

    assert DateTime.to_iso8601(iso_watch_channel.expiration_at) == "2026-07-22T12:34:56Z"

    {:ok, invalid_iso_watch_channel} =
      DataSources.upsert_watch_channel(
        watch_attrs(config, %{
          channel_id: "channel-invalid-iso",
          expiration_at: "not-an-iso8601-date",
          metadata: %{"watch" => %{}}
        })
      )

    assert invalid_iso_watch_channel.expiration_at == nil
  end

  test "upsert_watch_channel preserves other metadata and rebuilds watch metadata when existing watch is not a map" do
    config = insert_data_source_config()

    {:ok, watch_channel} =
      DataSources.upsert_watch_channel(
        watch_attrs(config, %{
          metadata: %{"watch" => "legacy", "other" => "keep-me"}
        })
      )

    assert watch_channel.metadata["other"] == "keep-me"
    assert watch_channel.metadata["watch"]["provider"] == "google_drive"
    assert watch_channel.metadata["watch"]["channel_id"] == "channel-1"
    assert watch_channel.metadata["watch"]["kind"] == "collection"
  end
end
