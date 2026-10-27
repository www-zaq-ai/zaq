defmodule Zaq.Engine.ChannelConfigTest do
  use Zaq.DataCase, async: false
  use ExUnitProperties

  alias Ecto.Changeset
  alias Zaq.ConnectorConfig.Settings

  alias Zaq.Channels.{AgentRouting, Bridge, DiskBridge, RetrievalChannel}
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Repo
  alias Zaq.System.SecretConfig
  alias Zaq.SystemConfigFixtures

  property "ordinary settings replacement preserves saved pairing metadata" do
    metadata = %{
      "owner_id" => 7,
      "account" => "paired-account",
      "pairing_attempt" => "attempt",
      "credential_document_id" => "binding"
    }

    saved = create_reply_policy_config!("whatsapp", metadata)

    check all(value <- string(:alphanumeric), enabled <- boolean(), max_runs: 20) do
      config = %{saved | enabled: enabled}
      changeset = ChannelConfig.changeset(config, %{settings: %{"custom" => value}})
      assert changeset.valid?
      settings = Changeset.get_field(changeset, :settings)
      assert Map.take(settings, Map.keys(metadata)) == metadata
      assert settings["custom"] == value
    end

    cleared = ChannelConfig.changeset(saved, %{settings: nil})
    assert cleared.valid?
    assert Map.take(Changeset.get_field(cleared, :settings), Map.keys(metadata)) == metadata
  end

  test "settings reject replacement of pairing identity and permit identical metadata" do
    metadata = %{
      "owner_id" => 7,
      "account" => "paired-account",
      "pairing_attempt" => "attempt",
      "credential_document_id" => "binding"
    }

    saved = create_reply_policy_config!("whatsapp", metadata)
    assert ChannelConfig.changeset(saved, %{settings: metadata}).valid?

    refute ChannelConfig.changeset(saved, %{settings: Map.put(metadata, :account, "replacement")}).valid?

    for key <- Map.keys(metadata),
        value <- [nil, "replacement"],
        representation <- [:string, :atom] do
      field = if representation == :atom, do: String.to_existing_atom(key), else: key
      changeset = ChannelConfig.changeset(saved, %{settings: %{field => value}})
      refute changeset.valid?
      assert {:error, _} = Repo.update(changeset)
      assert Repo.get!(ChannelConfig, saved.id).settings == saved.settings
    end

    legacy = create_reply_policy_config!("whatsapp", %{})
    refute ChannelConfig.changeset(legacy, %{settings: metadata}).valid?
    assert ChannelConfig.changeset(legacy, %{settings: %{"custom" => "allowed"}}).valid?
  end

  test "trusted adapter authentication supports multiple configurations without URL or token" do
    configs =
      for name <- ["WhatsApp Sales", "WhatsApp Support"] do
        assert {:ok, config} =
                 %ChannelConfig{}
                 |> ChannelConfig.changeset(
                   %{
                     name: name,
                     provider: "whatsapp",
                     kind: "retrieval",
                     enabled: false
                   },
                   adapter_authentication: true
                 )
                 |> Repo.insert()

        assert config.token == ""
        assert config.url == ""
        config
      end

    assert [first, second] = configs
    refute first.id == second.id
  end

  test "provider names and submitted authentication flags cannot bypass connection validation" do
    for provider <- ["whatsapp", "mattermost", "telegram"],
        flag <- [true, "true", false] do
      attrs = %{
        "name" => "Untrusted",
        "provider" => provider,
        "kind" => "retrieval",
        "adapter_authentication" => flag
      }

      assert {:error, changeset} = ChannelConfig.create(attrs)
      assert "can't be blank" in errors_on(changeset).url
      assert "can't be blank" in errors_on(changeset).token
    end
  end

  test "trusted adapter authentication is provider independent and supports saved edits" do
    for provider <- ["whatsapp", "mattermost"] do
      assert {:ok, saved} =
               ChannelConfig.create(
                 %{name: "Paired", provider: provider, kind: "retrieval"},
                 adapter_authentication: true
               )

      assert saved.url == ""
      assert saved.token == ""

      assert {:ok, updated} =
               saved
               |> ChannelConfig.changeset(%{name: "Renamed"}, adapter_authentication: true)
               |> Repo.update()

      assert updated.id == saved.id
      assert updated.name == "Renamed"
      assert updated.url == ""
      assert updated.token == ""
    end
  end

  # ── Token encryption ────────────────────────────────────────────────────

  test "token is stored encrypted in DB on insert" do
    config = insert_channel_config(%{token: "plaintext-token"})

    [[raw_token]] =
      Repo.query!("SELECT token FROM channel_configs WHERE id = $1", [config.id]).rows

    assert SecretConfig.encrypted?(raw_token),
           "expected DB value to be encrypted, got: #{inspect(raw_token)}"
  end

  test "loaded struct exposes decrypted token" do
    inserted = insert_channel_config(%{token: "my-secret"})
    loaded = Repo.get!(ChannelConfig, inserted.id)

    assert loaded.token == "my-secret"
  end

  test "updating loaded smtp config without token leaves token unchanged" do
    {:ok, smtp} =
      ChannelConfig.upsert_by_provider("email:smtp", %{
        name: "Email SMTP",
        kind: "retrieval",
        enabled: true,
        settings: %{"relay" => "smtp.example.com", "port" => "587"}
      })

    loaded = Repo.get!(ChannelConfig, smtp.id) |> Map.put(:token, nil)

    assert loaded.token == nil

    assert {:ok, updated} =
             loaded |> ChannelConfig.changeset(%{name: "Email SMTP Updated"}) |> Repo.update()

    assert updated.token == nil
  end

  test "update re-encrypts legacy plaintext token in DB" do
    # Write a plaintext token directly to simulate a legacy row
    {:ok, config} =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Legacy",
        provider: "mattermost",
        kind: "retrieval",
        url: "https://example.com",
        token: "legacy",
        enabled: true
      })
      |> Repo.insert()

    Repo.query!("UPDATE channel_configs SET token = 'legacy' WHERE id = $1", [config.id])

    # Reload and update without changing token
    loaded = Repo.get!(ChannelConfig, config.id)
    {:ok, _} = loaded |> ChannelConfig.changeset(%{name: "Updated"}) |> Repo.update()

    [[raw_token]] =
      Repo.query!("SELECT token FROM channel_configs WHERE id = $1", [config.id]).rows

    assert SecretConfig.encrypted?(raw_token),
           "expected token to be re-encrypted after update, got: #{inspect(raw_token)}"

    reloaded = Repo.get!(ChannelConfig, config.id)
    assert reloaded.token == "legacy"
  end

  test "update with new token encrypts the new value" do
    config = insert_channel_config(%{token: "old-token"})
    loaded = Repo.get!(ChannelConfig, config.id)

    {:ok, _} = loaded |> ChannelConfig.changeset(%{token: "new-token"}) |> Repo.update()

    [[raw_token]] =
      Repo.query!("SELECT token FROM channel_configs WHERE id = $1", [config.id]).rows

    assert SecretConfig.encrypted?(raw_token)
    reloaded = Repo.get!(ChannelConfig, config.id)
    assert reloaded.token == "new-token"
  end

  test "to_runtime_config/1 preserves non-binary token values in maps" do
    assert ChannelConfig.to_runtime_config(%{token: nil}) == %{token: nil}
    assert ChannelConfig.to_runtime_config(%{"token" => nil}) == %{"token" => nil}
  end

  test "to_runtime_config/1 logs encrypted token decryption failures" do
    invalid_token = "enc:v1:not-base64:not-base64:not-base64"

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert ChannelConfig.to_runtime_config(%{token: invalid_token}) == %{token: invalid_token}
      end)

    assert log =~ "Channel config token decryption failed"
  end

  test "insert returns changeset error when token encryption key is invalid" do
    previous_secret_config = Application.get_env(:zaq, Zaq.System.SecretConfig, [])

    Application.put_env(:zaq, Zaq.System.SecretConfig,
      encryption_key: "invalid",
      key_id: "test-v1"
    )

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.System.SecretConfig, previous_secret_config)
    end)

    changeset =
      ChannelConfig.changeset(%ChannelConfig{}, %{
        name: "Strict Failure",
        provider: "mattermost",
        kind: "retrieval",
        url: "https://example.com",
        token: "token-that-must-fail"
      })

    assert {:error, %Ecto.Changeset{} = failed_changeset} = Repo.insert(changeset)
    assert hd(errors_on(failed_changeset).token) =~ "could not be encrypted"
  end

  test "changeset returns generic error when token encryption fails unexpectedly" do
    with_encrypted_string_stub(fn ->
      changeset =
        ChannelConfig.changeset(%ChannelConfig{}, %{
          name: "Unexpected Encryption Failure",
          provider: "mattermost",
          kind: "retrieval",
          url: "https://example.com",
          token: "token-that-must-fail"
        })

      assert {:error, failed_changeset} = Repo.insert(changeset)
      assert hd(errors_on(failed_changeset).token) == "could not be encrypted"
    end)
  end

  test "changing a loaded config with a non-binary token does not encrypt it" do
    config = insert_channel_config(%{token: "existing-token"})
    loaded = Repo.get!(ChannelConfig, config.id) |> Map.put(:token, :unexpected)

    changeset = ChannelConfig.changeset(loaded, %{name: "Updated"})

    assert Ecto.Changeset.get_change(changeset, :token) == :unexpected
    refute Enum.any?(Map.get(errors_on(changeset), :token, []), &(&1 =~ "could not be encrypted"))
  end

  test "insert returns changeset error when token encryption key is missing" do
    previous_secret_config = Application.get_env(:zaq, Zaq.System.SecretConfig, [])
    Application.delete_env(:zaq, Zaq.System.SecretConfig)

    on_exit(fn ->
      Application.put_env(:zaq, Zaq.System.SecretConfig, previous_secret_config)
    end)

    changeset =
      ChannelConfig.changeset(%ChannelConfig{}, %{
        name: "Strict Failure Missing",
        provider: "mattermost",
        kind: "retrieval",
        url: "https://example.com",
        token: "token-that-must-fail"
      })

    assert {:error, %Ecto.Changeset{} = failed_changeset} = Repo.insert(changeset)

    assert hd(errors_on(failed_changeset).token) =~
             "could not be encrypted: missing SYSTEM_CONFIG_ENCRYPTION_KEY"
  end

  # ── Validation ──────────────────────────────────────────────────────────

  test "changeset/2 validates required fields and inclusion" do
    changeset = ChannelConfig.changeset(%ChannelConfig{}, %{provider: "unknown", kind: "bad"})

    refute changeset.valid?
    assert "can't be blank" in errors_on(changeset).name
    assert "can't be blank" in errors_on(changeset).url
    assert "can't be blank" in errors_on(changeset).token
    assert "is invalid" in errors_on(changeset).provider
    assert "is invalid" in errors_on(changeset).kind
  end

  test "data_source configs do not require url or token" do
    changeset =
      ChannelConfig.changeset(%ChannelConfig{}, %{
        name: "Google Drive source",
        provider: "google_drive",
        kind: "data_source",
        enabled: true,
        settings: %{"connect" => %{"credential_id" => "1"}}
      })

    assert changeset.valid?
    assert {:ok, _config} = Repo.insert(changeset)
  end

  # ── disk data source ────────────────────────────────────────────────────────

  describe "disk provider" do
    test "is an accepted provider" do
      changeset =
        ChannelConfig.changeset(%ChannelConfig{}, %{
          name: "Disk",
          provider: "disk",
          kind: "data_source",
          enabled: true,
          settings: disk_settings()
        })

      assert changeset.valid?
      refute Elixir.Map.has_key?(errors_on(changeset), :provider)
    end

    test "gets url and token placeholders rather than being required to supply them" do
      # The disk data source fronts volumes ZAQ already owns — there is nothing for an
      # operator to enter, but the row still has to exist for the bridge to be resolved.
      assert {:ok, config} =
               %ChannelConfig{}
               |> ChannelConfig.changeset(%{
                 name: "Disk",
                 provider: "disk",
                 kind: "data_source",
                 enabled: true,
                 settings: disk_settings()
               })
               |> Repo.insert()

      assert config.url == ""
      assert config.token == ""
    end

    test "keeps a url and token the caller did supply" do
      assert {:ok, config} =
               insert_disk_config()
               |> ChannelConfig.changeset(%{url: "https://example.test", token: "supplied"})
               |> Repo.update()

      assert config.url == "https://example.test"
      assert Repo.get!(ChannelConfig, config.id).token == "supplied"
    end

    test "its row is what Bridge.fetch_channel_config/1 finds" do
      insert_disk_config()

      assert {:ok, config} = Bridge.fetch_channel_config("disk")
      assert config.provider == "disk"
      assert config.kind == "data_source"
      assert config.enabled
    end

    test "resolves to the disk bridge" do
      assert {:ok, DiskBridge} = Bridge.resolve_bridge("disk")
    end

    defp insert_disk_config do
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Disk",
        provider: "disk",
        kind: "data_source",
        enabled: true,
        settings: disk_settings()
      })
      |> Repo.insert!()
    end

    test "requires at least one volume" do
      changeset =
        ChannelConfig.changeset(%ChannelConfig{}, %{
          name: "Disk",
          provider: "disk",
          kind: "data_source",
          enabled: true
        })

      refute changeset.valid?
      assert %{settings: ["at least one volume is required"]} = errors_on(changeset)
    end

    defp disk_settings, do: %{"volumes" => [%{"name" => "default", "path" => "."}]}
  end

  test "email:imap requires selected_mailboxes in settings" do
    changeset =
      ChannelConfig.changeset(%ChannelConfig{}, %{
        name: "Email IMAP",
        provider: "email:imap",
        kind: "retrieval",
        token: "imap-secret",
        enabled: false,
        settings: %{"imap" => %{"server" => "imap.example.com", "selected_mailboxes" => []}}
      })

    refute changeset.valid?

    assert "imap.selected_mailboxes must contain at least one mailbox" in errors_on(changeset).settings
  end

  test "email:imap rejects nil settings before mailbox normalization" do
    changeset =
      ChannelConfig.changeset(%ChannelConfig{}, %{
        name: "Email IMAP Nil Settings",
        provider: "email:imap",
        kind: "retrieval",
        token: "imap-secret",
        enabled: false,
        settings: nil
      })

    refute changeset.valid?
    assert "imap.selected_mailboxes is required" in errors_on(changeset).settings
  end

  test "email:imap rejects missing or malformed selected_mailboxes" do
    missing_selected_mailboxes =
      ChannelConfig.changeset(%ChannelConfig{}, %{
        name: "Email IMAP Missing",
        provider: "email:imap",
        kind: "retrieval",
        token: "imap-secret",
        enabled: false,
        settings: %{"imap" => %{"server" => "imap.example.com"}}
      })

    refute missing_selected_mailboxes.valid?
    assert "imap.selected_mailboxes is required" in errors_on(missing_selected_mailboxes).settings

    malformed_selected_mailboxes =
      ChannelConfig.changeset(%ChannelConfig{}, %{
        name: "Email IMAP Malformed",
        provider: "email:imap",
        kind: "retrieval",
        token: "imap-secret",
        enabled: false,
        settings: %{"imap" => %{"selected_mailboxes" => "INBOX"}}
      })

    refute malformed_selected_mailboxes.valid?

    assert "imap.selected_mailboxes is required" in errors_on(malformed_selected_mailboxes).settings

    non_map_settings =
      ChannelConfig.changeset(
        %ChannelConfig{provider: "email:imap", settings: :unexpected},
        %{
          name: "Email IMAP Non Map",
          kind: "retrieval",
          token: "imap-secret",
          enabled: false
        }
      )

    refute non_map_settings.valid?
    assert "imap.selected_mailboxes is required" in errors_on(non_map_settings).settings
  end

  test "email:imap dependency is enforced at persistence time" do
    changeset =
      ChannelConfig.changeset(%ChannelConfig{}, %{
        name: "Email IMAP",
        provider: "email:imap",
        kind: "retrieval",
        url: "imap.example.com",
        token: "imap-secret",
        enabled: true,
        settings: %{"imap" => %{"selected_mailboxes" => ["INBOX"]}}
      })

    assert changeset.valid?

    assert {:error, %Ecto.Changeset{} = failed_changeset} = Repo.insert(changeset)

    assert "email:imap requires an enabled email:smtp configuration" in errors_on(
             failed_changeset
           ).enabled
  end

  test "email:imap changeset is valid when smtp dependency is enabled" do
    assert {:ok, _smtp} =
             ChannelConfig.upsert_by_provider("email:smtp", %{
               name: "Email SMTP",
               kind: "retrieval",
               enabled: true,
               settings: %{"relay" => "smtp.example.com", "port" => "587"}
             })

    changeset =
      ChannelConfig.changeset(%ChannelConfig{}, %{
        name: "Email IMAP",
        provider: "email:imap",
        kind: "retrieval",
        token: "imap-secret",
        enabled: true,
        settings: %{"imap" => %{"selected_mailboxes" => ["INBOX", "Support"]}}
      })

    assert changeset.valid?
  end

  test "email:imap enabled persists when smtp dependency is enabled" do
    assert {:ok, _smtp} =
             ChannelConfig.upsert_by_provider("email:smtp", %{
               name: "Email SMTP",
               kind: "retrieval",
               enabled: true,
               settings: %{"relay" => "smtp.example.com", "port" => "587"}
             })

    changeset =
      ChannelConfig.changeset(%ChannelConfig{}, %{
        name: "Email IMAP",
        provider: "email:imap",
        kind: "retrieval",
        url: "imap.example.com",
        token: "imap-secret",
        enabled: true,
        settings: %{"imap" => %{"selected_mailboxes" => ["INBOX"]}}
      })

    assert {:ok, _config} = Repo.insert(changeset)
  end

  test "list_enabled_by_kind/2 returns only enabled configs for kind and known providers" do
    retrieval_enabled =
      insert_channel_config(%{provider: "mattermost", kind: "retrieval", enabled: true})

    _retrieval_disabled =
      insert_channel_config(%{provider: "slack", kind: "retrieval", enabled: false})

    _data_source_enabled =
      insert_channel_config(%{provider: "google_drive", kind: "data_source", enabled: true})

    _unknown_provider =
      insert_channel_config(%{provider: "discord", kind: "retrieval", enabled: true})

    assert [result] = ChannelConfig.list_enabled_by_kind(:retrieval, ["mattermost"])
    assert result.id == retrieval_enabled.id
  end

  test "list_enabled_by_kind/2 matches provider prefix before colon" do
    assert {:ok, smtp} =
             ChannelConfig.upsert_by_provider("email:smtp", %{
               name: "Email SMTP",
               kind: "retrieval",
               enabled: true,
               settings: %{"relay" => "smtp.example.com", "port" => "587"}
             })

    imap = upsert_imap_config(enabled: true, mailbox: "INBOX")

    result_ids =
      :retrieval
      |> ChannelConfig.list_enabled_by_kind(["email"])
      |> Enum.map(& &1.id)

    assert Enum.sort(result_ids) == Enum.sort([smtp.id, imap.id])
  end

  test "list_enabled_by_kind/2 excludes disabled provider-prefix matches" do
    _disabled_imap = upsert_imap_config(enabled: false, mailbox: "Archive")

    result_providers =
      :retrieval
      |> ChannelConfig.list_enabled_by_kind(["email"])
      |> Enum.map(& &1.provider)

    refute "email:imap" in result_providers
  end

  test "list_enabled_by_kind/2 excludes disabled configs without provider filter" do
    insert_channel_config(%{provider: "mattermost", kind: "retrieval", enabled: false})

    assert ChannelConfig.list_enabled_by_kind(:retrieval, nil) == []
  end

  test "list_incoming_routing_configs_for_platform/1 maps email to enabled imap config only" do
    assert {:ok, _smtp} =
             ChannelConfig.upsert_by_provider("email:smtp", %{
               name: "Email SMTP",
               kind: "retrieval",
               enabled: true,
               settings: %{"relay" => "smtp.example.com", "port" => "587"}
             })

    imap = upsert_imap_config(enabled: true, mailbox: "INBOX")

    result = ChannelConfig.list_incoming_routing_configs_for_platform("email")

    assert Enum.map(result, & &1.id) == [imap.id]
    assert Enum.map(result, & &1.provider) == ["email:imap"]
  end

  test "get_by_provider/1 ignores disabled configs" do
    _disabled = insert_channel_config(%{provider: "mattermost", enabled: false})
    enabled = insert_channel_config(%{provider: "slack", enabled: true})
    enabled_id = enabled.id

    assert %ChannelConfig{id: ^enabled_id} = ChannelConfig.get_by_provider("slack")
    assert nil == ChannelConfig.get_by_provider("mattermost")
  end

  test "get_any_by_provider/1 returns disabled config" do
    disabled = insert_channel_config(%{provider: "mattermost", enabled: false})
    disabled_id = disabled.id

    assert %ChannelConfig{id: ^disabled_id} = ChannelConfig.get_any_by_provider("mattermost")
  end

  test "provider-only lookups and upsert fail closed when two connectors share a provider" do
    first = insert_channel_config(%{provider: "slack", name: "Workspace A"})
    second = insert_channel_config(%{provider: "slack", name: "Workspace B"})

    assert first.id != second.id
    assert ChannelConfig.get(first.id).name == "Workspace A"
    assert ChannelConfig.get(second.id).name == "Workspace B"
    assert nil == ChannelConfig.get_by_provider("slack")
    assert nil == ChannelConfig.get_any_by_provider("slack")
    assert {:error, :ambiguous_connector} = ChannelConfig.resolve_by_provider("slack")
    assert {:error, :ambiguous_connector} = Bridge.fetch_channel_config("slack")
    assert {:ok, explicitly_selected} = Bridge.fetch_channel_config("slack", second.id)
    assert explicitly_selected.id == second.id

    assert {:error, :connector_mismatch} =
             Bridge.fetch_channel_config("mattermost", second.id)

    assert {:ok, selected} = ChannelConfig.resolve_by_provider("slack", first.id)
    assert selected.id == first.id

    assert {:error, :connector_mismatch} =
             ChannelConfig.resolve_by_provider("mattermost", first.id)

    assert {:error, :ambiguous_connector} =
             ChannelConfig.upsert_by_provider("slack", %{name: "Do not overwrite either"})

    assert ChannelConfig.get(first.id).name == "Workspace A"
    assert ChannelConfig.get(second.id).name == "Workspace B"
  end

  test "provider-only resolution stays ambiguous even if one connector is disabled" do
    first = insert_channel_config(%{provider: "slack", name: "Active", enabled: true})
    second = insert_channel_config(%{provider: "slack", name: "Disabled", enabled: false})

    assert {:error, :ambiguous_connector} = ChannelConfig.resolve_by_provider("slack")
    assert nil == ChannelConfig.get_by_provider("slack")
    assert {:ok, config} = ChannelConfig.resolve_by_provider("slack", first.id)
    assert config.id == first.id

    assert {:error, :connector_mismatch} =
             ChannelConfig.resolve_by_provider("slack", second.id)
  end

  test "archived connector remains addressable by ID but is excluded from provider selection" do
    config = insert_channel_config(%{provider: "slack", enabled: true})

    assert {:ok, archived} = ChannelConfig.archive(config)
    assert archived.archived_at
    refute archived.enabled
    assert {:ok, same} = ChannelConfig.archive(archived)
    assert same.archived_at == archived.archived_at
    assert ChannelConfig.get(config.id).id == archived.id
    assert nil == ChannelConfig.get_any_by_provider("slack")
    assert {:error, :not_found} = ChannelConfig.resolve_by_provider("slack", config.id)

    replacement = insert_channel_config(%{provider: "slack", name: "Replacement"})
    assert ChannelConfig.get_by_provider("slack").id == replacement.id

    assert {:ok, updated} =
             ChannelConfig.upsert_by_provider("slack", %{
               name: "Updated replacement",
               kind: "retrieval",
               url: "https://example.invalid",
               token: "fixture-token"
             })

    assert updated.id == replacement.id
    assert ChannelConfig.get(config.id).archived_at == archived.archived_at
    refute ChannelConfig.changeset(archived, %{enabled: true}).valid?

    assert {:error, :protected} =
             Repo.transaction(fn ->
               result =
                 archived
                 |> Ecto.Changeset.change(enabled: true)
                 |> Ecto.Changeset.check_constraint(:enabled,
                   name: :archived_configs_disabled
                 )
                 |> Repo.update()

               assert {:error, %Ecto.Changeset{}} = result
               Repo.rollback(:protected)
             end)
  end

  test "upsert_by_provider/2 inserts and updates provider config" do
    attrs = %{
      name: "Email SMTP",
      kind: "retrieval",
      url: "smtp://configured-in-settings",
      token: "smtp-unused",
      enabled: true,
      settings: %{"relay" => "smtp.example.com", "port" => "587"}
    }

    assert {:ok, inserted} = ChannelConfig.upsert_by_provider("email:smtp", attrs)
    assert inserted.provider == "email:smtp"
    assert inserted.settings["relay"] == "smtp.example.com"

    assert {:ok, updated} =
             ChannelConfig.upsert_by_provider("email:smtp", %{
               name: "Email SMTP",
               kind: "retrieval",
               url: "smtp://configured-in-settings",
               token: "smtp-unused",
               enabled: false,
               settings: %{"relay" => "smtp.internal.local", "port" => "465"}
             })

    assert updated.id == inserted.id
    assert updated.enabled == false
    assert updated.settings["relay"] == "smtp.internal.local"
  end

  test "get_by_channel_id/2 returns config for matching channel and provider" do
    config = insert_channel_config(%{provider: "mattermost", enabled: true})

    %RetrievalChannel{}
    |> RetrievalChannel.changeset(%{
      channel_config_id: config.id,
      channel_id: "chan-abc",
      channel_name: "general",
      team_id: "team-1",
      team_name: "My Team"
    })
    |> Repo.insert!()

    result = ChannelConfig.get_by_channel_id("mattermost", "chan-abc")
    assert result.id == config.id
  end

  test "get_by_channel_id does not mistake another connector's channel for its own" do
    first = insert_channel_config(%{provider: "slack", name: "Workspace A", enabled: true})
    second = insert_channel_config(%{provider: "slack", name: "Workspace B", enabled: false})

    for config <- [first, second] do
      %RetrievalChannel{}
      |> RetrievalChannel.changeset(%{
        channel_config_id: config.id,
        channel_id: "same-room",
        channel_name: "general",
        team_id: "team-1",
        team_name: "My Team"
      })
      |> Repo.insert!()
    end

    assert nil == ChannelConfig.get_by_channel_id("slack", "same-room")

    assert %ChannelConfig{id: id} =
             ChannelConfig.get_by_channel_id("slack", "same-room", first.id)

    assert id == first.id
    assert nil == ChannelConfig.get_by_channel_id("slack", "same-room", second.id)
  end

  test "get_by_channel_id/2 returns nil for unknown channel_id" do
    assert nil == ChannelConfig.get_by_channel_id("mattermost", "no-such-chan")
  end

  test "get_by_channel_id/2 returns nil for disabled config" do
    config = insert_channel_config(%{provider: "slack", enabled: false})

    %RetrievalChannel{}
    |> RetrievalChannel.changeset(%{
      channel_config_id: config.id,
      channel_id: "chan-disabled",
      channel_name: "general",
      team_id: "team-1",
      team_name: "My Team"
    })
    |> Repo.insert!()

    assert nil == ChannelConfig.get_by_channel_id("slack", "chan-disabled")
  end

  test "get/1 returns nil for invalid ids and finds configs by integer or trimmed string id" do
    config = insert_channel_config(%{provider: "mattermost", enabled: false})

    for id <- ["", " ", "abc", "12x", "0", "-1", nil, :invalid, 0, -1, %{}] do
      assert ChannelConfig.get(id) == nil
    end

    assert %ChannelConfig{id: id} = ChannelConfig.get(config.id)
    assert id == config.id
    assert %ChannelConfig{id: ^id} = ChannelConfig.get(" #{config.id} ")
  end

  test "jido_chat_settings/1 returns empty map for non-struct config without settings key" do
    assert %{} == ChannelConfig.jido_chat_settings(%{})
  end

  test "helper accessors normalize non-map nested payloads for plain maps" do
    assert ChannelConfig.jido_chat_settings(%{settings: %{"jido_chat" => "bad"}}) == %{}
    assert ChannelConfig.imap_settings(%{settings: %{"imap" => "bad"}}) == %{}
  end

  test "set_provider_default_agent_id/2 persists provider default agent id as routing rule" do
    config = insert_channel_config(%{provider: "mattermost", settings: %{}})
    agent = insert_configured_agent()

    assert {:ok, updated} = ChannelConfig.set_provider_default_agent_id(config, agent.id)
    assert ChannelConfig.get_provider_default_agent_id(updated) == agent.id

    reloaded = Repo.get!(ChannelConfig, config.id)
    assert ChannelConfig.get_provider_default_agent_id(reloaded) == agent.id

    assert %{routing_mode: :agent, configured_agent_id: configured_agent_id} =
             IncomingMessageRouting.get_rule(%{channel_config_id: config.id})

    assert configured_agent_id == agent.id
  end

  test "set_provider_default_agent_id/2 clears provider default agent id with nil" do
    config = insert_channel_config(%{provider: "discord", settings: %{}})
    agent = insert_configured_agent()

    assert {:ok, updated} = ChannelConfig.set_provider_default_agent_id(config, agent.id)
    assert {:ok, cleared} = ChannelConfig.set_provider_default_agent_id(updated, nil)

    assert ChannelConfig.get_provider_default_agent_id(cleared) == nil
    assert IncomingMessageRouting.get_rule(%{channel_config_id: config.id}) == nil
  end

  test "set_provider_default_agent_id/2 persists NONE as provider agent choice" do
    config = insert_channel_config(%{provider: "discord", settings: %{}})

    assert {:ok, updated} =
             ChannelConfig.set_provider_default_agent_id(
               config,
               AgentRouting.none_value()
             )

    assert ChannelConfig.get_provider_default_agent_id(updated) == nil

    assert ChannelConfig.get_provider_agent_choice(updated) ==
             AgentRouting.none_value()

    reloaded = Repo.get!(ChannelConfig, config.id)

    assert ChannelConfig.get_provider_agent_choice(reloaded) ==
             AgentRouting.none_value()

    assert %{routing_mode: :none, configured_agent_id: nil} =
             IncomingMessageRouting.get_rule(%{channel_config_id: config.id})
  end

  test "set_provider_default_agent_id/2 rejects agents without conversations enabled" do
    config = insert_channel_config(%{provider: "mattermost", settings: %{}})
    agent = insert_configured_agent(%{conversation_enabled: false})

    assert {:error, changeset} = ChannelConfig.set_provider_default_agent_id(config, agent.id)
    assert "must be conversation-enabled" in errors_on(changeset).configured_agent_id
    assert IncomingMessageRouting.get_rule(%{channel_config_id: config.id}) == nil
  end

  test "get_provider_default_agent_id/1 returns nil for invalid value" do
    config =
      insert_channel_config(%{
        provider: "mattermost",
        settings: %{"routing" => %{"default_agent_id" => "oops"}}
      })

    assert ChannelConfig.get_provider_default_agent_id(config) == nil
  end

  test "get_provider_default_agent_id/1 returns nil when settings is not a map" do
    assert ChannelConfig.get_provider_default_agent_id(%{settings: "bad"}) == nil
  end

  test "set_provider_default_agent_id/2 deletes provider routing rule when clearing" do
    config =
      insert_channel_config(%{
        provider: "discord",
        settings: %{"routing" => %{"default_agent_id" => 12}}
      })

    assert {:ok, cleared} = ChannelConfig.set_provider_default_agent_id(config, nil)
    assert ChannelConfig.get_provider_agent_choice(cleared) == nil
    assert IncomingMessageRouting.get_rule(%{channel_config_id: config.id}) == nil
  end

  test "imap and jido_chat helpers normalize non-map payloads" do
    config =
      insert_channel_config(%{
        provider: "mattermost",
        settings: %{"imap" => "bad", "jido_chat" => "bad"}
      })

    assert ChannelConfig.imap_settings(config) == %{}
    assert ChannelConfig.imap_selected_mailboxes(config) == []
    assert ChannelConfig.jido_chat_settings(config) == %{}
    assert ChannelConfig.jido_chat_bot_name(config) == nil
    assert ChannelConfig.jido_chat_bot_user_id(config) == nil
  end

  test "helper accessors handle maps, nil, and loaded smtp records without token" do
    assert ChannelConfig.jido_chat_settings(%{settings: %{"jido_chat" => %{"bot_name" => "zaq"}}}) ==
             %{"bot_name" => "zaq"}

    assert ChannelConfig.imap_settings(%{
             settings: %{"imap" => %{"selected_mailboxes" => ["INBOX"]}}
           }) == %{"selected_mailboxes" => ["INBOX"]}

    assert ChannelConfig.imap_settings(nil) == %{}
    assert ChannelConfig.get_provider_default_agent_id(nil) == nil

    {:ok, smtp} =
      ChannelConfig.upsert_by_provider("email:smtp", %{
        name: "Email SMTP",
        kind: "retrieval",
        enabled: true,
        settings: %{"relay" => "smtp.example.com", "port" => "587"}
      })

    loaded = Repo.get!(ChannelConfig, smtp.id)

    assert {:ok, updated} =
             loaded |> ChannelConfig.changeset(%{name: "Email SMTP Updated"}) |> Repo.update()

    assert updated.name == "Email SMTP Updated"
  end

  test "email:imap requires token" do
    imap_changeset =
      ChannelConfig.changeset(%ChannelConfig{}, %{
        name: "IMAP",
        provider: "email:imap",
        kind: "retrieval",
        enabled: false,
        settings: %{"imap" => %{"selected_mailboxes" => ["INBOX"]}}
      })

    refute imap_changeset.valid?
    assert "can't be blank" in errors_on(imap_changeset).token
  end

  defp insert_channel_config(attrs) do
    defaults = %{
      name: "Config",
      provider: "mattermost",
      kind: "retrieval",
      url: "https://mattermost.example.com",
      token: "test-token",
      enabled: true
    }

    %ChannelConfig{}
    |> ChannelConfig.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp upsert_imap_config(opts) do
    enabled = Keyword.fetch!(opts, :enabled)
    mailbox = Keyword.fetch!(opts, :mailbox)

    attrs = %{
      name: "Email IMAP",
      provider: "email:imap",
      kind: "retrieval",
      token: "imap-secret",
      enabled: enabled,
      settings: %{"imap" => %{"selected_mailboxes" => [mailbox]}}
    }

    case ChannelConfig.get_any_by_provider("email:imap") do
      nil ->
        insert_channel_config(attrs)

      existing ->
        assert {:ok, updated} =
                 existing
                 |> ChannelConfig.changeset(attrs)
                 |> Repo.update()

        updated
    end
  end

  defp insert_configured_agent(overrides \\ %{}) do
    credential =
      SystemConfigFixtures.ai_credential_fixture(%{
        provider: "openai",
        endpoint: "https://api.openai.com/v1"
      })

    attrs =
      Map.merge(
        %{
          name: "Provider Default Agent #{System.unique_integer([:positive, :monotonic])}",
          description: "",
          job: "Route provider traffic",
          model: "gpt-4.1-mini",
          credential_id: credential.id,
          strategy: "react",
          enabled_tool_keys: [],
          conversation_enabled: true,
          active: true,
          advanced_options: %{}
        },
        overrides
      )

    {:ok, agent} = Zaq.Agent.create_agent(attrs)

    agent
  end

  defp with_encrypted_string_stub(fun) when is_function(fun, 0) do
    {_, original_binary, original_path} = :code.get_object_code(Zaq.Types.EncryptedString)

    :code.purge(Zaq.Types.EncryptedString)
    :code.delete(Zaq.Types.EncryptedString)

    Code.compiler_options(ignore_module_conflict: true)

    Code.compile_string("""
    defmodule Zaq.Types.EncryptedString do
      use Ecto.Type

      def encrypt(_value), do: {:error, :boom}
      def decrypt(value), do: {:ok, value}
      def encrypted?(_value), do: false
      def type, do: :string

      def cast(nil), do: {:ok, nil}
      def cast(value) when is_binary(value), do: {:ok, value}
      def cast(_), do: :error

      def load(value), do: {:ok, value}
      def dump(nil), do: {:ok, nil}
      def dump(value) when is_binary(value), do: {:ok, value}
      def dump(_), do: :error
    end
    """)

    Code.compiler_options(ignore_module_conflict: false)

    try do
      fun.()
    after
      :code.purge(Zaq.Types.EncryptedString)
      :code.delete(Zaq.Types.EncryptedString)

      {:module, Zaq.Types.EncryptedString} =
        :code.load_binary(Zaq.Types.EncryptedString, original_path, original_binary)

      Code.compiler_options(ignore_module_conflict: false)
    end
  end

  test "WhatsApp creation persists the default alongside existing connector settings" do
    settings = %{"owner_id" => 4, "jido_chat" => %{"bot_name" => "Support"}}
    saved = create_reply_policy_config!("whatsapp", settings)

    assert saved.settings ==
             put_in(settings["jido_chat"]["room_reply_policy"], "mention_required")

    assert Settings.jido_chat_room_reply_policy(ChannelConfig.to_runtime_config(saved)) ==
             :mention_required
  end

  test "explicit policies work for every messaging provider and other providers retain their defaults" do
    for provider <- ["whatsapp", "telegram", "mattermost", "discord"] do
      for policy <- ["default", "mention_required"] do
        saved =
          create_reply_policy_config!(provider, %{"jido_chat" => %{"room_reply_policy" => policy}})

        assert Settings.jido_chat_setting(saved, "room_reply_policy") == policy
      end

      unless provider == "whatsapp" do
        saved = create_reply_policy_config!(provider, %{"unrelated" => true})
        assert saved.settings == %{"unrelated" => true}
        assert Settings.jido_chat_room_reply_policy(saved) == :default
      end
    end
  end

  test "partial settings edits preserve a saved policy until explicitly replaced" do
    for provider <- ["whatsapp", "telegram"] do
      saved =
        create_reply_policy_config!(provider, %{
          "jido_chat" => %{"room_reply_policy" => "default"}
        })

      updated =
        saved |> ChannelConfig.changeset(%{settings: %{"custom" => "updated"}}) |> Repo.update!()

      assert updated.settings == %{
               "custom" => "updated",
               "jido_chat" => %{"room_reply_policy" => "default"}
             }

      updated =
        updated
        |> ChannelConfig.changeset(%{
          settings: %{"jido_chat" => %{"room_reply_policy" => "mention_required"}}
        })
        |> Repo.update!()

      assert Settings.jido_chat_room_reply_policy(updated) == :mention_required
    end
  end

  test "null policy is treated as absent and unsupported or malformed settings reject writes" do
    config = %ChannelConfig{
      provider: "whatsapp",
      name: "Support",
      kind: "retrieval",
      url: "https://example.test",
      token: "test-token"
    }

    for settings <- [%{}, %{"jido_chat" => nil}, %{"jido_chat" => %{"room_reply_policy" => nil}}] do
      changeset = ChannelConfig.changeset(config, %{settings: settings})
      assert changeset.valid?

      assert Changeset.get_field(changeset, :settings)["jido_chat"]["room_reply_policy"] ==
               "mention_required"
    end

    for settings <- [
          %{"jido_chat" => "invalid"},
          %{"jido_chat" => %{"room_reply_policy" => "all"}},
          %{"jido_chat" => %{"room_reply_policy" => false}}
        ] do
      changeset = ChannelConfig.changeset(config, %{settings: settings})
      refute changeset.valid?
      assert errors_on(changeset).settings != []
    end
  end

  property "default insertion retains arbitrary unrelated JSON keys and nested values" do
    check all(value <- one_of([integer(), boolean(), string(:alphanumeric)]), max_runs: 30) do
      original = %{"other" => value, "jido_chat" => %{"bot_name" => value}}

      changeset =
        ChannelConfig.changeset(%ChannelConfig{}, reply_policy_attrs("whatsapp", original))

      assert changeset.valid?
      result = Changeset.get_field(changeset, :settings)
      assert result["other"] == value
      assert Map.delete(result["jido_chat"], "room_reply_policy") == original["jido_chat"]
    end
  end

  defp create_reply_policy_config!(provider, settings) do
    %ChannelConfig{}
    |> ChannelConfig.changeset(reply_policy_attrs(provider, settings))
    |> Repo.insert!()
  end

  defp reply_policy_attrs(provider, settings),
    do: %{
      name: Ecto.UUID.generate(),
      provider: provider,
      kind: "retrieval",
      enabled: false,
      url: "https://example.com",
      token: "test-token",
      settings: settings
    }

  test "Engine creation and upsert save defaults while changesets only validate" do
    attrs = %{provider: "whatsapp", name: "Support", kind: "retrieval", enabled: false}
    assert {:ok, saved} = ChannelConfig.create(attrs, adapter_authentication: true)

    assert saved_history_options(saved) == %{
             "sync_history" => false,
             "sync_full_history" => false
           }

    assert saved.settings["jido_chat"]["room_reply_policy"] == "mention_required"

    settings =
      Ecto.Changeset.get_field(
        ChannelConfig.changeset(%ChannelConfig{}, attrs, adapter_authentication: true),
        :settings
      )

    refute Map.has_key?(settings["jido_chat"], "ingress")

    Repo.delete!(saved)

    assert {:ok, upserted} =
             ChannelConfig.upsert_by_provider("whatsapp", Map.delete(attrs, :provider),
               adapter_authentication: true
             )

    assert saved_history_options(upserted) == saved_history_options(saved)
  end

  test "explicit flags survive string-key creation, unrelated edits and upsert" do
    attrs = %{
      "provider" => "whatsapp",
      "name" => "Support",
      "kind" => "retrieval",
      "enabled" => false,
      "settings" => %{"owner_id" => 3, "jido_chat" => %{"ingress" => %{"sync_history" => true}}}
    }

    assert {:ok, saved} = ChannelConfig.create(attrs, adapter_authentication: true)
    assert saved_history_options(saved) == %{"sync_history" => true, "sync_full_history" => false}
    assert saved.settings["owner_id"] == 3

    assert {:ok, updated} =
             ChannelConfig.upsert_by_provider("whatsapp", %{settings: %{"custom" => "changed"}},
               adapter_authentication: true
             )

    assert saved_history_options(updated) == saved_history_options(saved)
    assert updated.settings["custom"] == "changed"

    assert {:ok, updated} =
             updated
             |> ChannelConfig.changeset(
               %{
                 settings: %{
                   "jido_chat" => %{
                     "ingress" => %{"sync_history" => false, "sync_full_history" => true}
                   }
                 }
               },
               adapter_authentication: true
             )
             |> Repo.update()

    assert saved_history_options(updated) == %{
             "sync_history" => false,
             "sync_full_history" => true
           }
  end

  test "partial edits retain provider options while replacing unrelated settings" do
    attrs = %{
      provider: "whatsapp",
      name: "Support",
      kind: "retrieval",
      enabled: false,
      settings: %{
        "jido_chat" => %{"ingress" => %{"sync_history" => true}},
        "obsolete" => true
      }
    }

    assert {:ok, saved} = ChannelConfig.create(attrs, adapter_authentication: true)
    assert saved_history_options(saved) == %{"sync_history" => true, "sync_full_history" => false}

    assert {:ok, updated} =
             saved
             |> ChannelConfig.changeset(%{settings: %{"other" => "new"}},
               adapter_authentication: true
             )
             |> Repo.update()

    assert updated.settings == %{
             "jido_chat" => %{
               "room_reply_policy" => "mention_required",
               "ingress" => %{"sync_history" => true, "sync_full_history" => false}
             },
             "other" => "new"
           }
  end

  test "runtime readers project persisted defaults and explicit choices without rewriting storage" do
    assert {:ok, saved} =
             ChannelConfig.create(
               %{
                 provider: "whatsapp",
                 name: "Stored defaults",
                 kind: "retrieval",
                 enabled: false
               },
               adapter_authentication: true
             )

    assert Settings.jido_chat_setting(saved, "ingress") == %{
             "sync_history" => false,
             "sync_full_history" => false
           }

    assert Settings.jido_chat_room_reply_policy(saved) == :mention_required
    assert Repo.get!(ChannelConfig, saved.id).settings == saved.settings

    override = %{
      saved
      | settings: %{
          "jido_chat" => %{
            "ingress" => %{"sync_history" => true},
            "room_reply_policy" => "default"
          }
        }
    }

    assert Settings.jido_chat_setting(override, "ingress") == %{"sync_history" => true}

    assert Settings.jido_chat_room_reply_policy(override) == :default
  end

  test "providers without configured defaults preserve their existing settings" do
    for provider <- ~w(telegram mattermost discord) do
      attrs = %{
        provider: provider,
        name: provider,
        kind: "retrieval",
        url: "https://example.com",
        token: "test",
        enabled: false,
        settings: %{"other" => true}
      }

      assert {:ok, saved} = ChannelConfig.create(attrs)
      assert saved.settings == %{"other" => true}
      assert Settings.jido_chat_settings(saved) == %{}
      assert Settings.jido_chat_room_reply_policy(saved) == :default
    end
  end

  defp saved_history_options(config), do: config.settings["jido_chat"]["ingress"]
end
