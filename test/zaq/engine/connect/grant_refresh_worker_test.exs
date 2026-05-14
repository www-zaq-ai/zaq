defmodule Zaq.Engine.Connect.GrantRefreshWorkerTest do
  use Zaq.DataCase, async: true

  alias Oban.Job
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.GrantRefreshWorker

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
        resource_type: "data_source",
        resource_id: "1",
        owner_type: "org",
        metadata: %{},
        status: "active"
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
end
