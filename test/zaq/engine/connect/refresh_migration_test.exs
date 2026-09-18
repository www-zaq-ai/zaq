unless Code.ensure_loaded?(Zaq.Repo.Migrations.AddConnectGrantRefreshClaim) do
  Code.require_file(
    "../../../../priv/repo/migrations/20260914120057_add_connect_grant_refresh_claim.exs",
    __DIR__
  )
end

defmodule Zaq.Engine.Connect.RefreshMigrationTest do
  use Zaq.DataCase, async: false
  alias Zaq.Engine.Connect
  alias Zaq.Repo.Migrations.AddConnectGrantRefreshClaim

  test "claim migration round-trips without changing grant material" do
    {:ok, credential} =
      Connect.create_credential(%{
        name: Ecto.UUID.generate(),
        provider: "example",
        auth_kind: "oauth2",
        client_id: "client"
      })

    {:ok, grant} =
      Connect.issue_grant(%{
        credential_id: credential.id,
        resource_type: "mcp",
        resource_id: "migration",
        owner_type: "user",
        access_token: "access",
        refresh_token: "refresh"
      })

    original =
      Repo.query!(
        "SELECT access_token, refresh_token, status FROM connect_grants WHERE id = $1",
        [grant.id]
      ).rows

    assert :ok = migrate(:down)

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM information_schema.columns WHERE table_name = 'connect_grants' AND column_name IN ('refresh_claim', 'refresh_claim_until')"
             )

    assert :ok = migrate(:up)

    assert %{rows: [[2]]} =
             Repo.query!(
               "SELECT count(*) FROM information_schema.columns WHERE table_name = 'connect_grants' AND column_name IN ('refresh_claim', 'refresh_claim_until')"
             )

    assert :already_up = migrate(:up)

    assert Repo.query!(
             "SELECT access_token, refresh_token, status FROM connect_grants WHERE id = $1",
             [grant.id]
           ).rows == original
  end

  defp migrate(direction) do
    apply(Ecto.Migrator, direction, [
      Repo,
      20_260_914_120_057,
      AddConnectGrantRefreshClaim,
      [log: false, migration_lock: false, skip_table_creation: true]
    ])
  end
end
