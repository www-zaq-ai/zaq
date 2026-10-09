defmodule Zaq.Engine.WidgetConnectorSettingsTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.AccountsFixtures
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Engine.Api
  alias Zaq.Engine.{ChannelConfig, IncomingMessageRouting, WidgetConnectorSettings}
  alias Zaq.Event
  alias Zaq.SystemConfigFixtures

  defmodule Router do
    def dispatch(%Event{opts: opts} = event) do
      response =
        case opts[:action] do
          :widget_adapter_setup -> {:ok, %{available?: true, runtime: :disabled}}
          :sync_channel_runtime -> :ok
        end

      %{event | response: response}
    end
  end

  defmodule UnavailableRouter do
    def dispatch(event), do: %{event | response: {:error, :unavailable}}
  end

  defmodule PendingRouter do
    def dispatch(%Event{opts: opts} = event) do
      if opts[:action] == :sync_channel_runtime,
        do: %{event | response: {:error, %{secret: "internal failure"}}},
        else: Router.dispatch(event)
    end
  end

  @opts [node_router: Router]

  test "new settings default, roundtrip and partial edits preserve custom policy" do
    {:ok, created} = save(:new, nil, %{"name" => "Defaults", "enabled" => false})
    selected = created.snapshot.selected
    assert selected.identity_issuer == "zaq_issuer"
    assert selected.identity_audience == "zaq_audience"
    assert selected.same_site == "None"
    assert Repo.get!(ChannelConfig, selected.id).settings["same_site"] == "None"

    {:ok, edited} =
      save(selected.id, selected.revision, %{
        "identity_issuer" => "custom_parent",
        "identity_audience" => "custom_widget",
        "same_site" => "Strict"
      })

    selected = edited.snapshot.selected
    {:ok, renamed} = save(selected.id, selected.revision, %{"name" => "Renamed"})
    assert renamed.snapshot.selected.identity_issuer == "custom_parent"
    assert renamed.snapshot.selected.identity_audience == "custom_widget"
    assert renamed.snapshot.selected.same_site == "Strict"
  end

  test "legacy omitted settings stay omitted on unrelated saves" do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Legacy",
        provider: "web_widget",
        kind: "retrieval",
        enabled: false,
        settings: %{}
      })
      |> Repo.insert!()

    {:ok, snapshot} = WidgetConnectorSettings.execute(%{op: :snapshot, id: config.id}, @opts)
    assert snapshot.selected.identity_issuer == nil
    assert snapshot.selected.same_site == nil
    {:ok, _} = save(config.id, snapshot.selected.revision, %{"name" => "Legacy renamed"})
    assert Repo.get!(ChannelConfig, config.id).settings == %{}
  end

  test "invalid issuer, audience and cookie policy never persist" do
    for {key, value} <- [
          {"identity_issuer", ""},
          {"identity_audience", nil},
          {"same_site", "none"}
        ] do
      assert {:error, {:validation, _}} =
               save(:new, nil, %{"name" => "Invalid", "enabled" => false, key => value})
    end

    assert ChannelConfig.list_by_provider("web_widget") == []
  end

  test "disabled creation returns only a secret-free configuration snapshot" do
    assert {:ok, result} = save(:new, nil, %{"name" => "Support", "enabled" => false})
    config = result.snapshot.selected
    assert config.widget_id == config.id
    refute config.key_present?
    refute Map.has_key?(config, :token)
    assert Repo.get!(ChannelConfig, config.id).provider == "web_widget"
  end

  test "generation stores ciphertext and reveals once, rotation rejects stale revisions" do
    {:ok, created} = save(:new, nil, %{"name" => "Support", "enabled" => false})
    initial = created.snapshot.selected

    assert {:ok, generated} =
             WidgetConnectorSettings.execute(
               %{op: :generate_key, id: initial.id, revision: initial.revision},
               @opts
             )

    key = generated.authentication_key
    assert byte_size(key) >= 43
    stored = Repo.query!("SELECT token FROM channel_configs WHERE id = $1", [initial.id]).rows
    assert [[ciphertext]] = stored
    assert String.starts_with?(ciphertext, "enc:")
    refute ciphertext == key

    assert {:ok, snapshot} =
             WidgetConnectorSettings.execute(%{op: :snapshot, id: initial.id}, @opts)

    refute Map.has_key?(snapshot, :authentication_key)
    assert snapshot.selected.key_present?
    refute inspect(snapshot) =~ key

    assert {:error, :stale_connector} =
             WidgetConnectorSettings.execute(
               %{op: :rotate_key, id: initial.id, revision: initial.revision},
               @opts
             )

    assert {:ok, rotated} =
             WidgetConnectorSettings.execute(
               %{op: :rotate_key, id: initial.id, revision: snapshot.selected.revision},
               @opts
             )

    refute rotated.authentication_key == key
    assert rotated.snapshot.selected.key_rotated_at
    refute inspect(rotated.snapshot) =~ rotated.authentication_key
  end

  test "forged fields and wrong or archived connector IDs fail closed" do
    assert {:error, :invalid_request} =
             save(:new, nil, %{"name" => "Bad", "token" => "chosen", "enabled" => false})

    {:ok, created} = save(:new, nil, %{"name" => "Support", "enabled" => false})
    config = Repo.get!(ChannelConfig, created.snapshot.selected.id)
    {:ok, _} = ChannelConfig.archive(config)

    assert {:error, :connector_not_found} =
             WidgetConnectorSettings.execute(%{op: :snapshot, id: config.id}, @opts)

    assert {:error, :connector_not_found} =
             WidgetConnectorSettings.execute(%{op: :snapshot, id: -1}, @opts)
  end

  test "routing NONE and clear are owned by IncomingMessageRouting" do
    {:ok, created} =
      save(:new, nil, %{"name" => "Support", "enabled" => false, "agent_id" => "__none__"})

    config = created.snapshot.selected
    assert IncomingMessageRouting.get_rule(%{channel_config_id: config.id}).routing_mode == :none
    assert config.agent_id == "__none__"

    assert {:ok, _} =
             save(config.id, config.revision, %{
               "name" => "Support",
               "enabled" => false,
               "agent_id" => ""
             })

    assert IncomingMessageRouting.get_rule(%{channel_config_id: config.id}) == nil
  end

  test "a conversation-enabled agent is persisted as a connector routing rule, not settings" do
    credential = SystemConfigFixtures.ai_credential_fixture()

    agent =
      %ConfiguredAgent{}
      |> ConfiguredAgent.changeset(%{
        name: "Widget agent",
        job: "Answer questions",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        conversation_enabled: true,
        active: true
      })
      |> Repo.insert!()

    assert {:ok, created} =
             save(:new, nil, %{
               "name" => "Support",
               "enabled" => false,
               "agent_id" => to_string(agent.id)
             })

    config = created.snapshot.selected
    assert config.agent_id == to_string(agent.id)
    rule = IncomingMessageRouting.get_rule(%{channel_config_id: config.id})
    assert rule.configured_agent_id == agent.id
    assert rule.routing_mode == :agent
    refute Map.has_key?(Repo.get!(ChannelConfig, config.id).settings, "agent_id")
  end

  property "untrusted configuration fields cannot become persisted options or secrets" do
    check all(suffix <- string(:alphanumeric, min_length: 1, max_length: 20)) do
      assert {:error, :invalid_request} =
               save(:new, nil, %{
                 "name" => "Support",
                 "enabled" => false,
                 "untrusted_#{suffix}" => "chosen"
               })

      assert ChannelConfig.list_by_provider("web_widget") == []
    end
  end

  test "enabling requires configured global base_url" do
    assert :ok = Zaq.System.set_global_base_url(nil)

    for value <- [true, "true", "1"] do
      assert {:error, :missing_global_base_url} =
               save(:new, nil, %{"name" => "Support", "enabled" => value})
    end

    assert {:error, :invalid_request} = save(:new, nil, %{"name" => "Support", "enabled" => 1})
  end

  test "schema persistence cannot bypass the base_url prerequisite" do
    assert :ok = Zaq.System.set_global_base_url(nil)

    changeset =
      ChannelConfig.changeset(%ChannelConfig{}, %{
        name: "Direct widget",
        provider: "web_widget",
        kind: "retrieval",
        enabled: true
      })

    assert {:error, invalid} = Repo.insert(changeset)
    assert {"configure the global base URL before enabling", metadata} = invalid.errors[:enabled]
    assert metadata[:validation] == :missing_global_base_url
    assert ChannelConfig.list_by_provider("web_widget") == []
  end

  test "authenticated confidential events use the validated management Action" do
    user = AccountsFixtures.admin_fixture(%{must_change_password: false})

    event =
      Event.new(
        %{op: :save, id: :new, params: %{"name" => "Admin widget", "enabled" => false}},
        :engine,
        actor: %{user_id: user.id},
        opts: [confidential: true, node_router: Router]
      )

    assert {:ok, %{snapshot: %{selected: %{name: "Admin widget"}}}} =
             Api.handle_event(event, :widget_connector_settings, %{}).response

    assert {:error, :unauthorized} =
             Api.handle_event(%{event | opts: []}, :widget_connector_settings, %{}).response
  end

  test "enabling requires adapter support and does not create a failed configuration" do
    assert :ok = Zaq.System.set_global_base_url("https://zaq.example.test")

    assert {:error, :widget_runtime_not_configured} =
             WidgetConnectorSettings.execute(
               %{op: :save, id: :new, params: %{"name" => "Bad", "enabled" => true}},
               node_router: UnavailableRouter
             )

    assert ChannelConfig.list_by_provider("web_widget") == []
  end

  test "invalid routing rolls back connector creation and stale edits do not change it" do
    assert {:error, :invalid_agent} =
             save(:new, nil, %{"name" => "Bad", "enabled" => false, "agent_id" => "not-an-id"})

    assert ChannelConfig.list_by_provider("web_widget") == []
    {:ok, created} = save(:new, nil, %{"name" => "Original", "enabled" => false})
    config = created.snapshot.selected
    {:ok, edited} = save(config.id, config.revision, %{"name" => "Changed"})
    assert {:error, :stale_connector} = save(config.id, config.revision, %{"name" => "Stale"})
    assert edited.snapshot.selected.name == "Changed"
    assert Repo.get!(ChannelConfig, config.id).name == "Changed"
  end

  test "post-save runtime errors are bounded warnings without rolling back" do
    assert {:ok, result} =
             WidgetConnectorSettings.execute(
               %{op: :save, id: :new, params: %{"name" => "Support", "enabled" => false}},
               node_router: PendingRouter
             )

    assert result.runtime == {:pending, :runtime_sync_failed}
    refute inspect(result) =~ "internal failure"
    assert Repo.get!(ChannelConfig, result.snapshot.selected.id)
  end

  test "missing authentication and non-confidential events never reach management" do
    for opts <- [[], [confidential: true]] do
      event = Event.new(%{op: :snapshot}, :engine, opts: opts)

      assert {:error, :unauthorized} =
               Api.handle_event(event, :widget_connector_settings, %{}).response
    end
  end

  defp save(id, revision, params) do
    WidgetConnectorSettings.execute(
      %{op: :save, id: id, revision: revision, params: params},
      @opts
    )
  end
end
