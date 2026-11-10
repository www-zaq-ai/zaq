defmodule Zaq.Engine.LiveUpdateSettingsTest do
  use Zaq.DataCase, async: true

  alias Zaq.AccountsFixtures
  alias Zaq.ConnectorConfig.LiveUpdates

  alias Zaq.Engine.{
    Api,
    ChannelConfig,
    ConnectorLifecycle,
    LiveUpdateSettings,
    WidgetConnectorSettings
  }

  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias ZaqWeb.Live.BO.Communication.ChannelConfigPersistence

  setup do
    user = AccountsFixtures.user_fixture(%{must_change_password: false})
    %{actor: %{user_id: user.id}}
  end

  test "a new connector with an explicit ID keeps its submitted policy on insert" do
    %{rows: [[id]]} =
      Repo.query!("SELECT nextval(pg_get_serial_sequence('channel_configs', 'id'))")

    settings = %{"live_updates" => %{"enabled" => false}, "unrelated" => "retained"}

    assert {:ok, config} =
             %ChannelConfig{id: id}
             |> ChannelConfig.changeset(%{
               name: "Preassigned connector",
               provider: "web_widget",
               kind: "retrieval",
               enabled: false,
               settings: settings
             })
             |> Repo.insert()

    assert config.id == id
    assert Repo.get!(ChannelConfig, id).settings == settings
  end

  test "management authenticates the actor and requires confidential dispatch", %{actor: actor} do
    config = connector()
    request = %{op: :snapshot, id: config.id}

    for {actor, opts} <- [{nil, [confidential: true]}, {actor, []}, {%{}, [confidential: true]}] do
      event = Event.new(request, :engine, actor: actor, opts: opts)

      assert %{response: {:error, :unauthorized}} =
               Api.handle_event(event, :manage_live_update_settings, %{})
    end

    assert {:ok, %{id: id, policy: policy}} = manage(request, actor)
    assert id == config.id
    assert policy == LiveUpdates.defaults()
  end

  test "save changes only the exact connector's policy and returns no unrelated settings", %{
    actor: actor
  } do
    first = connector(%{"unrelated" => %{"private" => "not-returned"}})
    second = connector()

    assert {:ok, %{policy: policy} = snapshot} =
             manage(%{op: :save, id: first.id, policy: %{"enabled" => "false"}}, actor)

    refute policy["enabled"]
    refute inspect(snapshot) =~ "not-returned"

    assert Repo.get!(ChannelConfig, first.id).settings == %{
             "live_updates" => policy,
             "unrelated" => %{"private" => "not-returned"}
           }

    assert Repo.get!(ChannelConfig, second.id).settings == %{}
    assert {:ok, %{policy: ^policy}} = manage(%{op: :save, id: first.id, policy: policy}, actor)
  end

  test "validation failures and invalid targets cannot mutate settings", %{actor: actor} do
    config = connector()
    before = Repo.get!(ChannelConfig, config.id)

    assert {:error, {:validation, %{"triggers" => _}}} =
             manage(
               %{op: :save, id: config.id, policy: %{"triggers" => %{"status" => true}}},
               actor
             )

    assert Repo.get!(ChannelConfig, config.id).settings == before.settings

    for id <- [nil, 0, -1, "invalid", config.id + 1_000_000] do
      assert {:error, :connector_not_found} = manage(%{op: :snapshot, id: id}, actor)
    end

    Repo.update!(Ecto.Changeset.change(config, archived_at: ~U[2026-11-02 00:00:00Z]))
    assert {:error, :connector_not_found} = manage(%{op: :snapshot, id: config.id}, actor)
    assert {:error, :invalid_request} = LiveUpdateSettings.execute(%{op: :other})
  end

  test "runtime resolution uses exact routing, not arbitrary metadata" do
    config = connector(%{"live_updates" => %{"enabled" => false}})

    incoming = %Incoming{
      content: "question",
      channel_id: "room",
      provider: :web_widget,
      routing_context: %{channel_config_id: config.id},
      metadata: %{live_updates: LiveUpdates.defaults(), channel_config_id: config.id + 1}
    }

    assert {:ok, policy} = resolve(incoming)
    refute policy["enabled"]

    assert {:error, :connector_not_found} = resolve(%{incoming | provider: :mattermost})

    assert {:error, :connector_not_found} =
             resolve(%{incoming | routing_context: %{channel_config_id: config.id + 1_000_000}})

    assert {:ok, defaults} =
             resolve(%Incoming{content: "question", channel_id: "bo", provider: :web})

    assert defaults == LiveUpdates.defaults()

    assert {:error, :connector_not_found} =
             resolve(%Incoming{content: "question", channel_id: "room", provider: :web_widget})
  end

  test "malformed stored policy returns an error rather than permissive defaults" do
    config = connector()
    Repo.update!(Ecto.Changeset.change(config, settings: %{"live_updates" => nil}))

    assert {:error, {:validation, _}} =
             resolve(%Incoming{
               content: "question",
               channel_id: "room",
               provider: :web_widget,
               routing_context: %{channel_config_id: config.id}
             })
  end

  test "runtime projection requires confidential identified execution, not a BO administrator" do
    incoming = %Incoming{content: "question", channel_id: "bo", provider: :web}
    event = Event.new(incoming, :engine, opts: [confidential: true])

    assert %{response: {:error, :unauthorized}} =
             Api.handle_event(event, :resolve_live_update_policy, %{})

    event = %{event | actor: %{person: %{id: 17}}, opts: []}

    assert %{response: {:error, :unauthorized}} =
             Api.handle_event(event, :resolve_live_update_policy, %{})

    assert {:ok, _policy} = resolve(incoming)
  end

  test "channel config validation rejects malformed managed policies" do
    changeset =
      ChannelConfig.changeset(connector(), %{
        settings: %{"live_updates" => %{"min_interval_ms" => 0}}
      })

    refute changeset.valid?
    assert %{settings: [_error]} = errors_on(changeset)
  end

  test "grouped connector save validates and atomically persists details and policy", %{
    actor: actor
  } do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Grouped connector",
        provider: "mattermost",
        kind: "retrieval",
        url: "https://example.test",
        token: "synthetic-test-token",
        enabled: false,
        settings: %{"unrelated" => "retained"}
      })
      |> Repo.insert!()

    {:ok, descriptor} = ConnectorLifecycle.context(config.id, config.provider, config.kind)

    request = %{
      op: :save_configuration,
      id: config.id,
      revision: descriptor.revision,
      params: %{"name" => "Grouped save"},
      policy: %{"enabled" => false}
    }

    assert {:error, {:validation, _}} =
             manage(%{request | policy: %{"min_interval_ms" => 0}}, actor)

    assert Repo.get!(ChannelConfig, config.id).name == config.name
    assert {:error, {:configuration, _}} = manage(%{request | params: %{"name" => ""}}, actor)
    assert Repo.get!(ChannelConfig, config.id).settings == config.settings
    assert {:ok, %{id: id}} = manage(request, actor)
    assert id == config.id
    saved = Repo.get!(ChannelConfig, config.id)
    assert saved.name == "Grouped save"
    refute saved.settings["live_updates"]["enabled"]
    assert saved.settings["unrelated"] == "retained"

    # Ordinary configuration edits retain ChannelConfig's loaded-token
    # re-encryption contract; the resolved credential itself must not change.
    assert ChannelConfig.to_runtime_config(saved).token == "synthetic-test-token"

    assert {:error, :stale_connector} = manage(request, actor)
  end

  test "native grouped editing cannot bypass widget-specific configuration validation", %{
    actor: actor
  } do
    config = connector()
    {:ok, descriptor} = ConnectorLifecycle.context(config.id, config.provider, config.kind)

    assert {:error, :invalid_request} =
             manage(
               %{
                 op: :save_configuration,
                 id: config.id,
                 revision: descriptor.revision,
                 params: %{"enabled" => true},
                 policy: %{"enabled" => false}
               },
               actor
             )

    refute Repo.get!(ChannelConfig, config.id).enabled
    assert Repo.get!(ChannelConfig, config.id).settings == config.settings
  end

  test "widget grouped save rolls back both ordinary fields and policy on invalid input" do
    config = connector()

    {:ok, %{selected: selected}} =
      WidgetConnectorSettings.execute(%{op: :snapshot, id: config.id})

    request = %{
      op: :save,
      id: config.id,
      revision: selected.revision,
      params: %{"name" => "Must not persist", "live_updates" => %{"min_interval_ms" => 0}}
    }

    assert {:error, {:validation, _}} = WidgetConnectorSettings.execute(request)
    assert Repo.get!(ChannelConfig, config.id).name == config.name
    assert Repo.get!(ChannelConfig, config.id).settings == config.settings
    request = %{request | params: %{"name" => "", "live_updates" => %{"enabled" => false}}}
    assert {:error, {:validation, _}} = WidgetConnectorSettings.execute(request)
    assert Repo.get!(ChannelConfig, config.id).settings == config.settings
  end

  test "stale ordinary forms cannot erase or roll back the current policy", %{actor: actor} do
    config = connector(%{"other" => "original"})

    for submitted <- [
          %{"other" => "edited"},
          %{"other" => "edited", "live_updates" => LiveUpdates.defaults()}
        ] do
      assert {:ok, %{policy: policy}} =
               manage(%{op: :save, id: config.id, policy: %{"enabled" => false}}, actor)

      assert {:ok, saved} =
               ChannelConfigPersistence.persist(
                 :edit,
                 config,
                 %{settings: submitted},
                 config.provider,
                 fn changeset, _provider -> changeset end
               )

      assert saved.settings["live_updates"] == policy
      assert saved.settings["other"] == "edited"
    end

    assert {:ok, _} =
             manage(%{op: :save, id: config.id, policy: %{"min_interval_ms" => 250}}, actor)

    assert Repo.get!(ChannelConfig, config.id).settings["other"] == "edited"
  end

  test "widget edits from an old snapshot preserve the policy", %{actor: actor} do
    config = connector()

    assert {:ok, %{selected: selected}} =
             WidgetConnectorSettings.execute(%{op: :snapshot, id: config.id})

    assert {:ok, %{policy: policy}} =
             manage(%{op: :save, id: config.id, policy: %{"enabled" => false}}, actor)

    assert {:error, :stale_connector} =
             WidgetConnectorSettings.execute(%{
               op: :save,
               id: config.id,
               revision: selected.revision,
               params: %{"name" => "Renamed"}
             })

    assert Repo.get!(ChannelConfig, config.id).settings["live_updates"] == policy
  end

  test "policy-only saves preserve encrypted connector tokens byte for byte", %{actor: actor} do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Credential preservation",
        provider: "mattermost",
        kind: "retrieval",
        url: "https://example.test",
        token: "synthetic-test-credential",
        enabled: false
      })
      |> Repo.insert!()

    before = Repo.query!("SELECT token FROM channel_configs WHERE id = $1", [config.id]).rows
    assert {:ok, _} = manage(%{op: :save, id: config.id, policy: %{"enabled" => false}}, actor)
    after_save = Repo.query!("SELECT token FROM channel_configs WHERE id = $1", [config.id]).rows
    assert after_save == before
    refute inspect(before) =~ "synthetic-test-credential"

    data_source = Repo.update!(Ecto.Changeset.change(config, kind: "data_source"))
    assert {:error, :connector_not_found} = manage(%{op: :snapshot, id: data_source.id}, actor)
  end

  test "revision transition is scoped to the policy write and stale enclosing forms cannot save",
       %{
         actor: actor
       } do
    config = connector()
    {:ok, previous} = ConnectorLifecycle.context(config.id, config.provider, config.kind)

    assert {:ok, %{previous_revision: before, revision: after_save}} =
             manage(
               %{
                 op: :save,
                 id: config.id,
                 policy: %{"enabled" => false},
                 revision: previous.revision
               },
               actor
             )

    assert before == previous.revision
    refute after_save == before

    assert {:error, :stale_connector} =
             manage(
               %{op: :save, id: config.id, policy: %{"enabled" => true}, revision: before},
               actor
             )

    refute Repo.get!(ChannelConfig, config.id).settings["live_updates"]["enabled"]
  end

  defp connector(settings \\ %{}) do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "Live update #{System.unique_integer([:positive])}",
      provider: "web_widget",
      kind: "retrieval",
      enabled: false,
      settings: settings
    })
    |> Repo.insert!()
  end

  defp manage(request, actor) do
    request
    |> Event.new(:engine, actor: actor, opts: [confidential: true])
    |> Api.handle_event(:manage_live_update_settings, %{})
    |> Map.fetch!(:response)
  end

  defp resolve(incoming) do
    incoming
    |> Event.new(:engine, actor: %{person: %{id: 17}}, opts: [confidential: true])
    |> Api.handle_event(:resolve_live_update_policy, %{})
    |> Map.fetch!(:response)
  end
end
