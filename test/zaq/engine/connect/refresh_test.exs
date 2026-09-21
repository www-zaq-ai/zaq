defmodule Zaq.Engine.Connect.RefreshTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties
  import Ecto.Query

  alias Zaq.Accounts.Person
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Credential, Grant, GrantRefreshWorker, Refresh}
  alias Zaq.System.SecretConfig
  alias Zaq.TestSupport.{ConnectOAuthAttemptConfig, ConnectOAuthAttemptHTTP}

  @now ~U[2026-09-14 12:00:00Z]
  @opts [config: ConnectOAuthAttemptConfig, now: @now]
  setup {Req.Test, :verify_on_exit!}

  setup do
    Code.ensure_loaded!(ConnectOAuthAttemptConfig)
    person = Repo.insert!(Person.changeset(%Person{}, %{full_name: "Refresh"}))

    {:ok, dto} =
      Connect.save_credential_configuration(nil, %{
        name: "refresh-#{Ecto.UUID.generate()}",
        provider: "example",
        auth_kind: "oauth2",
        secret_binding: :grant,
        personal_credential_policy: :required,
        client_id: "client",
        metadata: %{"token_url" => "https://provider.example/token"}
      })

    credential = Repo.get!(Credential, dto.credential_id)

    {:ok, dto} =
      Connect.replace_credential_grant(credential, {:person, person.id}, %{
        access_token: "old-access",
        refresh_token: "old-refresh"
      })

    %{person: person, credential: credential, grant: Repo.get!(Grant, dto.grant_id)}
  end

  for refresh <- [nil, "rotated-refresh"] do
    test "successful refresh retains omitted or rotates provided key: #{inspect(refresh)}", %{
      grant: grant
    } do
      Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert URI.decode_query(body)["refresh_token"] == "old-refresh"

        Req.Test.json(conn, %{
          "access_token" => "new-access",
          "refresh_token" => unquote(refresh),
          "expires_in" => 3600
        })
      end)

      assert {:ok, updated} = Connect.refresh_grant(grant, @opts)
      assert updated.access_token == "new-access"
      assert updated.refresh_token == (unquote(refresh) || "old-refresh")
      assert updated.expires_at == ~U[2026-09-14 13:00:00Z]
      assert updated.refresh_claim == nil
    end
  end

  test "future and no expiration reuse cache; exact skew threshold refreshes", %{grant: grant} do
    assert {:ok, %{access_token: "old-access"}} = Connect.prepare_grant_for_use(grant, @opts)
    grant = Repo.update!(Ecto.Changeset.change(grant, expires_at: DateTime.add(@now, 61)))
    assert {:ok, %{access_token: "old-access"}} = Connect.prepare_grant_for_use(grant, @opts)
    grant = Repo.update!(Ecto.Changeset.change(grant, expires_at: DateTime.add(@now, 60)))
    success()
    assert {:ok, %{access_token: "new-access"}} = Connect.prepare_grant_for_use(grant, @opts)
  end

  test "expired status is recoverable with refresh material", %{grant: grant} do
    grant = Repo.update!(Ecto.Changeset.change(grant, status: "expired", expires_at: @now))
    success()
    assert {:ok, %{status: "active"}} = Connect.prepare_grant_for_use(grant, @opts)
    assert Enum.any?(Connect.expiring_oauth_grants(@now, 4000), &(&1.id == grant.id))
  end

  test "revoked stale structs and direct canonical cache updates reject", %{
    grant: grant,
    credential: credential,
    person: person
  } do
    assert {:error, :canonical_refresh_required} =
             Connect.update_grant_token_cache(grant, %{access_token: "bypass"})

    assert {:ok, _} = Connect.revoke_credential_grant(credential, {:person, person.id})
    assert {:error, :revoked} = Connect.refresh_grant(grant, @opts)
    assert {:error, :revoked} = Connect.prepare_grant_for_use(grant, @opts)
    assert {:error, :revoked} = Connect.update_grant_token_cache(grant, %{access_token: "bypass"})
  end

  test "stale deleted/inactive literal Person rejects even cached use", %{
    grant: grant,
    person: person
  } do
    Repo.update!(Person.update_changeset(person, %{status: "inactive"}))
    assert {:error, :person_unavailable} = Connect.prepare_grant_for_use(grant, @opts)
    Repo.delete!(person)
    assert {:error, :person_unavailable} = Connect.refresh_grant(grant, @opts)
  end

  for field <- [:refresh_token, :client_secret] do
    test "invalid #{field} ciphertext fails before HTTP", %{grant: grant, credential: credential} do
      {table, id} =
        if unquote(field) == :refresh_token,
          do: {"connect_grants", grant.id},
          else: {"connect_credentials", credential.id}

      Repo.query!("UPDATE #{table} SET #{unquote(field)} = 'enc:v1:broken' WHERE id = $1", [id])
      assert {:error, :authentication_required} = Connect.refresh_grant(grant, @opts)
    end
  end

  for response <- [:timeout, :unauthorized, :malformed] do
    test "#{response} is sanitized and repeated attempts are bounded", %{grant: grant} do
      Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
        case unquote(response) do
          :timeout ->
            Req.Test.transport_error(conn, :timeout)

          :unauthorized ->
            conn
            |> Plug.Conn.put_status(401)
            |> Req.Test.json(%{
              "error" => %{
                "code" => "secret_token_value",
                "message" => "never-expose"
              }
            })

          :malformed ->
            Req.Test.json(conn, %{"access_token" => ["never-expose"]})
        end
      end)

      assert {:error, reason} = Connect.refresh_grant(grant, @opts)

      if unquote(response) == :unauthorized do
        assert reason == {:oauth_refresh_failed, 401}
      else
        assert reason in [:refresh_failed, :invalid_material, :invalid_refresh_response]
      end

      assert {:error, :refresh_busy} = Connect.refresh_grant(grant, @opts)
      assert Repo.get!(Grant, grant.id).access_token == "old-access"
    end
  end

  test "worker surfaces a safe provider refresh code without its response body", %{grant: grant} do
    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{
        "error" => %{
          "code" => "refresh_token_reused",
          "message" => "secret response detail",
          "param" => "refresh_token"
        }
      })
    end)

    result =
      GrantRefreshWorker.perform(%Oban.Job{args: %{"grant_id" => grant.id}}, @opts)

    assert result ==
             {:error, {:oauth_refresh_failed, 401, %{code: "refresh_token_reused"}}}

    refute inspect(result) =~ "secret response detail"
    refute inspect(result) =~ "param"
  end

  test "refresh sanitizes nested atom-key provider errors", %{
    grant: grant,
    credential: credential
  } do
    parent = self()
    ref = make_ref()

    dispatch = fn current, received_credential, received_opts ->
      send(
        parent,
        {ref, :dispatch, current.id, received_credential.id, received_opts,
         Repo.in_transaction?()}
      )

      {:error,
       {:oauth_refresh_failed, 401,
        %{
          error: %{
            code: "  refresh_token_reused  ",
            message: "NESTED_SECRET_SENTINEL",
            param: "refresh_token"
          },
          debug: "OUTER_SECRET_SENTINEL"
        }}}
    end

    persist = fn _current, _received_credential, _payload, _received_opts ->
      send(parent, {ref, :unexpected_persist})
      {:error, :invalid_material}
    end

    assert {:error, {:oauth_refresh_failed, 401, %{code: "refresh_token_reused"}}} =
             Refresh.run(grant, dispatch, persist, @opts)

    assert_received {^ref, :dispatch, grant_id, credential_id, @opts, false}
    assert grant_id == grant.id
    assert credential_id == credential.id
    refute_received {^ref, :unexpected_persist}
    assert_failed_refresh_state(grant)
    assert token_update_count(grant) == 0
    assert {:error, :refresh_busy} = Connect.refresh_grant(grant, @opts)
  end

  test "refresh sanitizes scalar atom-key provider errors", %{
    grant: grant,
    credential: credential
  } do
    parent = self()
    ref = make_ref()

    dispatch = fn current, received_credential, received_opts ->
      send(
        parent,
        {ref, :dispatch, current.id, received_credential.id, received_opts,
         Repo.in_transaction?()}
      )

      {:error,
       {:oauth_refresh_failed, 400,
        %{error: " invalid_grant ", error_description: "SCALAR_SECRET_SENTINEL"}}}
    end

    persist = fn _current, _received_credential, _payload, _received_opts ->
      send(parent, {ref, :unexpected_persist})
      {:error, :invalid_material}
    end

    assert {:error, {:oauth_refresh_failed, 400, %{code: "invalid_grant"}}} =
             Refresh.run(grant, dispatch, persist, @opts)

    assert_received {^ref, :dispatch, grant_id, credential_id, @opts, false}
    assert grant_id == grant.id
    assert credential_id == credential.id
    refute_received {^ref, :unexpected_persist}
    assert_failed_refresh_state(grant)
    assert token_update_count(grant) == 0
    assert {:error, :refresh_busy} = Connect.refresh_grant(grant, @opts)
  end

  test "refresh discards a nested nonbinary provider error code", %{grant: grant} do
    parent = self()

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:request, conn.method, conn.request_path, URI.decode_query(body)})

      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"error" => %{"code" => 123, "message" => "CODE_SECRET_SENTINEL"}})
    end)

    assert {:error, {:oauth_refresh_failed, 401}} = Connect.refresh_grant(grant, @opts)
    assert_received {:request, "POST", "/token", form}
    assert form["grant_type"] == "refresh_token"
    assert form["refresh_token"] == "old-refresh"
    assert form["client_id"] == "client"
    assert_failed_refresh_state(grant)
    assert token_update_count(grant) == 0
    assert {:error, :refresh_busy} = Connect.refresh_grant(grant, @opts)
  end

  test "refresh discards a scalar null provider error code", %{grant: grant} do
    parent = self()

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:request, conn.method, conn.request_path, URI.decode_query(body)})

      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"error" => nil, "error_description" => "NIL_SECRET_SENTINEL"})
    end)

    assert {:error, {:oauth_refresh_failed, 401}} = Connect.refresh_grant(grant, @opts)
    assert_received {:request, "POST", "/token", form}
    assert form["grant_type"] == "refresh_token"
    assert form["refresh_token"] == "old-refresh"
    assert form["client_id"] == "client"
    assert_failed_refresh_state(grant)
    assert token_update_count(grant) == 0
    assert {:error, :refresh_busy} = Connect.refresh_grant(grant, @opts)
  end

  property "nonbinary provider error codes are never exposed", %{credential: credential} do
    check all(
            code <-
              one_of([
                constant(nil),
                boolean(),
                integer(-100..100),
                list_of(integer(-10..10), max_length: 3)
              ]),
            max_runs: 15
          ) do
      {:ok, legacy} =
        Connect.issue_grant(%{
          credential_id: credential.id,
          resource_type: "mcp",
          resource_id: "refresh-code-#{Ecto.UUID.generate()}",
          owner_type: "org",
          owner_id: nil,
          access_token: "old-access",
          refresh_token: "old-refresh"
        })

      legacy = Repo.get!(Grant, legacy.id)
      parent = self()

      Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:property_request, URI.decode_query(body)})

        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => %{"code" => code, "message" => "PROPERTY_SECRET_SENTINEL"}})
      end)

      assert {:error, {:oauth_refresh_failed, 401}} = Connect.refresh_grant(legacy, @opts)
      assert_received {:property_request, form}
      assert form["refresh_token"] == "old-refresh"

      persisted = Repo.get!(Grant, legacy.id)
      assert persisted.access_token == "old-access"
      assert persisted.refresh_token == "old-refresh"
      assert persisted.status == "active"
    end
  end

  test "legacy cache rejects stale caller material with unreadable ciphertext", %{
    credential: credential
  } do
    {:ok, legacy} =
      Connect.issue_grant(%{
        credential_id: credential.id,
        resource_type: "mcp",
        resource_id: "legacy-cache-#{Ecto.UUID.generate()}",
        owner_type: "org",
        owner_id: nil,
        access_token: "legacy-current-access",
        refresh_token: "legacy-current-refresh"
      })

    legacy = Repo.get!(Grant, legacy.id)
    stale = %{legacy | access_token: "enc:v1:broken"}

    assert {:error, :stale_grant} =
             Connect.update_grant_token_cache(stale, %{
               access_token: "must-not-store",
               expires_at: ~U[2099-01-01 00:00:00Z]
             })

    persisted = Repo.get!(Grant, legacy.id)
    assert persisted.access_token == "legacy-current-access"
    assert persisted.refresh_token == "legacy-current-refresh"
    assert persisted.expires_at == nil
    assert persisted.refresh_claim == nil
    assert persisted.refresh_claim_until == nil
    assert token_update_count(legacy) == 0
  end

  test "expired lease recovers without trusting old claim", %{grant: grant} do
    Repo.update!(
      Ecto.Changeset.change(grant,
        refresh_claim: Ecto.UUID.generate(),
        refresh_claim_until: DateTime.add(@now, 120)
      )
    )

    assert {:error, :refresh_busy} = Connect.refresh_grant(grant, @opts)
    success()

    assert {:ok, %{access_token: "new-access"}} =
             Connect.refresh_grant(grant, Keyword.put(@opts, :now, DateTime.add(@now, 120)))
  end

  test "network cannot run inside caller transaction", %{grant: grant} do
    assert {:ok, {:error, :refresh_requires_committed_state}} =
             Repo.transaction(fn -> Connect.refresh_grant(grant, @opts) end)
  end

  for owner <- ["org", "user"] do
    test "legacy #{owner} resource grants use real refresh and guard stale cache writes", %{
      credential: credential
    } do
      {:ok, legacy} =
        Connect.issue_grant(%{
          credential_id: credential.id,
          resource_type: "mcp",
          resource_id: "legacy",
          owner_type: unquote(owner),
          owner_id: nil,
          access_token: "old",
          refresh_token: "refresh"
        })

      success()
      legacy = Repo.update!(Ecto.Changeset.change(legacy, status: "expired"))
      assert {:ok, refreshed} = Connect.refresh_grant(legacy, @opts)
      assert refreshed.access_token == "new-access"
      assert refreshed.status == "active"

      assert {:error, :stale_grant} =
               Connect.update_grant_token_cache(legacy, %{
                 access_token: "old-result",
                 expires_at: ~U[2099-01-01 00:00:00Z]
               })

      assert {:ok, _} = Connect.revoke_grant(refreshed)
      assert {:error, :revoked} = Connect.refresh_grant(legacy, @opts)

      assert {:error, :revoked} =
               Connect.update_grant_token_cache(refreshed, %{access_token: "bypass"})
    end
  end

  test "enc-prefixed refresh material is literal and cannot resurrect an old token", %{
    credential: credential,
    person: person
  } do
    {:ok, old_ciphertext} = SecretConfig.encrypt("retired-secret")

    {:ok, dto} =
      Connect.replace_credential_grant(credential, {:person, person.id}, %{
        access_token: "current",
        refresh_token: old_ciphertext
      })

    grant = Repo.get!(Grant, dto.grant_id)

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert URI.decode_query(body)["refresh_token"] == old_ciphertext
      Req.Test.json(conn, %{"access_token" => "enc:provider-literal", "expires_in" => 3600})
    end)

    assert {:ok, %{access_token: "enc:provider-literal", refresh_token: ^old_ciphertext}} =
             Connect.refresh_grant(grant, @opts)
  end

  test "missing refresh material cannot recover expiry and deleted grant cannot be cached", %{
    grant: grant
  } do
    Repo.update!(Ecto.Changeset.change(grant, refresh_token: nil, expires_at: @now))
    assert {:error, :authentication_required} = Connect.prepare_grant_for_use(grant, @opts)
    Repo.delete!(grant)
    assert {:error, :not_found} = Connect.prepare_grant_for_use(grant, @opts)

    assert {:error, :not_found} =
             Connect.update_grant_token_cache(grant, %{access_token: "bypass"})
  end

  test "worker retry backoff exceeds claim TTL and scheduling retains bounded attempts", %{
    grant: grant
  } do
    assert {:ok, job} = Connect.schedule_refresh(grant)
    assert job.max_attempts == 3
    assert Connect.GrantRefreshWorker.backoff(%Oban.Job{attempt: 1}) >= 120
  end

  test "scheduling is unique per grant while a refresh job is pending", %{grant: grant} do
    assert {:ok, first} = Connect.schedule_refresh(grant)
    assert {:ok, second} = Connect.schedule_refresh(grant)
    assert second.id == first.id
    assert second.conflict?
  end

  test "proactive scheduling excludes grants with an active refresh lease", %{grant: grant} do
    grant =
      Repo.update!(
        Ecto.Changeset.change(grant,
          expires_at: @now,
          refresh_claim: Ecto.UUID.generate(),
          refresh_claim_until: DateTime.add(@now, 120)
        )
      )

    refute Enum.any?(Connect.expiring_oauth_grants(@now, 600), &(&1.id == grant.id))

    assert Enum.any?(
             Connect.expiring_oauth_grants(DateTime.add(@now, 120), 600),
             &(&1.id == grant.id)
           )
  end

  for mode <- [:raise, :throw] do
    test "HTTP #{mode} never exposes secrets", %{grant: grant} do
      Req.Test.expect(ConnectOAuthAttemptHTTP, fn _conn ->
        case unquote(mode) do
          :raise -> raise "secret"
          :throw -> throw("secret")
        end
      end)

      assert {:error, :refresh_failed} = Connect.refresh_grant(grant, @opts)
    end
  end

  test "incompatible canonical config rejects before cached or external token use", %{
    grant: grant,
    credential: credential
  } do
    Repo.update!(Ecto.Changeset.change(credential, scopes: ["changed"]))
    assert {:error, :stale_grant} = Connect.prepare_grant_for_use(grant, @opts)
    assert {:error, :stale_grant} = Connect.refresh_grant(grant, @opts)
  end

  test "unreadable access token may recover using valid refresh material", %{grant: grant} do
    Repo.query!("UPDATE connect_grants SET access_token = 'enc:v1:broken' WHERE id = $1", [
      grant.id
    ])

    success()
    assert {:ok, %{access_token: "new-access"}} = Connect.prepare_grant_for_use(grant, @opts)
  end

  for canonical? <- [true, false] do
    test "#{canonical?} canonical: encryption failure cannot store response or erase previous token",
         %{credential: credential, grant: canonical} do
      grant =
        if unquote(canonical?) do
          canonical
        else
          {:ok, legacy} =
            Connect.issue_grant(%{
              credential_id: credential.id,
              resource_type: "mcp",
              resource_id: "encryption",
              owner_type: "user",
              access_token: "old-access",
              refresh_token: "old-refresh"
            })

          legacy
        end

      success()
      opts = [config: Zaq.TestSupport.ConnectRefreshConfig, encryption_config: [], now: @now]
      Code.ensure_loaded!(Zaq.TestSupport.ConnectRefreshConfig)
      assert {:error, reason} = Connect.refresh_grant(grant, opts)
      assert reason in [:encryption_failed, :invalid_refresh_response]
      assert Repo.get!(Grant, grant.id).access_token == "old-access"
    end
  end

  test "provider success without access token is malformed", %{grant: grant} do
    Req.Test.expect(ConnectOAuthAttemptHTTP, &Req.Test.json(&1, %{"expires_in" => 3600}))
    assert {:error, :invalid_refresh_response} = Connect.refresh_grant(grant, @opts)
    assert Repo.get!(Grant, grant.id).access_token == "old-access"
  end

  property "revoked never becomes usable at any expiry", %{grant: grant} do
    check all(delta <- integer(-10_000..10_000), max_runs: 15) do
      Repo.update!(
        Ecto.Changeset.change(Repo.get!(Grant, grant.id),
          status: "revoked",
          expires_at: DateTime.add(@now, delta)
        )
      )

      assert {:error, :revoked} = Connect.prepare_grant_for_use(grant, @opts)
    end
  end

  defp success do
    Req.Test.expect(
      ConnectOAuthAttemptHTTP,
      &Req.Test.json(&1, %{"access_token" => "new-access", "expires_in" => 3600})
    )
  end

  defp assert_failed_refresh_state(grant) do
    persisted = Repo.get!(Grant, grant.id)
    assert persisted.access_token == "old-access"
    assert persisted.refresh_token == "old-refresh"
    assert persisted.status == "active"
    assert is_binary(persisted.refresh_claim)
    assert persisted.refresh_claim_until == DateTime.add(@now, 120)
  end

  defp token_update_count(grant) do
    Repo.aggregate(
      from(j in Oban.Job,
        where:
          j.queue == "connect_credential_notifications" and
            fragment("?->>'grant_id'", j.args) == ^to_string(grant.id) and
            fragment("?->>'kind'", j.args) == "grant_tokens_updated"
      ),
      :count
    )
  end
end
