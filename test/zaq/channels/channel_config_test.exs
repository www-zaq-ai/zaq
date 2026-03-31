defmodule Zaq.Channels.ChannelConfigTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Repo
  alias Zaq.System.SecretConfig

  defmodule StubPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)

      send(
        opts[:test_pid],
        {:stub_request, conn.method, conn.request_path, conn.query_string, body}
      )

      case opts[:handler].(conn, body) do
        {status, response} when is_map(response) or is_list(response) ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(status, Jason.encode!(response))

        {status, response} ->
          send_resp(conn, status, response)
      end
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

  test "list_enabled_by_kind/1 returns only enabled configs for kind" do
    retrieval_enabled =
      insert_channel_config(%{provider: "mattermost", kind: "retrieval", enabled: true})

    _retrieval_disabled =
      insert_channel_config(%{provider: "slack", kind: "retrieval", enabled: false})

    _ingestion_enabled =
      insert_channel_config(%{provider: "google_drive", kind: "ingestion", enabled: true})

    assert [result] = ChannelConfig.list_enabled_by_kind(:retrieval)
    assert result.id == retrieval_enabled.id
  end

  test "get_by_provider/1 ignores disabled configs" do
    _disabled = insert_channel_config(%{provider: "mattermost", enabled: false})
    enabled = insert_channel_config(%{provider: "slack", enabled: true})
    enabled_id = enabled.id

    assert %ChannelConfig{id: ^enabled_id} = ChannelConfig.get_by_provider("slack")
    assert nil == ChannelConfig.get_by_provider("mattermost")
  end

  test "test_connection/2 returns unsupported provider error" do
    config = %ChannelConfig{provider: "slack"}

    assert {:error, "Testing not supported for slack"} =
             ChannelConfig.test_connection(config, "channel-1")
  end

  test "test_connection/2 dispatches to provider API module" do
    base_url =
      start_stub_server(fn conn, body ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/v4/posts"

        assert %{"channel_id" => "channel-1", "message" => message} = Jason.decode!(body)
        assert String.contains?(message, "Zaq Connection Test")

        {201, %{"id" => "post-1"}}
      end)

    config = %ChannelConfig{provider: "mattermost", url: base_url, token: "token"}

    assert {:ok, %{"id" => "post-1"}} = ChannelConfig.test_connection(config, "channel-1")
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

  defp start_stub_server(handler) do
    port = free_port()

    start_supervised!(
      {Bandit, plug: {StubPlug, test_pid: self(), handler: handler}, scheme: :http, port: port}
    )

    "http://127.0.0.1:#{port}"
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
