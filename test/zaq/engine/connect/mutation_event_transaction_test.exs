defmodule Zaq.Engine.Connect.MutationEventTransactionTest do
  # Transaction-local DDL forces an actual Oban insertion error. Serialize because
  # PostgreSQL takes a table lock; sandbox rollback removes the test constraint.
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Credential, Grant}

  defp reject_jobs do
    Repo.query!(
      "ALTER TABLE oban_jobs ADD CONSTRAINT connect_event_test_failure CHECK (queue <> 'connect_credential_notifications') NOT VALID"
    )
  end

  test "failed real Oban insertion aborts the credential transaction with a safe error" do
    reject_jobs()

    name = Ecto.UUID.generate()

    assert {:error, :mutation_event_enqueue_failed} =
             Connect.create_credential(%{name: name, provider: "example", auth_kind: "api_key"})

    refute Repo.get_by(Credential, name: name)
  end

  test "enqueue failure rolls back canonical and legacy update revoke delete and token writes" do
    {:ok, c} =
      Connect.create_credential(%{
        name: Ecto.UUID.generate(),
        provider: "example",
        auth_kind: "oauth2",
        client_id: "client"
      })

    {:ok, dto} =
      Connect.replace_credential_grant(c, :org, %{
        access_token: "ORIGINAL",
        refresh_token: "REFRESH"
      })

    g = Repo.get!(Grant, dto.grant_id)

    {:ok, legacy} =
      Connect.issue_grant(%{
        credential_id: c.id,
        resource_type: "mcp",
        resource_id: "1",
        owner_type: "org",
        access_token: "ORIGINAL",
        refresh_token: "REFRESH"
      })

    reject_jobs()

    for mutation <- [
          fn -> Connect.update_credential(c, %{name: "changed"}) end,
          fn -> Connect.delete_credential(c) end,
          fn -> Connect.save_credential_configuration(c, %{name: "changed"}) end,
          fn -> Connect.replace_credential_grant(c, :org, %{access_token: "REPLACED"}) end,
          fn -> Connect.revoke_credential_grant(c, :org) end,
          fn -> Connect.remove_credential_grant(c, :org) end,
          fn -> Connect.revoke_grant(legacy) end,
          fn -> Connect.delete_grant(legacy) end,
          fn ->
            Connect.update_grant_token_cache(g, %{
              access_token: "REPLACED",
              expires_at: ~U[2099-01-01 00:00:00Z]
            })
          end
        ] do
      assert {:error, reason} = mutation.()
      assert is_atom(reason)
      assert Repo.reload!(c).name == c.name
      assert Repo.reload!(g).access_token == "ORIGINAL"
      assert Repo.reload!(g).status == "active"
      assert Repo.reload!(legacy).status == "active"
    end
  end
end
