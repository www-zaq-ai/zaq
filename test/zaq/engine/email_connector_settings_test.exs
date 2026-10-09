defmodule Zaq.Engine.EmailConnectorSettingsTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  import StreamData

  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.EmailConnectorSettings
  alias Zaq.Event
  alias Zaq.Types.EncryptedString

  defmodule RuntimeStub do
    def dispatch(event) do
      send(self(), {:runtime_sync, event})
      %{event | response: Process.get(:runtime_result, :ok)}
    end
  end

  defmodule UnavailableRuntimeRouter do
    def dispatch(_event), do: exit(:nodedown)
  end

  defmodule ResponseRuntimeRouter do
    def dispatch(event) do
      send(self(), {:runtime_sync, event})
      %{event | response: {:ok, :applied}}
    end
  end

  defmodule RaisingRuntimeRouter do
    def dispatch(_event), do: raise("runtime dispatch failed")
  end

  defmodule NonEventRuntimeRouter do
    def dispatch(_event), do: :unavailable
  end

  test "snapshots default selection without creating or changing connectors" do
    Repo.delete_all(ChannelConfig)

    assert {:ok,
            %{
              provider: "email:smtp",
              configs: [],
              selected_config_id: :new,
              selected: %ChannelConfig{id: nil, provider: "email:smtp"}
            }} =
             EmailConnectorSettings.snapshot("email:smtp")

    connector = insert_config("email:smtp", "Existing SMTP")
    _second = insert_config("email:smtp", "Other SMTP")
    before = Repo.all(ChannelConfig)

    assert {:ok,
            %{
              provider: "email:smtp",
              selected_config_id: :new,
              selected: %ChannelConfig{id: nil, provider: "email:smtp"}
            }} =
             EmailConnectorSettings.snapshot("email:smtp", :new)

    assert {:error, :unsupported_provider} = EmailConnectorSettings.snapshot("unsupported", :new)
    assert {:error, :unsupported_provider} = EmailConnectorSettings.snapshot("unsupported")
    assert Enum.sort_by(Repo.all(ChannelConfig), & &1.id) == Enum.sort_by(before, & &1.id)
    assert Repo.get!(ChannelConfig, connector.id).name == "Existing SMTP"
  end

  test "rejects invalid save requests and missing selection without side effects" do
    before = Repo.all(ChannelConfig)

    for request <- [
          %{provider: "unsupported", selected_config_id: :new, params: %{}},
          %{provider: "email:smtp", selected_config_id: :new},
          %{provider: "email:smtp", selected_config_id: :new, params: "invalid"}
        ] do
      assert {:error, :invalid_request} =
               EmailConnectorSettings.save(request, node_router: RuntimeStub)

      refute_received {:runtime_sync, _}
    end

    assert {:error, :invalid_request} =
             EmailConnectorSettings.save(
               %{
                 provider: "email:smtp",
                 selected_config_id: :new,
                 params: smtp_params("Invalid options")
               },
               "not a keyword list"
             )

    assert {:error, :selection_required} =
             EmailConnectorSettings.save(
               %{
                 provider: "email:smtp",
                 selected_config_id: nil,
                 params: smtp_params("No selection")
               },
               node_router: RuntimeStub
             )

    assert Repo.all(ChannelConfig) == before
    refute_received {:runtime_sync, _}
  end

  test "synchronizes persisted SMTP settings with confidential event options" do
    assert {:ok, %{selected_config_id: id, runtime: :synced}} =
             EmailConnectorSettings.save(
               %{
                 provider: "email:smtp",
                 selected_config_id: :new,
                 params: smtp_params("Synced SMTP")
               },
               node_router: ResponseRuntimeRouter
             )

    assert Repo.get!(ChannelConfig, id).name == "Synced SMTP"
    saved = Repo.get!(ChannelConfig, id)
    assert saved.settings["password"] != "secret"
    assert {:ok, "secret"} = EncryptedString.decrypt(saved.settings["password"])

    assert_received {:runtime_sync,
                     %Event{
                       request: %{
                         config: %{
                           id: ^id,
                           provider: "email:smtp",
                           settings: %{"password" => "secret"}
                         }
                       },
                       opts: opts
                     }}

    assert opts[:confidential] == true
    assert opts[:action] == :sync_provider_runtime
  end

  test "runtime dispatch exceptions leave encrypted SMTP settings saved as pending" do
    assert {:ok, %{selected_config_id: id, runtime: {:pending, :runtime_sync_failed}}} =
             EmailConnectorSettings.save(
               %{
                 provider: "email:smtp",
                 selected_config_id: :new,
                 params: smtp_params("Raised SMTP")
               },
               node_router: RaisingRuntimeRouter
             )

    saved = Repo.get!(ChannelConfig, id)
    assert saved.settings["password"] != "secret"
    assert {:ok, "secret"} = EncryptedString.decrypt(saved.settings["password"])
  end

  test "non-Event runtime responses leave encrypted SMTP settings saved as unavailable" do
    assert {:ok, %{selected_config_id: id, runtime: {:pending, :channels_unavailable}}} =
             EmailConnectorSettings.save(
               %{
                 provider: "email:smtp",
                 selected_config_id: :new,
                 params: smtp_params("Unavailable SMTP")
               },
               node_router: NonEventRuntimeRouter
             )

    saved = Repo.get!(ChannelConfig, id)
    assert saved.name == "Unavailable SMTP"
    refute saved.settings["password"] == "secret"
    assert {:ok, "secret"} = EncryptedString.decrypt(saved.settings["password"])
  end

  test "rejects malformed connector ids and selects valid id controls" do
    connector = insert_config("email:smtp", "Selected SMTP")

    for invalid_id <- ["12x", "0", "-1", :not_an_id, []] do
      assert {:error, :connector_mismatch} =
               EmailConnectorSettings.snapshot("email:smtp", invalid_id)
    end

    assert {:ok, %{selected_config_id: id}} =
             EmailConnectorSettings.snapshot("email:smtp", connector.id)

    assert id == connector.id

    assert {:ok, %{selected: %{id: ^id}}} =
             EmailConnectorSettings.snapshot("email:smtp", Integer.to_string(connector.id))

    assert {:error, :invalid_smtp_connector} = EmailConnectorSettings.set_default_smtp("12x")
    assert {:error, :invalid_smtp_connector} = EmailConnectorSettings.set_default_smtp(:not_an_id)
  end

  property "malformed connector ids never select a connector" do
    connector = insert_config("email:smtp", "Property SMTP")

    malformed_id =
      one_of([
        integer(-100..0),
        map(integer(0..9_999), &"#{&1}x"),
        member_of([:not_an_id, :connector, :invalid_id])
      ])

    check all(id <- malformed_id, max_runs: 60) do
      refute id in [nil, :new]
      assert {:error, :connector_mismatch} = EmailConnectorSettings.snapshot("email:smtp", id)
      assert Repo.get!(ChannelConfig, connector.id).id == connector.id
    end
  end

  test "creates and updates only the explicitly selected SMTP connector" do
    assert {:ok, created} =
             EmailConnectorSettings.save(
               %{
                 provider: "email:smtp",
                 selected_config_id: :new,
                 params: smtp_params("Primary SMTP")
               },
               node_router: RuntimeStub
             )

    id = created.selected_config_id
    assert created.runtime == :synced

    assert_received {:runtime_sync,
                     %Event{
                       request: %{
                         config: %{
                           id: ^id,
                           provider: "email:smtp",
                           settings: %{"password" => "secret"}
                         }
                       },
                       opts: runtime_opts
                     }}

    assert runtime_opts[:confidential] == true
    assert Repo.get!(ChannelConfig, id).name == "Primary SMTP"

    other = insert_config("email:smtp", "Other SMTP")

    assert {:ok, updated} =
             EmailConnectorSettings.save(
               %{
                 provider: "email:smtp",
                 selected_config_id: id,
                 params: smtp_params("Renamed SMTP")
               },
               node_router: RuntimeStub
             )

    assert updated.selected_config_id == id
    assert Repo.get!(ChannelConfig, id).name == "Renamed SMTP"
    assert Repo.get!(ChannelConfig, other.id).name == "Other SMTP"
    assert_received {:runtime_sync, %Event{request: %{config: %{id: ^id, name: "Renamed SMTP"}}}}
  end

  test "rejects wrong-provider, archived and stale connector selections" do
    smtp = insert_config("email:smtp", "SMTP")
    archived = insert_config("email:imap", "Archived IMAP")
    {:ok, _} = ChannelConfig.archive(archived)

    assert {:error, :connector_mismatch} =
             EmailConnectorSettings.save(
               %{
                 provider: "email:imap",
                 selected_config_id: smtp.id,
                 params: %{}
               },
               node_router: RuntimeStub
             )

    assert {:error, :connector_mismatch} =
             EmailConnectorSettings.save(
               %{
                 provider: "email:imap",
                 selected_config_id: archived.id,
                 params: %{}
               },
               node_router: RuntimeStub
             )
  end

  test "reports saved settings when runtime synchronization is pending" do
    Process.put(:runtime_result, {:error, :runtime_down})

    assert {:ok, %{selected_config_id: id, runtime: {:pending, :runtime_down}}} =
             EmailConnectorSettings.save(
               %{
                 provider: "email:smtp",
                 selected_config_id: :new,
                 params: smtp_params("Pending SMTP")
               },
               node_router: RuntimeStub
             )

    assert Repo.get!(ChannelConfig, id).name == "Pending SMTP"
  end

  test "unreachable Channels does not undo saved configuration or expose runtime credentials" do
    assert {:ok, %{selected_config_id: id, runtime: {:pending, :channels_unavailable}}} =
             EmailConnectorSettings.save(
               %{
                 provider: "email:smtp",
                 selected_config_id: :new,
                 params: smtp_params("Offline SMTP")
               },
               node_router: UnavailableRuntimeRouter
             )

    saved = Repo.get!(ChannelConfig, id)
    assert saved.name == "Offline SMTP"
    refute saved.settings["password"] == "secret"
    assert {:ok, "secret"} = EncryptedString.decrypt(saved.settings["password"])
  end

  test "enabled IMAP requires one exact live SMTP binding when selection is ambiguous" do
    first = insert_config("email:smtp", "First")
    _second = insert_config("email:smtp", "Second")

    params = %{
      "connector_name" => "Inbox",
      "enabled" => "true",
      "url" => "imap.example.com",
      "username" => "inbox@example.com",
      "password" => "secret",
      "selected_mailboxes" => ["INBOX"]
    }

    assert {:error, :missing_smtp_binding} =
             EmailConnectorSettings.save(
               %{provider: "email:imap", selected_config_id: :new, params: params},
               node_router: RuntimeStub
             )

    assert {:ok, %{selected_config_id: id}} =
             EmailConnectorSettings.save(
               %{
                 provider: "email:imap",
                 selected_config_id: :new,
                 params: Map.put(params, "smtp_config_id", to_string(first.id))
               },
               node_router: RuntimeStub
             )

    assert get_in(Repo.get!(ChannelConfig, id).settings, ["imap", "smtp_config_id"]) == first.id
    assert_received {:runtime_sync, %Event{request: %{config: %{id: ^id, token: "secret"}}}}
  end

  defp smtp_params(name) do
    %{
      "connector_name" => name,
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

  defp insert_config(provider, name) do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: name,
      provider: provider,
      kind: "retrieval",
      enabled: provider != "email:imap",
      url: "https://example.invalid",
      token: "token",
      settings:
        if(provider == "email:imap",
          do: %{"imap" => %{"selected_mailboxes" => ["INBOX"], "smtp_config_id" => nil}},
          else: %{}
        )
    })
    |> Repo.insert!()
  end
end
