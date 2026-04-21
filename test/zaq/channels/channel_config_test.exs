defmodule Zaq.Channels.ChannelConfigTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.{ChannelConfig, RetrievalChannel}
  alias Zaq.Repo
  alias Zaq.System.SecretConfig
  alias Zaq.SystemConfigFixtures

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

    _ingestion_enabled =
      insert_channel_config(%{provider: "google_drive", kind: "ingestion", enabled: true})

    _unknown_provider =
      insert_channel_config(%{provider: "discord", kind: "retrieval", enabled: true})

    assert [result] = ChannelConfig.list_enabled_by_kind(:retrieval, ["mattermost"])
    assert result.id == retrieval_enabled.id
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

  test "jido_chat_settings/1 returns empty map for non-struct config without settings key" do
    assert %{} == ChannelConfig.jido_chat_settings(%{})
  end

  test "set_provider_default_agent_id/2 persists provider default agent id in settings" do
    config = insert_channel_config(%{provider: "mattermost", settings: %{}})
    agent = insert_configured_agent()

    assert {:ok, updated} = ChannelConfig.set_provider_default_agent_id(config, agent.id)
    assert ChannelConfig.get_provider_default_agent_id(updated) == agent.id

    reloaded = Repo.get!(ChannelConfig, config.id)
    assert ChannelConfig.get_provider_default_agent_id(reloaded) == agent.id
  end

  test "set_provider_default_agent_id/2 clears provider default agent id with nil" do
    config = insert_channel_config(%{provider: "discord", settings: %{}})
    agent = insert_configured_agent()

    assert {:ok, updated} = ChannelConfig.set_provider_default_agent_id(config, agent.id)
    assert {:ok, cleared} = ChannelConfig.set_provider_default_agent_id(updated, nil)

    assert ChannelConfig.get_provider_default_agent_id(cleared) == nil
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

  defp insert_configured_agent do
    credential =
      SystemConfigFixtures.ai_credential_fixture(%{
        provider: "openai",
        endpoint: "https://api.openai.com/v1"
      })

    {:ok, agent} =
      Zaq.Agent.create_agent(%{
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
      })

    agent
  end
end
