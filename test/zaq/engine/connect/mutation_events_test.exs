defmodule Zaq.Engine.Connect.MutationEventsTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties
  use Oban.Testing, repo: Zaq.Repo

  alias Zaq.Accounts.Person
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Credential, Grant, MutationEvents}
  alias Zaq.TestSupport.OpenAIStub

  setup do
    # Isolate assertions from committed concurrency fixtures from previous runs.
    # This deletion is sandboxed and rolled back, never pruning the real backlog.
    Repo.delete_all(from j in Oban.Job, where: j.queue == "connect_credential_notifications")
    :ok
  end

  defp attrs(extra \\ %{}) do
    Map.merge(%{name: Ecto.UUID.generate(), provider: "example", auth_kind: "api_key"}, extra)
  end

  defp jobs do
    Repo.all(
      from j in Oban.Job,
        where: j.queue == "connect_credential_notifications",
        order_by: j.id
    )
  end

  defp assert_event(job, kind, credential_id, grant_id \\ nil, owner_type \\ nil, owner_id \\ nil) do
    assert job.state == "available"
    assert job.worker == "Zaq.Engine.Connect.MutationEventWorker"
    assert job.max_attempts == 3
    assert {:ok, _} = Ecto.UUID.cast(job.args["event_id"])
    assert {:ok, _, 0} = DateTime.from_iso8601(job.args["occurred_at"])

    assert job.args == %{
             "version" => 1,
             "event_id" => job.args["event_id"],
             "credential_id" => credential_id,
             "grant_id" => grant_id,
             "owner_type" => owner_type,
             "owner_id" => owner_id,
             "kind" => kind,
             "occurred_at" => job.args["occurred_at"]
           }
  end

  test "legacy credential CRUD enqueues once, unchanged saves do not enqueue" do
    assert {:ok, c} =
             Connect.create_credential(attrs(%{api_key: "SECRET", metadata: %{token: "SECRET"}}))

    assert [created] = jobs()
    assert_event(created, "credential_created", c.id)
    assert {:ok, c} = Connect.update_credential(c, %{name: "changed"})
    assert [_, updated] = jobs()
    assert_event(updated, "credential_updated", c.id)
    assert {:ok, _} = Connect.update_credential(c, %{})
    assert length(jobs()) == 2
    assert {:ok, _} = Connect.delete_credential(c)
    assert [_, _, deleted] = jobs()
    assert_event(deleted, "credential_deleted", c.id)
  end

  test "canonical configuration delegates do not duplicate events and failures roll back all jobs" do
    config = attrs()
    assert {:error, :global_grant_unusable} = Connect.save_credential_configuration(nil, config)
    assert jobs() == []
    refute Repo.get_by(Credential, name: config.name)

    assert {:ok, saved} =
             Connect.save_credential_configuration(nil, config, {:replace, %{api_key: "SECRET"}})

    assert [created, replaced] = jobs()
    assert_event(created, "credential_created", saved.credential_id)

    assert_event(
      replaced,
      "grant_replaced",
      saved.credential_id,
      saved.global_grant.grant_id,
      "org"
    )

    assert {:ok, _} = Connect.save_credential_configuration(saved.credential_id, %{})
    assert length(jobs()) == 2

    assert {:ok, _} =
             Connect.save_credential_configuration(saved.credential_id, %{
               personal_credential_policy: :required
             })

    assert_event(List.last(jobs()), "credential_updated", saved.credential_id)
  end

  test "canonical org and Person replacement revoke and removal retain exact dependency identity" do
    person = Repo.insert!(%Person{full_name: "Owner"})
    {:ok, c} = Connect.create_credential(attrs())

    for {owner, type, id} <- [{:org, "org", nil}, {{:person, person.id}, "person", person.id}] do
      assert {:ok, first} = Connect.replace_credential_grant(c, owner, %{api_key: "SECRET"})
      assert_event(List.last(jobs()), "grant_replaced", c.id, first.grant_id, type, id)
      assert {:ok, ^first} = Connect.replace_credential_grant(c, owner, %{api_key: "NEW-SECRET"})
      assert_event(List.last(jobs()), "grant_replaced", c.id, first.grant_id, type, id)
      assert {:ok, _} = Connect.revoke_credential_grant(c, owner)
      assert_event(List.last(jobs()), "grant_revoked", c.id, first.grant_id, type, id)
      assert {:ok, _} = Connect.remove_credential_grant(c, owner)
      refute Repo.get(Grant, first.grant_id)
      assert_event(List.last(jobs()), "grant_deleted", c.id, first.grant_id, type, id)
      count = length(jobs())
      assert {:ok, _} = Connect.remove_credential_grant(c, owner)
      assert {:ok, _} = Connect.revoke_credential_grant(c, owner)
      assert length(jobs()) == count
    end
  end

  test "legacy issue revoke delete and credential cascade capture persisted IDs" do
    {:ok, c} = Connect.create_credential(attrs(%{api_key: "SECRET"}))

    for owner <- [nil, 123] do
      type = if owner, do: "user", else: "org"

      {:ok, g} =
        Connect.issue_grant(%{
          credential_id: c.id,
          resource_type: "mcp",
          resource_id: "1",
          owner_type: type,
          owner_id: owner
        })

      assert_event(List.last(jobs()), "grant_created", c.id, g.id, type, owner)
      {:ok, g} = Connect.revoke_grant(g)
      assert_event(List.last(jobs()), "grant_revoked", c.id, g.id, type, owner)
      # A stale caller cannot report a former owner on deletion.
      Repo.update!(Ecto.Changeset.change(g, owner_type: "user", owner_id: 456))
      assert {:ok, _} = Connect.delete_grant(g)
      assert_event(List.last(jobs()), "grant_deleted", c.id, g.id, "user", 456)
    end

    {:ok, dto} = Connect.replace_credential_grant(c, :org, %{api_key: "SECRET"})
    assert {:ok, _} = Connect.delete_credential(c)
    refute Repo.get(Grant, dto.grant_id)
    assert_event(List.last(jobs()), "credential_deleted", c.id)
  end

  test "legacy OAuth cache emits events and canonical direct cache writes reject" do
    {:ok, c} = Connect.create_credential(attrs(%{auth_kind: "oauth2", client_id: "client"}))

    {:ok, canonical} =
      Connect.replace_credential_grant(c, :org, %{
        access_token: "SECRET",
        refresh_token: "REFRESH"
      })

    {:ok, legacy} =
      Connect.issue_grant(%{
        credential_id: c.id,
        resource_type: "mcp",
        resource_id: "1",
        owner_type: "org",
        access_token: "SECRET",
        refresh_token: "REFRESH"
      })

    person = Repo.insert!(%Person{full_name: "OAuth owner"})

    {:ok, personal} =
      Connect.replace_credential_grant(c, {:person, person.id}, %{
        access_token: "SECRET",
        refresh_token: "REFRESH"
      })

    for id <- [canonical.grant_id, personal.grant_id] do
      assert {:error, :canonical_refresh_required} =
               Connect.update_grant_token_cache(Repo.get!(Grant, id), %{access_token: "BYPASS"})
    end

    for g <- [legacy] do
      assert {:ok, updated} =
               Connect.update_grant_token_cache(g, %{
                 access_token: "NEW-SECRET",
                 expires_at: ~U[2099-01-01 00:00:00Z],
                 metadata: %{secret: "SENTINEL"}
               })

      assert updated.access_token == "NEW-SECRET"

      assert_event(
        List.last(jobs()),
        "grant_tokens_updated",
        c.id,
        g.id,
        g.owner_type,
        g.owner_id
      )
    end

    count = length(jobs())
    assert {:error, _} = Connect.update_grant_token_cache(legacy, %{})
    assert length(jobs()) == count
  end

  test "outer and nested rollback undo writes and notifications" do
    Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")
    config = attrs()

    assert {:error, {:abort, id}} =
             Repo.transaction(fn ->
               assert {:ok, {:ok, saved}} =
                        Repo.transaction(fn ->
                          Connect.save_credential_configuration(
                            nil,
                            config,
                            {:replace, %{api_key: "SECRET"}}
                          )
                        end)

               assert length(jobs()) == 2
               Repo.rollback({:abort, saved.credential_id})
             end)

    assert jobs() == []
    refute Repo.get_by(Credential, name: config.name)
    refute_received {:node_router_event, %{request: %{"credential_id" => ^id}}}
  end

  test "real OAuth refresh persists one notification through shared token path" do
    {server, endpoint} =
      OpenAIStub.server(
        fn conn, body ->
          assert conn.method == "POST"
          assert conn.request_path == "/v1/token"
          assert URI.decode_query(body)["refresh_token"] == "REFRESH"

          {200,
           %{access_token: "ROTATED-SECRET", refresh_token: "ROTATED-REFRESH", expires_in: 3600}}
        end,
        self()
      )

    start_supervised!(server)

    {:ok, c} =
      Connect.create_credential(
        attrs(%{
          auth_kind: "oauth2",
          client_id: "client",
          metadata: %{"token_url" => endpoint <> "/token"}
        })
      )

    {:ok, dto} =
      Connect.replace_credential_grant(c, :org, %{access_token: "OLD", refresh_token: "REFRESH"})

    g = Repo.get!(Grant, dto.grant_id)
    count = length(jobs())
    assert {:ok, refreshed} = Connect.refresh_grant(g)
    assert_receive {:openai_request, "POST", "/v1/token", _, _}
    assert refreshed.access_token == "ROTATED-SECRET"
    assert length(jobs()) == count + 1
    assert_event(List.last(jobs()), "grant_tokens_updated", c.id, g.id, "org")
    refute Jason.encode!(List.last(jobs()).args) =~ "ROTATED"
  end

  test "JWT cached token persistence emits a safe grant dependency" do
    {:ok, c} =
      Connect.create_credential(
        attrs(%{
          auth_kind: "jwt_bearer",
          issuer: "issuer",
          private_key: "SECRET",
          key_id: "kid",
          metadata: %{"auth_profile_id" => "service_account"}
        })
      )

    {:ok, g} =
      Connect.issue_grant(%{
        credential_id: c.id,
        resource_type: "mcp",
        resource_id: "1",
        owner_type: "org"
      })

    assert {:ok, _} =
             Connect.update_grant_token_cache(g, %{
               access_token: "JWT-SECRET",
               expires_at: ~U[2099-01-01 00:00:00Z]
             })

    assert_event(List.last(jobs()), "grant_tokens_updated", c.id, g.id, "org")
  end

  test "legacy nullable user and explicit org identities stay supported" do
    {:ok, c} = Connect.create_credential(attrs(%{api_key: "SECRET"}))

    for {type, owner} <- [{"user", nil}, {"org", 10}, {"user", -1}] do
      {:ok, g} =
        Connect.issue_grant(%{
          credential_id: c.id,
          resource_type: "mcp",
          resource_id: "1",
          owner_type: type,
          owner_id: owner
        })

      assert_event(List.last(jobs()), "grant_created", c.id, g.id, type, owner)
    end
  end

  test "invalid writes and invalid event kinds never leave records or jobs" do
    assert {:error, _} = Connect.create_credential(%{})
    config = attrs()

    assert {:error, :mutation_event_enqueue_failed} =
             %Credential{} |> Credential.changeset(config) |> MutationEvents.persist("invalid")

    refute Repo.get_by(Credential, name: config.name)
    assert jobs() == []
    assert {:error, :not_found} = Connect.delete_credential(%Credential{id: -1})
  end

  property "arbitrary secret-bearing metadata never enters durable or routed payload" do
    check all(secret <- string(:alphanumeric, min_length: 12, max_length: 60), max_runs: 25) do
      {:ok, c} =
        Connect.create_credential(
          attrs(%{api_key: secret, metadata: %{nested: %{token: secret}}})
        )

      job = List.last(jobs())
      assert_event(job, "credential_created", c.id)
      refute Jason.encode!(job.args) =~ secret
      assert :ok = MutationEvents.validate(job.args)

      assert {:error, :invalid_mutation_event} =
               MutationEvents.validate(Map.put(job.args, "metadata", %{secret: secret}))
    end
  end
end
