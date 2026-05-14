defmodule Zaq.Engine.Connect.GrantRefreshWorkerTest do
  use Zaq.DataCase, async: false

  alias Oban.Job
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.GrantRefreshWorker
  alias Zaq.Repo

  defmodule StubOAuthSuccess do
    def oauth_refresh_token(_config, _params) do
      {:ok,
       %{access_token: "new_access", refresh_token: "new_refresh", expires_at: nil, scopes: []}}
    end
  end

  defmodule StubNoOAuthRefresh do
    def send_reply(_outgoing, _details), do: :ok
  end

  defp insert_config(provider, attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    base = %{
      name: "cfg-#{provider}-#{unique}",
      provider: to_string(provider),
      kind: "data_source",
      url: "https://#{provider}.example.com",
      token: "tok-#{unique}",
      enabled: true
    }

    %ChannelConfig{}
    |> ChannelConfig.changeset(Map.merge(base, Map.new(attrs)))
    |> Repo.insert!()
  end

  test "perform/1 returns ok when grant does not exist" do
    assert :ok = GrantRefreshWorker.perform(%Job{args: %{"grant_id" => -1}})
  end

  test "perform/1 returns ok for non oauth2 or non active grants" do
    {:ok, credential} =
      Connect.create_credential(%{
        name: "API credential",
        provider: "google_drive",
        auth_kind: "api_key",
        request_format: "raw",
        user_level: false,
        metadata: %{},
        api_key: "shared"
      })

    {:ok, grant} =
      Connect.issue_grant(%{
        credential_id: credential.id,
        resource_type: "mcp",
        resource_id: "1",
        owner_type: "org",
        metadata: %{},
        status: "active"
      })

    assert :ok = GrantRefreshWorker.perform(%Job{args: %{"grant_id" => grant.id}})
  end

  test "perform/1 returns ok for revoked oauth2 grants" do
    {:ok, credential} =
      Connect.create_credential(%{
        name: "Revoked OAuth credential",
        provider: "google_drive",
        auth_kind: "oauth2",
        request_format: "bearer",
        user_level: false,
        metadata: %{},
        client_id: "id",
        client_secret: "secret"
      })

    {:ok, grant} =
      Connect.issue_grant(%{
        credential_id: credential.id,
        resource_type: "mcp",
        resource_id: "revoked-1",
        owner_type: "org",
        metadata: %{},
        status: "revoked",
        access_token: "a",
        refresh_token: "r"
      })

    assert :ok = GrantRefreshWorker.perform(%Job{args: %{"grant_id" => grant.id}})
  end

  test "perform/1 returns refresh error for active oauth2 grant" do
    {:ok, credential} =
      Connect.create_credential(%{
        name: "OAuth credential",
        provider: "google_drive",
        auth_kind: "oauth2",
        request_format: "bearer",
        user_level: false,
        metadata: %{},
        client_id: "id",
        client_secret: "secret"
      })

    {:ok, grant} =
      Connect.issue_grant(%{
        credential_id: credential.id,
        resource_type: "data_source",
        resource_id: "2",
        owner_type: "org",
        metadata: %{},
        status: "active",
        access_token: "a",
        refresh_token: "r"
      })

    assert {:error, {:channel_not_configured, "google_drive"}} =
             GrantRefreshWorker.perform(%Job{args: %{"grant_id" => grant.id}})
  end

  test "perform/1 returns ok when oauth2 refresh succeeds" do
    insert_config(:google_drive, kind: "data_source")

    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      google_drive: %{bridge: GrantRefreshWorkerTest.StubOAuthSuccess}
    })

    on_exit(fn ->
      if original_channels do
        Application.put_env(:zaq, :channels, original_channels)
      else
        Application.delete_env(:zaq, :channels)
      end
    end)

    {:ok, credential} =
      Connect.create_credential(%{
        name: "OAuth credential",
        provider: "google_drive",
        auth_kind: "oauth2",
        request_format: "bearer",
        user_level: false,
        metadata: %{},
        client_id: "id",
        client_secret: "secret"
      })

    {:ok, grant} =
      Connect.issue_grant(%{
        credential_id: credential.id,
        resource_type: "data_source",
        resource_id: "2",
        owner_type: "org",
        metadata: %{},
        status: "active",
        access_token: "a",
        refresh_token: "r"
      })

    assert :ok = GrantRefreshWorker.perform(%Job{args: %{"grant_id" => grant.id}})
  end

  test "perform/1 returns ok when bridge does not support oauth2 refresh" do
    insert_config(:slack, kind: "data_source")

    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      slack: %{bridge: GrantRefreshWorkerTest.StubNoOAuthRefresh}
    })

    on_exit(fn ->
      if original_channels do
        Application.put_env(:zaq, :channels, original_channels)
      else
        Application.delete_env(:zaq, :channels)
      end
    end)

    {:ok, credential} =
      Connect.create_credential(%{
        name: "OAuth credential",
        provider: "slack",
        auth_kind: "oauth2",
        request_format: "bearer",
        user_level: false,
        metadata: %{},
        client_id: "id",
        client_secret: "secret"
      })

    {:ok, grant} =
      Connect.issue_grant(%{
        credential_id: credential.id,
        resource_type: "data_source",
        resource_id: "2",
        owner_type: "org",
        metadata: %{},
        status: "active",
        access_token: "a",
        refresh_token: "r"
      })

    assert :ok = GrantRefreshWorker.perform(%Job{args: %{"grant_id" => grant.id}})
  end
end
