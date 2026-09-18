defmodule Zaq.Engine.Connect.RefreshRecoveryTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Credential, Grant}
  alias Zaq.Repo
  alias Zaq.TestSupport.{ConnectOAuthAttemptConfig, ConnectOAuthAttemptHTTP}
  @now ~U[2026-09-14 12:00:00Z]
  @opts [config: ConnectOAuthAttemptConfig, now: @now]
  setup {Req.Test, :verify_on_exit!}

  setup do
    Code.ensure_loaded!(ConnectOAuthAttemptConfig)

    {credential, grant} =
      db(fn ->
        {:ok, dto} =
          Connect.save_credential_configuration(nil, %{
            name: "recovery-#{Ecto.UUID.generate()}",
            provider: "example",
            auth_kind: "oauth2",
            secret_binding: :grant,
            personal_credential_policy: :required,
            client_id: "client",
            metadata: %{"token_url" => "https://provider.example/token"}
          })

        credential = Repo.get!(Credential, dto.credential_id)

        {:ok, dto} =
          Connect.replace_credential_grant(credential, :org, %{
            access_token: "old",
            refresh_token: "refresh"
          })

        {credential, Repo.get!(Grant, dto.grant_id)}
      end)

    on_exit(fn ->
      db(fn ->
        Repo.query!("ALTER TABLE oban_jobs DROP CONSTRAINT IF EXISTS refresh_event_failure")
        Repo.delete_all(from c in Credential, where: c.id == ^credential.id)

        Repo.delete_all(
          from j in Oban.Job,
            where: fragment("?->>'credential_id'", j.args) == ^to_string(credential.id)
        )
      end)
    end)

    %{credential: credential, grant: grant}
  end

  for finish <- [:crash, :late] do
    test "#{finish} holder cannot block lease recovery indefinitely", %{grant: grant} do
      parent = self()

      Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
        send(parent, {:entered, self()})

        receive do
          :continue -> Req.Test.json(conn, %{"access_token" => "late", "expires_in" => 3600})
        after
          5_000 -> flunk("barrier timeout")
        end
      end)

      task = Task.async(fn -> db(fn -> Connect.refresh_grant(grant, @opts) end) end)
      assert_receive {:entered, holder}, 5_000
      assert {:error, :refresh_busy} = db(fn -> Connect.refresh_grant(grant, @opts) end)

      if unquote(finish) == :crash do
        Task.shutdown(task, :brutal_kill)
      end

      Req.Test.expect(
        ConnectOAuthAttemptHTTP,
        &Req.Test.json(&1, %{
          "access_token" => "recovered",
          "refresh_token" => "rotated",
          "expires_in" => 3600
        })
      )

      assert {:ok, %{access_token: "recovered"}} =
               db(fn ->
                 Connect.refresh_grant(grant, Keyword.put(@opts, :now, DateTime.add(@now, 120)))
               end)

      if unquote(finish) == :late do
        send(holder, :continue)
        assert {:error, :stale_grant} = Task.await(task)
      end

      assert db(fn -> Repo.get!(Grant, grant.id).refresh_token end) == "rotated"
    end
  end

  test "real event insertion failure rolls back returned token and leaves bounded claim", %{
    grant: grant
  } do
    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      refute Repo.in_transaction?()

      Repo.query!(
        "ALTER TABLE oban_jobs ADD CONSTRAINT refresh_event_failure CHECK (queue <> 'connect_credential_notifications') NOT VALID"
      )

      Req.Test.json(conn, %{"access_token" => "must-rollback", "expires_in" => 3600})
    end)

    assert {:error, reason} = db(fn -> Connect.refresh_grant(grant, @opts) end)
    assert reason in [:mutation_event_enqueue_failed, :invalid_material]

    db(fn ->
      assert Repo.get!(Grant, grant.id).access_token == "old"
      assert {:error, :refresh_busy} = Connect.refresh_grant(grant, @opts)
      Repo.query!("ALTER TABLE oban_jobs DROP CONSTRAINT refresh_event_failure")

      refute Repo.exists?(
               from j in Oban.Job,
                 where:
                   fragment("?->>'grant_id'", j.args) == ^to_string(grant.id) and
                     fragment("?->>'kind'", j.args) == "grant_tokens_updated"
             )
    end)
  end

  defp db(fun), do: Sandbox.unboxed_run(Repo, fun)
end
