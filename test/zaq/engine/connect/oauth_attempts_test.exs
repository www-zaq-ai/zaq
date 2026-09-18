defmodule Zaq.Engine.Connect.OAuthAttemptsTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Accounts.Person
  alias Zaq.Engine.Connect

  alias Zaq.Engine.Connect.{
    Credential,
    Grant,
    OAuth,
    OAuthAttempts,
    OAuthState
  }

  alias Zaq.TestSupport.{ConnectOAuthAttemptConfig, ConnectOAuthAttemptHTTP, PersonOAuth}

  @opts [config: ConnectOAuthAttemptConfig]
  @now ~U[2026-09-14 10:00:00Z]

  setup {Req.Test, :verify_on_exit!}

  setup do
    Code.ensure_loaded!(ConnectOAuthAttemptConfig)
    person = Repo.insert!(Person.changeset(%Person{}, %{full_name: "OAuth owner"}))
    {:ok, dto} = Connect.save_credential_configuration(nil, attrs())
    %{person: person, credential: Repo.get!(Credential, dto.credential_id)}
  end

  defp attrs do
    %{
      name: "attempt-#{Ecto.UUID.generate()}",
      provider: "example",
      auth_kind: "oauth2",
      secret_binding: :grant,
      personal_credential_policy: :required,
      client_id: "admin-client",
      client_secret: "CLIENT_SECRET_SENTINEL",
      scopes: ["read"],
      metadata: %{
        "authorize_url" => "https://provider.example/authorize",
        "token_url" => "https://provider.example/token",
        "pkce" => true
      }
    }
  end

  defp start(person, credential, opts \\ @opts) do
    assert {:ok, %{authorize_url: url}} =
             PersonOAuth.start(person, credential.id, opts)

    query = URI.decode_query(URI.parse(url).query)
    {query["state"], query}
  end

  defp exchange(fun \\ fn _conn -> :ok end) do
    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      fun.(conn)

      Req.Test.json(conn, %{
        "access_token" => "ACCESS_SENTINEL",
        "refresh_token" => "REFRESH_SENTINEL"
      })
    end)
  end

  defp finish(state, extra \\ %{}, opts \\ @opts) do
    OAuthAttempts.finalize_callback(
      "example",
      Map.merge(extra, %{"state" => state, "code" => "CODE_SENTINEL"}),
      opts
    )
  end

  test "opaque state, fixed redirect, encrypted verifier, canonical event and safe result", ctx do
    {state, query} = start(ctx.person, ctx.credential)
    assert {:ok, %{"attempt_id" => id} = payload} = OAuthState.verify(state)
    assert map_size(payload) == 1
    assert byte_size(id) >= 32
    assert query["redirect_uri"] == OAuth.redirect_uri_for("example")
    assert query["scope"] == "read"
    refute Map.has_key?(query, "code_verifier")
    refute inspect(query) =~ "SECRET_SENTINEL"

    assert %{rows: [[verifier]]} =
             Repo.query!("SELECT pkce_verifier FROM connect_oauth_attempts WHERE id = $1", [id])

    assert String.starts_with?(verifier, "enc:")

    exchange(fn conn ->
      # DataCase itself wraps the test; independent-connection tests prove no IO lock.
      {:ok, body, _} = Plug.Conn.read_body(conn)
      form = URI.decode_query(body)
      assert form["client_secret"] == "CLIENT_SECRET_SENTINEL"
      assert form["redirect_uri"] == query["redirect_uri"]
      assert form["code"] == "CODE_SENTINEL"

      assert Base.url_encode64(:crypto.hash(:sha256, form["code_verifier"]), padding: false) ==
               query["code_challenge"]
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{credential_id: id, status: "active"} = dto} =
                 finish(state, %{
                   "owner_id" => 99,
                   "provider" => "evil",
                   "scope" => "admin",
                   "metadata" => %{"injected" => true},
                   "redirect_uri" => "https://evil.test"
                 })

        assert id == ctx.credential.id
        assert map_size(dto) == 2
      end)

    refute log =~ "SENTINEL"
    grant = Repo.get_by!(Grant, credential_id: ctx.credential.id, owner_type: "person")
    assert grant.owner_id == ctx.person.id
    assert grant.resource_id == to_string(ctx.credential.id)
    assert grant.scopes == ["read"]
    assert grant.metadata == %{}

    assert %{rows: [[access, refresh]]} =
             Repo.query!("SELECT access_token, refresh_token FROM connect_grants WHERE id = $1", [
               grant.id
             ])

    assert String.starts_with?(access, "enc:") and String.starts_with?(refresh, "enc:")

    assert Repo.exists?(
             from j in Oban.Job, where: fragment("?->>'grant_id'", j.args) == ^to_string(grant.id)
           )

    assert {:error, :invalid_attempt} = finish(state)
  end

  test "expires_in uses the latest function clock after the provider response", ctx do
    clock = start_supervised!({Agent, fn -> @now end})
    opts = Keyword.put(@opts, :now, fn -> Agent.get(clock, & &1) end)
    {state, _} = start(ctx.person, ctx.credential, opts)

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      Agent.update(clock, fn _ -> DateTime.add(@now, 30) end)
      Req.Test.json(conn, %{"access_token" => "clock-token", "expires_in" => 3600})
    end)

    assert {:ok, %{status: "active"}} = finish(state, %{}, opts)
    grant = Repo.get_by!(Grant, credential_id: ctx.credential.id, owner_type: "person")
    assert DateTime.compare(grant.expires_at, DateTime.add(@now, 3630)) == :eq
  end

  property "unsigned state cannot authorize a callback" do
    check all(state <- string(:alphanumeric, max_length: 100)) do
      assert {:error, :invalid_attempt} = finish(state)
    end
  end

  test "expiry is exclusive and failed claim cannot exchange", ctx do
    {state, _} = start(ctx.person, ctx.credential, Keyword.put(@opts, :now, @now))

    assert {:error, :invalid_attempt} =
             finish(state, %{}, Keyword.put(@opts, :now, DateTime.add(@now, 600)))

    assert {:error, :invalid_attempt} = finish(state)
  end

  for change <- [:policy, :config, :person, :deleted_person, :deleted_config] do
    test "#{change} invalidates attempt", ctx do
      {state, _} = start(ctx.person, ctx.credential)

      case unquote(change) do
        :policy ->
          Repo.update!(
            Ecto.Changeset.change(ctx.credential, personal_credential_policy: :disabled)
          )

        :config ->
          Repo.update!(Ecto.Changeset.change(ctx.credential, client_secret: "rotated"))

        :person ->
          Repo.update!(Person.update_changeset(ctx.person, %{status: "inactive"}))

        :deleted_person ->
          Repo.delete!(ctx.person)

        :deleted_config ->
          Repo.delete!(ctx.credential)
      end

      assert {:error, :invalid_attempt} = finish(state)
      refute Repo.exists?(from g in Grant, where: g.credential_id == ^ctx.credential.id)
    end
  end

  test "provider mismatch and tampering cannot exchange", ctx do
    {state, _} = start(ctx.person, ctx.credential)
    assert {:error, :invalid_attempt} = finish(state <> "x")

    assert {:error, :invalid_attempt} =
             OAuthAttempts.finalize_callback("other", %{"state" => state, "code" => "x"}, @opts)
  end

  test "expired signature and simultaneous code/error fail closed", ctx do
    {state, _} = start(ctx.person, ctx.credential)
    {:ok, payload} = OAuthState.verify(state)

    expired =
      Phoenix.Token.sign(ZaqWeb.Endpoint, "zaq.connect.oauth2.state", payload,
        signed_at: DateTime.to_unix(DateTime.utc_now()) - 601
      )

    assert {:error, :invalid_attempt} = finish(expired)
    assert {:error, :invalid_attempt} = finish(state, %{"error" => "denied"})
    assert {:error, :invalid_attempt} = finish(state)
  end

  test "reconnect failure consumes attempt and retains previous slot; success reuses ID", ctx do
    {:ok, original} =
      Connect.replace_credential_grant(ctx.credential, {:person, ctx.person.id}, %{
        access_token: "previous",
        refresh_token: "previous-refresh"
      })

    {:ok, %{authorize_url: url}} =
      PersonOAuth.reconnect(ctx.person, ctx.credential.id, @opts)

    state = URI.decode_query(URI.parse(url).query)["state"]

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"secret" => "PROVIDER_SECRET_SENTINEL"})
    end)

    assert {:error, :oauth_failed} = finish(state)
    assert {:error, :invalid_attempt} = finish(state)
    assert Repo.get!(Grant, original.grant_id).access_token == "previous"
    {state, _} = start(ctx.person, ctx.credential)
    exchange()
    assert {:ok, _} = finish(state)
    assert Repo.get!(Grant, original.grant_id).access_token == "ACCESS_SENTINEL"

    assert Repo.aggregate(from(g in Grant, where: g.credential_id == ^ctx.credential.id), :count) ==
             1
  end

  test "changes during exchange reject finalization and preserve previous grant", ctx do
    {:ok, original} =
      Connect.replace_credential_grant(ctx.credential, {:person, ctx.person.id}, %{
        access_token: "previous"
      })

    {state, _} = start(ctx.person, ctx.credential)
    exchange(fn _ -> Repo.update!(Person.update_changeset(ctx.person, %{status: "inactive"})) end)
    assert {:error, :invalid_attempt} = finish(state)
    assert Repo.get!(Grant, original.grant_id).access_token == "previous"
    assert {:error, :invalid_attempt} = finish(state)
  end

  test "canonical global setup is transient until complete for disabled/optional/required" do
    for policy <- [:disabled, :optional, :required] do
      attrs = Map.put(attrs(), :personal_credential_policy, policy)

      assert {:ok, %{authorize_url: url}} =
               OAuthAttempts.start_global_configuration(nil, attrs, @opts)

      refute Repo.get_by(Credential, name: attrs.name)
      state = URI.decode_query(URI.parse(url).query)["state"]
      assert {:ok, %{"attempt_id" => id}} = OAuthState.verify(state)

      assert %{rows: [[candidate]]} =
               Repo.query!("SELECT candidate_config FROM connect_oauth_attempts WHERE id = $1", [
                 id
               ])

      assert String.starts_with?(candidate, "enc:")
      exchange()
      assert {:ok, %{credential_id: id, status: "active"}} = finish(state)
      config = Repo.get!(Credential, id)
      assert config.personal_credential_policy == policy
      grant = Repo.get_by!(Grant, credential_id: id, owner_type: "org")
      assert is_nil(grant.owner_id)
      assert grant.access_token == "ACCESS_SENTINEL"
    end
  end

  test "global reconnect stages config until exchange", ctx do
    {:ok, original} =
      Connect.replace_credential_grant(ctx.credential, :org, %{access_token: "previous"})

    assert {:ok, %{authorize_url: url}} =
             OAuthAttempts.start_global_configuration(
               ctx.credential.id,
               %{client_id: "new-client"},
               @opts
             )

    assert Repo.reload!(ctx.credential).client_id == "admin-client"
    state = URI.decode_query(URI.parse(url).query)["state"]
    exchange()
    assert {:ok, _} = finish(state)
    assert Repo.reload!(ctx.credential).client_id == "new-client"
    assert Repo.get!(Grant, original.grant_id).access_token == "ACCESS_SENTINEL"
  end

  test "missing encryption key rejects start without plaintext persistence", ctx do
    Code.ensure_loaded!(Zaq.TestSupport.ConnectEncryptionConfig)
    opts = [config: Zaq.TestSupport.ConnectEncryptionConfig, encryption_config: []]
    before_count = Repo.aggregate(Zaq.Engine.Connect.OAuthAttempt, :count)

    assert {:error, :encryption_failed} =
             PersonOAuth.start(ctx.person, ctx.credential.id, opts)

    assert {:error, :encryption_failed} =
             OAuthAttempts.start_global_configuration(nil, attrs(), opts)

    assert Repo.aggregate(Zaq.Engine.Connect.OAuthAttempt, :count) == before_count
  end

  test "unsupported provider authorization consumes its transient attempt without publishing state",
       ctx do
    {:ok, _} = Connect.save_credential_configuration(ctx.credential, %{metadata: %{}})
    Phoenix.PubSub.subscribe(Zaq.PubSub, "node_router:events")

    assert {:error, :oauth_failed} =
             PersonOAuth.start(ctx.person, ctx.credential.id, @opts)

    attempt = Repo.get_by!(Zaq.Engine.Connect.OAuthAttempt, credential_id: ctx.credential.id)
    refute is_nil(attempt.claimed_at)
    assert is_nil(attempt.pkce_verifier)
    refute_received {:node_router_event, %Zaq.Event{request: %{provider: "example", params: _}}}
  end

  test "server origin is bound and a base URL change invalidates the attempt", ctx do
    assert :ok = Zaq.System.set_global_base_url("https://zaq.example")
    {state, query} = start(ctx.person, ctx.credential)
    assert query["redirect_uri"] == "https://zaq.example/channels/oauth2/example/redirect"
    assert :ok = Zaq.System.set_global_base_url("https://new.example")
    assert {:error, :invalid_attempt} = finish(state)
    assert :ok = Zaq.System.set_global_base_url("https://zaq.example?redirect=evil")

    assert {:error, :invalid_configuration} =
             PersonOAuth.start(ctx.person, ctx.credential.id, @opts)
  end

  test "clock advances during exchange: deadline is rechecked before persistence", ctx do
    clock = start_supervised!({Agent, fn -> @now end})
    opts = Keyword.put(@opts, :now, fn -> Agent.get(clock, & &1) end)
    {state, _} = start(ctx.person, ctx.credential, opts)
    exchange(fn _ -> Agent.update(clock, &DateTime.add(&1, 600)) end)
    assert {:error, :invalid_attempt} = finish(state, %{}, opts)
    refute Repo.get_by(Grant, credential_id: ctx.credential.id)
  end

  test "cancel consumes and erases attempt; legacy owner state cannot bypass trusted starts",
       ctx do
    {state, _} = start(ctx.person, ctx.credential)

    assert {:error, :invalid_attempt} =
             OAuthAttempts.finalize_callback(
               "example",
               %{"state" => state, "error" => "SECRET_SENTINEL"},
               @opts
             )

    assert {:error, :invalid_attempt} = finish(state)
    assert {:ok, %{"attempt_id" => id}} = OAuthState.verify(state)

    assert %{rows: [[nil, nil]]} =
             Repo.query!(
               "SELECT pkce_verifier, candidate_config FROM connect_oauth_attempts WHERE id = $1",
               [id]
             )

    assert {:error, :person_management_required} =
             OAuth.build_authorize_url(ctx.credential, %{
               owner_type: "person",
               owner_id: ctx.person.id
             })

    old =
      OAuthState.sign(%{
        "owner_type" => "person",
        "owner_id" => ctx.person.id,
        "provider" => "example",
        "credential_id" => ctx.credential.id
      })

    assert {:error, :person_management_required} =
             OAuth.finalize_callback("example", %{"state" => old, "code" => "code"})

    assert {:error, :invalid_attempt} =
             finish(OAuthState.sign(%{"attempt_id" => id, "owner_id" => ctx.person.id}))

    assert {:error, :invalid_attempt} = finish(OAuthState.sign(%{"attempt_id" => 123}))
    assert {:error, :invalid_attempt} = OAuthAttempts.finalize_callback(nil, %{}, @opts)
  end

  test "start rejects unavailable configuration, policy and caller transactions", ctx do
    for attrs <- [
          %{personal_credential_policy: :disabled},
          %{secret_binding: :configuration},
          %{auth_kind: "api_key"}
        ] do
      changed = Repo.update!(Ecto.Changeset.change(ctx.credential, attrs))
      assert {:error, :not_found} = PersonOAuth.start(ctx.person, changed.id, @opts)
      Repo.update!(Ecto.Changeset.change(changed, Map.take(ctx.credential, Map.keys(attrs))))
    end

    assert {:error, :not_found} = PersonOAuth.start(ctx.person, -1, @opts)
    assert {:error, :not_found} = PersonOAuth.start(ctx.person, 2_147_483_647, @opts)
    {state, _} = start(ctx.person, ctx.credential)

    Repo.transaction(fn ->
      assert {:error, :transaction_not_allowed} =
               PersonOAuth.start(ctx.person, ctx.credential.id, @opts)

      assert {:error, :transaction_not_allowed} = finish(state)
    end)

    exchange()
    assert {:ok, _} = finish(state)
  end

  test "failed and malformed external responses never leak and consume the attempt", ctx do
    for failure <- [:raise, :throw, :exit, :missing_token, :expired_token] do
      {state, _} = start(ctx.person, ctx.credential)

      Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
        case failure do
          :raise ->
            raise "PROVIDER_SECRET_SENTINEL"

          :throw ->
            throw("PROVIDER_SECRET_SENTINEL")

          :exit ->
            exit("PROVIDER_SECRET_SENTINEL")

          :missing_token ->
            Req.Test.json(conn, %{"refresh_token" => "PROVIDER_SECRET_SENTINEL"})

          :expired_token ->
            Req.Test.json(conn, %{
              "access_token" => "PROVIDER_SECRET_SENTINEL",
              "expires_in" => -60
            })
        end
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, reason} = finish(state)
          assert reason in [:oauth_failed, :invalid_attempt]
        end)

      refute log =~ "SENTINEL"
      assert {:error, :invalid_attempt} = finish(state)
      refute Repo.get_by(Grant, credential_id: ctx.credential.id)
    end
  end

  test "provider returned owner resource scopes and metadata never override canonical binding",
       ctx do
    {state, _} = start(ctx.person, ctx.credential)

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      Req.Test.json(conn, %{
        "access_token" => "token",
        "owner_type" => "org",
        "owner_id" => 999,
        "resource_type" => "mcp",
        "resource_id" => "attacker",
        "provider" => "evil",
        "credential_id" => 999,
        "scopes" => ["admin"],
        "metadata" => %{"client_secret" => "injected"}
      })
    end)

    assert {:ok, _} = finish(state)
    grant = Repo.get_by!(Grant, credential_id: ctx.credential.id)
    assert grant.owner_type == "person" and grant.owner_id == ctx.person.id

    assert grant.resource_type == "connect_credential" and
             grant.resource_id == to_string(ctx.credential.id)

    assert grant.provider == "example" and grant.scopes == ["read"] and grant.metadata == %{}
  end

  test "corrupt encrypted verifier and setup candidate fail closed", ctx do
    {state, _} = start(ctx.person, ctx.credential)
    assert {:ok, %{"attempt_id" => id}} = OAuthState.verify(state)

    Repo.query!("UPDATE connect_oauth_attempts SET pkce_verifier = $1 WHERE id = $2", [
      "enc:invalid",
      id
    ])

    assert {:error, :invalid_attempt} = finish(state)
    {:ok, %{authorize_url: url}} = OAuthAttempts.start_global_configuration(nil, attrs(), @opts)
    state = URI.decode_query(URI.parse(url).query)["state"]
    assert {:ok, %{"attempt_id" => id}} = OAuthState.verify(state)

    Repo.query!("UPDATE connect_oauth_attempts SET candidate_config = $1 WHERE id = $2", [
      "enc:invalid",
      id
    ])

    assert {:error, :invalid_attempt} = finish(state)
  end

  test "admin setup validates candidate without persisting incomplete config or accepting injected fields",
       ctx do
    for changes <- [
          %{auth_kind: "api_key"},
          %{secret_binding: :configuration},
          %{owner_id: ctx.person.id},
          %{client_secret: ""},
          %{scopes: nil},
          %{metadata: %{"client_secret" => "injected"}},
          %{metadata: %{"pkce" => "true"}},
          %{metadata: %{"authorize_params" => %{"state" => "injected"}}}
        ] do
      candidate = Map.merge(attrs(), changes)

      assert {:error, :invalid_configuration} =
               OAuthAttempts.start_global_configuration(nil, candidate, @opts)

      refute Repo.get_by(Credential, name: candidate.name)
    end

    {:ok, _} =
      Connect.replace_credential_grant(ctx.credential, {:person, ctx.person.id}, %{
        access_token: "previous"
      })

    assert {:error, :incompatible_live_grants} =
             OAuthAttempts.start_global_configuration(
               ctx.credential.id,
               %{client_id: "changed"},
               @opts
             )

    assert {:error, :not_found} =
             OAuthAttempts.start_global_configuration(2_147_483_647, %{}, @opts)

    candidate =
      Map.put(attrs(), :metadata, %{
        "authorize_url" => "https://provider.example/auth",
        "token_url" => "https://provider.example/token",
        "authorize_params" => %{"prompt" => "consent"}
      })

    assert {:ok, %{authorize_url: url}} =
             OAuthAttempts.start_global_configuration(nil, candidate, @opts)

    assert URI.decode_query(URI.parse(url).query)["prompt"] == "consent"
  end

  test "failed global exchange never creates a config; stale admin candidate never overwrites edits",
       ctx do
    candidate = Map.put(attrs(), :personal_credential_policy, :optional)
    {:ok, %{authorize_url: url}} = OAuthAttempts.start_global_configuration(nil, candidate, @opts)
    state = URI.decode_query(URI.parse(url).query)["state"]

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{})
    end)

    assert {:error, :oauth_failed} = finish(state)
    refute Repo.get_by(Credential, name: candidate.name)

    {:ok, %{authorize_url: url}} =
      OAuthAttempts.start_global_configuration(ctx.credential.id, %{client_id: "staged"}, @opts)

    state = URI.decode_query(URI.parse(url).query)["state"]

    {:ok, _} =
      Connect.save_credential_configuration(ctx.credential, %{
        name: "changed-#{Ecto.UUID.generate()}"
      })

    assert {:error, :invalid_attempt} = finish(state)
    assert Repo.reload!(ctx.credential).client_id == "admin-client"
  end
end
