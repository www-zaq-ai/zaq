defmodule Zaq.Engine.EmailConnectorSettingsApiTest do
  use Zaq.DataCase, async: true

  import Mox
  import Zaq.AccountsFixtures

  alias Zaq.Engine.Api
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Event

  defmodule RuntimeRouterContract do
    @callback dispatch(map()) :: map()
  end

  Mox.defmock(__MODULE__.RuntimeRouter, for: RuntimeRouterContract)
  alias __MODULE__.RuntimeRouter

  setup :verify_on_exit!

  test "Engine authorizes confidential snapshots and saves then sends exact runtime config" do
    admin = current_admin()
    actor = %{user_id: admin.id}
    event = settings_event(%{op: :snapshot, provider: "email:smtp"}, actor)

    assert %{response: {:ok, %{provider: "email:smtp"}}} =
             Api.handle_event(event, :email_connector_settings, nil)

    event =
      settings_event(
        %{op: :save, provider: "email:smtp", selected_config_id: :new, params: smtp_params()},
        actor
      )

    event = %{event | opts: Keyword.put(event.opts, :node_router, RuntimeRouter)}
    caller = self()

    expect(RuntimeRouter, :dispatch, fn runtime_event ->
      send(caller, {:email_runtime_event, runtime_event})
      %{runtime_event | response: :ok}
    end)

    assert %{response: {:ok, %{selected_config_id: id, runtime: :synced}}} =
             Api.handle_event(event, :email_connector_settings, nil)

    assert Repo.get!(ChannelConfig, id).name == "Engine SMTP"

    assert_received {:email_runtime_event,
                     %Event{request: %{config: %{id: ^id, provider: "email:smtp"}}, opts: opts}}

    assert opts[:confidential] == true
    assert opts[:action] == :sync_provider_runtime
  end

  test "snapshots, writes and defaults reject missing or invalid trusted actor" do
    for request <- [
          %{op: :snapshot, provider: "email:smtp"},
          %{op: :save, provider: "email:smtp", selected_config_id: :new, params: smtp_params()},
          %{op: :set_default, id: 42}
        ],
        actor <- [%{}, %{user_id: -1}] do
      assert %{response: {:error, _}} =
               Api.handle_event(settings_event(request, actor), :email_connector_settings, nil)
    end

    refute Repo.get_by(ChannelConfig, name: "Engine SMTP")
    refute_received {:email_runtime_event, _}
  end

  test "even a current BO user cannot expose settings through a nonconfidential event" do
    admin = current_admin()
    event = settings_event(%{op: :snapshot, provider: "email:smtp"}, %{user_id: admin.id})
    event = %{event | opts: [action: :email_connector_settings]}

    assert %{response: {:error, :confidential_event_required}} =
             Api.handle_event(event, :email_connector_settings, nil)
  end

  test "Engine rechecks password-blocked users and owns notification-default persistence" do
    admin = current_admin()

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Default SMTP",
        provider: "email:smtp",
        kind: "retrieval",
        enabled: true,
        url: "smtp://configured-in-settings",
        token: "__smtp_unused__",
        settings: %{"relay" => "smtp.example.com"}
      })
      |> Repo.insert!()

    event = settings_event(%{op: :set_default, id: config.id}, %{user_id: admin.id})
    assert %{response: {:ok, _}} = Api.handle_event(event, :email_connector_settings, nil)
    assert Repo.get!(ChannelConfig, config.id).notification_default

    admin |> Ecto.Changeset.change(must_change_password: true) |> Repo.update!()

    assert %{response: {:error, :confidential_event_required}} =
             Api.handle_event(event, :email_connector_settings, nil)
  end

  defp settings_event(request, actor) do
    Event.new(request, :engine,
      actor: actor,
      opts: [action: :email_connector_settings, confidential: true]
    )
  end

  defp current_admin do
    super_admin_fixture()
    |> Ecto.Changeset.change(must_change_password: false)
    |> Repo.update!()
  end

  defp smtp_params do
    %{
      "connector_name" => "Engine SMTP",
      "enabled" => "false",
      "relay" => "smtp.example.com",
      "port" => "587",
      "transport_mode" => "starttls",
      "tls" => "enabled",
      "tls_verify" => "verify_peer",
      "from_email" => "noreply@example.com",
      "from_name" => "ZAQ",
      "password" => "secret"
    }
  end
end
