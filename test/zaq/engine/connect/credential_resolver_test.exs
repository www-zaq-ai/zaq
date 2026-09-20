defmodule Zaq.Engine.Connect.CredentialResolverTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Accounts.Person
  alias Zaq.Engine.Api
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Grant, PersonCredentials}
  alias Zaq.Event
  alias Zaq.System.SecretConfig
  alias Zaq.TestSupport.{ConnectOAuthAttemptConfig, ConnectOAuthAttemptHTTP}

  @now ~U[2026-09-14 12:00:00Z]
  @opts [now: @now, config: ConnectOAuthAttemptConfig]
  @states [:absent, :active, :revoked, :expired]
  setup {Req.Test, :verify_on_exit!}

  setup do
    Code.ensure_loaded!(ConnectOAuthAttemptConfig)
    %{person: Repo.insert!(Person.changeset(%Person{}, %{full_name: "Resolver"}))}
  end

  # Explicitly generated 2 actors x 3 policies x 4 personal x 4 global states.
  for person? <- [true, false],
      policy <- [:disabled, :optional, :required],
      personal <- @states,
      global <- @states do
    @person? person?
    @policy policy
    @personal personal
    @global global
    @selected (cond do
                 not person? or policy == :disabled -> {:org, global}
                 personal != :absent -> {:person, personal}
                 policy == :required -> {:error, :personal_credential_required}
                 true -> {:org, global}
               end)
    test "matrix person=#{person?} policy=#{policy} personal=#{personal} global=#{global}", %{
      person: person
    } do
      c = credential(@policy)
      p = slot(c, {:person, person.id}, @personal)
      g = slot(c, :org, @global)
      actor = if @person?, do: %{person: %{id: person.id}}, else: nil
      result = Connect.resolve_credential(c, actor, @opts)

      case @selected do
        {:error, reason} ->
          assert result == error(c, reason)

        {:org, :absent} ->
          assert result == error(c, :global_credential_missing)

        {owner, :revoked} ->
          assert result == error(c, :credential_revoked, to_string(owner))

        {owner, :expired} ->
          assert result == error(c, :credential_expired, to_string(owner))

        {owner, :active} ->
          selected = Map.fetch!(%{person: p, org: g}, owner)
          assert {:ok, resolved} = result
          assert resolved.credential_id == c.id
          assert resolved.grant_id == selected.id
          assert resolved.owner_type == to_string(owner)
          assert resolved.owner_id == selected.owner_id
          assert resolved.authentication == %{api_key: "#{owner}-secret"}
      end
    end
  end

  # Fifteen concrete table scenarios supplement the lifecycle matrix.
  for {label, change, reason} <- [
        {"blank key", {:grant, :api_key, " "}, :credential_unavailable},
        {"missing key", {:grant, :api_key, nil}, :credential_unavailable},
        {"masked key", {:grant, :api_key, "••••••••"}, :credential_unavailable},
        {"unknown status", {:grant, :status, "broken"}, :credential_unavailable},
        {"provider mismatch", {:grant, :provider, "other"}, :credential_unavailable},
        {"kind mismatch", {:grant, :auth_kind, "oauth2"}, :credential_unavailable},
        {"format mismatch", {:grant, :request_format, "raw"}, :credential_unavailable},
        {"scope mismatch", {:grant, :scopes, ["other"]}, :credential_unavailable},
        {"issuer mismatch", {:grant, :issuer, "other"}, :credential_unavailable},
        {"key id mismatch", {:grant, :key_id, "other"}, :credential_unavailable},
        {"subject mismatch", {:grant, :subject, "other"}, :credential_unavailable},
        {"exact expiry", {:grant, :expires_at, @now}, :credential_expired},
        {"past expiry", {:grant, :expires_at, DateTime.add(@now, -1)}, :credential_expired},
        {"configuration expiry", {:credential, :expires_at, @now}, :credential_expired},
        {"invalid format", {:both, :request_format, "unknown"}, :credential_unavailable}
      ] do
    @change change
    @reason reason
    test "selected personal never falls back: #{label}", %{person: person} do
      c = credential(:optional)
      slot(c, :org, :active)
      g = slot(c, {:person, person.id}, :active)
      change_records(c, g, @change)

      assert Connect.resolve_credential(c, %{person_id: person.id}, @opts) == error(c, @reason)
    end
  end

  test "reloads stale configuration structs and accepts string IDs", %{person: person} do
    c = credential(:optional)
    slot(c, :org, :active)
    Repo.update!(Ecto.Changeset.change(c, personal_credential_policy: :required))

    assert Connect.resolve_credential(c, %{person_id: person.id}, @opts) ==
             error(c, :personal_credential_required)

    assert {:ok, resolved} = Connect.resolve_credential(to_string(c.id), nil, @opts)
    assert resolved.credential_id == c.id
  end

  test "resolved expiry is the earliest configuration or selected grant deadline" do
    for {configuration_expiry, grant_expiry, expected} <- [
          {nil, nil, nil},
          {DateTime.add(@now, 60), nil, DateTime.add(@now, 60)},
          {nil, DateTime.add(@now, 120), DateTime.add(@now, 120)},
          {DateTime.add(@now, 180), DateTime.add(@now, 90), DateTime.add(@now, 90)},
          {DateTime.add(@now, 30), DateTime.add(@now, 240), DateTime.add(@now, 30)}
        ] do
      c = credential(:required)
      g = slot(c, :org, :active)
      Repo.update!(Ecto.Changeset.change(c, expires_at: configuration_expiry))
      Repo.update!(Ecto.Changeset.change(g, expires_at: grant_expiry))

      assert {:ok, resolved} = Connect.resolve_credential(c, nil, @opts)
      assert resolved.expires_at == expected
    end
  end

  test "literal active identity is required before even disabled policy", %{person: person} do
    c = credential(:disabled)
    slot(c, :org, :active)
    Repo.update!(Person.update_changeset(person, %{status: "inactive"}))

    assert Connect.resolve_credential(c, %{person: %{id: person.id}}, @opts) ==
             error(c, :person_unavailable)

    Repo.delete!(person)

    assert Connect.resolve_credential(c, %{person_id: person.id}, @opts) ==
             error(c, :person_unavailable)
  end

  test "canonical nested and legacy flat numeric-string identities retain exact ownership", %{
    person: person
  } do
    c = credential(:required)
    g = slot(c, {:person, person.id}, :active)

    for actor <- [
          %{person: %{id: person.id}},
          %{"person" => %{"id" => " #{person.id} "}},
          %{person_id: person.id},
          %{"person_id" => to_string(person.id)}
        ] do
      assert {:ok, %{grant_id: id, owner_id: owner}} = Connect.resolve_credential(c, actor, @opts)
      assert {id, owner} == {g.id, person.id}
    end
  end

  test "malformed or conflicting identity claims never become global", %{person: person} do
    c = credential(:disabled)
    slot(c, :org, :active)

    for actor <- [
          "person",
          person,
          [],
          %{person: "invalid"},
          %{person: %{}},
          %{person: %{id: nil}},
          %{person_id: "invalid"},
          %{person_id: 0},
          %{person_id: -1},
          %{person: %{id: "bad"}, person_id: person.id},
          %{person: %{id: person.id}, person_id: person.id + 1},
          %{:person_id => person.id, "person_id" => "bad"}
        ] do
      assert Connect.resolve_credential(c, actor, @opts) == error(c, :person_unavailable)
    end
  end

  test "nil and genuine BO/system actors are privileged runtime only" do
    c = credential(:required)
    g = slot(c, :org, :active)

    for actor <- [nil, %{}, %{id: 123, provider: "bo"}, %{person: nil, person_id: nil}] do
      assert {:ok, %{grant_id: id}} = Connect.resolve_credential(c, actor, @opts)
      assert id == g.id
    end

    assert {:error, :unauthorized} = PersonCredentials.get_own_status(nil, c.id)
  end

  test "missing and invalid credential references return safe IDs" do
    c = credential(:required)
    Repo.delete!(c)
    assert Connect.resolve_credential(c, nil, @opts) == error(c, :credential_unavailable, nil)

    for ref <- [nil, "bad", %{}, -1] do
      assert Connect.resolve_credential(ref, nil, @opts) ==
               {:error, %{credential_id: nil, reason: :credential_unavailable}}
    end
  end

  for ciphertext <- ["enc:v1:broken", "enc:unavailable-key:AAAA:AAAA:AAAA"] do
    @ciphertext ciphertext
    test "corrupt or unavailable encryption key: #{ciphertext}", %{person: person} do
      c = credential(:optional)
      slot(c, :org, :active)
      g = slot(c, {:person, person.id}, :active)
      Repo.query!("UPDATE connect_grants SET api_key = $1 WHERE id = $2", [@ciphertext, g.id])

      assert Connect.resolve_credential(c, %{person_id: person.id}, @opts) ==
               error(c, :credential_unavailable)
    end
  end

  test "legacy configuration secrets and resource grants are never sources", %{person: person} do
    c = credential(:optional)
    Repo.update!(Ecto.Changeset.change(c, api_key: "legacy-global", private_key: "legacy-key"))

    {:ok, _} =
      Connect.issue_grant(%{
        credential_id: c.id,
        resource_type: "mcp",
        resource_id: "legacy",
        owner_type: "org",
        api_key: "legacy-grant"
      })

    assert Connect.resolve_credential(c, nil, @opts) == error(c, :global_credential_missing)
    g = slot(c, {:person, person.id}, :active)
    Repo.update!(Ecto.Changeset.change(g, api_key: nil))

    assert Connect.resolve_credential(c, %{person_id: person.id}, @opts) ==
             error(c, :credential_unavailable)
  end

  test "runtime result is redacted and not JSON serializable; only selected account metadata", %{
    person: person
  } do
    c = credential(:optional)
    global = slot(c, :org, :active)
    g = slot(c, {:person, person.id}, :active)
    Repo.update!(Ecto.Changeset.change(global, metadata: %{"account_id" => "global-private"}))

    Repo.update!(
      Ecto.Changeset.change(g,
        metadata: %{
          "account_id" => "own-account",
          "account_name" => "Own",
          "secret" => "hidden",
          "nested" => %{}
        }
      )
    )

    assert {:ok, r} = Connect.resolve_credential(c, %{person_id: person.id}, @opts)
    assert r.metadata == %{"account_id" => "own-account", "account_name" => "Own"}
    refute inspect(r) =~ "person-secret"
    refute inspect(r) =~ "own-account"
    refute inspect(r) =~ "global-private"
    assert {:error, _} = Jason.encode(r)
    refute Map.has_key?(Map.from_struct(r), :credential)
    refute Map.has_key?(Map.from_struct(r), :grant)
  end

  for state <- [:active, :expired, :revoked] do
    @state state
    test "selected OAuth #{@state} uses shared refresh or terminal revocation", %{person: person} do
      c = credential(:optional, "oauth2")
      slot(c, :org, :active)
      g = slot(c, {:person, person.id}, @state)

      if @state != :revoked do
        Repo.update!(Ecto.Changeset.change(g, expires_at: DateTime.add(@now, 60)))

        Req.Test.expect(
          ConnectOAuthAttemptHTTP,
          &Req.Test.json(&1, %{"access_token" => "new-token", "expires_in" => 3600})
        )

        assert {:ok, r} = Connect.resolve_credential(c, %{person_id: person.id}, @opts)
        assert r.grant_id == g.id
        assert r.authentication == %{access_token: "new-token"}
      else
        assert Connect.resolve_credential(c, %{person_id: person.id}, @opts) ==
                 error(c, :credential_revoked)
      end
    end
  end

  test "OAuth cached access excludes client and refresh secrets", %{person: person} do
    c = credential(:required, "oauth2")
    g = slot(c, {:person, person.id}, :active)
    Repo.update!(Ecto.Changeset.change(c, client_secret: "client-secret"))
    assert {:ok, r} = Connect.resolve_credential(c, %{person_id: person.id}, @opts)
    assert r.authentication == %{access_token: "person-secret"}
    assert r.grant_id == g.id
    refute inspect(Map.from_struct(r)) =~ "client-secret"
    refute inspect(Map.from_struct(r)) =~ "refresh-secret"
  end

  for mode <- [:failure, :delete_person, :delete_config, :change_config, :replace, :revoke] do
    @mode mode
    test "OAuth #{@mode} during HTTP fails without fallback", %{person: person} do
      c = credential(:optional, "oauth2")
      slot(c, :org, :active)
      slot(c, {:person, person.id}, :expired)

      Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
        case @mode do
          :delete_person ->
            Repo.delete!(person)

          :delete_config ->
            Repo.delete!(c)

          :change_config ->
            Repo.update!(Ecto.Changeset.change(c, client_id: "changed"))

          :replace ->
            Connect.replace_credential_grant(c, {:person, person.id}, %{
              access_token: "replacement"
            })

          :revoke ->
            Connect.revoke_credential_grant(c, {:person, person.id})

          :failure ->
            :ok
        end

        if @mode == :failure,
          do:
            conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"secret" => "provider-response"}),
          else: Req.Test.json(conn, %{"access_token" => "stale-response", "expires_in" => 3600})
      end)

      reason =
        case @mode do
          :delete_person -> :person_unavailable
          :revoke -> :credential_revoked
          :failure -> :credential_refresh_failed
          _ -> :credential_unavailable
        end

      assert Connect.resolve_credential(c, %{person_id: person.id}, @opts) == error(c, reason)
      refute inspect(error(c, reason)) =~ "provider-response"
    end
  end

  test "unrefreshable expired OAuth is expired, not absent", %{person: person} do
    c = credential(:optional, "oauth2")
    slot(c, :org, :active)
    g = slot(c, {:person, person.id}, :expired)
    Repo.update!(Ecto.Changeset.change(g, refresh_token: nil))

    assert Connect.resolve_credential(c, %{person_id: person.id}, @opts) ==
             error(c, :credential_expired)
  end

  property "credential/person isolation and deterministic resolution", %{person: person} do
    check all(suffix <- string(:alphanumeric, min_length: 1, max_length: 24), max_runs: 15) do
      c = credential(:required)
      other = credential(:required)
      own = slot(c, {:person, person.id}, :active)
      other_person = Repo.insert!(Person.changeset(%Person{}, %{full_name: "Other #{suffix}"}))
      slot(c, {:person, other_person.id}, :active)
      slot(other, {:person, person.id}, :active)
      actor = %{person_id: person.id}
      assert {:ok, r} = Connect.resolve_credential(c, actor, @opts)
      assert {r.credential_id, r.grant_id, r.owner_id} == {c.id, own.id, person.id}
      assert Connect.resolve_credential(c, actor, @opts) == {:ok, r}
    end
  end

  test "deleted alias never resolves the survivor's personal or org material", %{person: person} do
    c = credential(:disabled)
    slot(c, :org, :active)
    survivor = Repo.insert!(Person.changeset(%Person{}, %{full_name: "Survivor"}))
    Repo.update!(Ecto.Changeset.change(survivor, merged_person_ids: [person.id]))
    slot(c, {:person, survivor.id}, :active)
    Repo.delete!(person)

    assert Connect.resolve_credential(c, %{person_id: person.id}, @opts) ==
             error(c, :person_unavailable)
  end

  test "public Engine actions cannot return resolved authentication" do
    c = credential(:required)
    slot(c, :org, :active)

    for action <- [:resolve_credential, :connect_resolve_credential] do
      event = %Event{request: %{credential_id: c.id}, next_hop: nil}

      assert %{response: {:error, {:unsupported_action, ^action}}} =
               Api.handle_event(event, action, nil)
    end
  end

  test "raw API format and enc-prefixed literal are not re-decrypted", %{person: person} do
    c = credential(:required)
    c = Repo.update!(Ecto.Changeset.change(c, request_format: "raw"))
    {:ok, ciphertext} = SecretConfig.encrypt("retired")
    {:ok, _} = Connect.replace_credential_grant(c, {:person, person.id}, %{api_key: ciphertext})
    assert {:ok, r} = Connect.resolve_credential(c, %{person_id: person.id}, @opts)
    assert r.request_format == "raw"
    assert r.authentication == %{api_key: ciphertext}
  end

  test "OAuth busy remains bounded and safely distinct from provider failure", %{person: person} do
    c = credential(:required, "oauth2")
    g = slot(c, {:person, person.id}, :expired)

    Repo.update!(
      Ecto.Changeset.change(g,
        refresh_claim: Ecto.UUID.generate(),
        refresh_claim_until: DateTime.add(@now, 120)
      )
    )

    assert Connect.resolve_credential(c, %{person_id: person.id}, @opts) ==
             error(c, :credential_refresh_busy)
  end

  test "OAuth missing access and refresh material is unavailable without legacy recovery", %{
    person: person
  } do
    c = credential(:optional, "oauth2")
    slot(c, :org, :active)
    g = slot(c, {:person, person.id}, :active)
    Repo.update!(Ecto.Changeset.change(g, access_token: nil, refresh_token: nil))

    assert Connect.resolve_credential(c, %{person_id: person.id}, @opts) ==
             error(c, :credential_unavailable)
  end

  test "selected metadata drops nonstring account values", %{person: person} do
    c = credential(:required)
    g = slot(c, {:person, person.id}, :active)

    Repo.update!(
      Ecto.Changeset.change(g,
        metadata: %{
          "account_id" => %{"secret" => "hidden"},
          "account_name" => String.duplicate("a", 256)
        }
      )
    )

    assert {:ok, %{metadata: %{}}} = Connect.resolve_credential(c, %{person_id: person.id}, @opts)
  end

  test "OAuth runtime identity comes only from the selected behavior and grant", %{person: person} do
    c = credential(:optional, "oauth2")

    c =
      Repo.update!(
        Ecto.Changeset.change(c,
          metadata: Map.put(c.metadata, "auth_profile", "openai_chatgpt_codex")
        )
      )

    org = slot(c, :org, :active)
    personal = slot(c, {:person, person.id}, :active)

    Repo.update!(
      Ecto.Changeset.change(org,
        metadata: %{"chatgpt_account_id" => "acct_org"}
      )
    )

    Repo.update!(
      Ecto.Changeset.change(personal,
        metadata: %{
          "chatgpt_account_id" => "acct_person",
          "account_id" => "not-codex-identity",
          "secret" => "hidden"
        }
      )
    )

    assert {:ok, resolved} = Connect.resolve_credential(c, %{person_id: person.id}, @opts)
    assert resolved.grant_id == personal.id
    assert resolved.metadata == %{"chatgpt_account_id" => "acct_person"}
  end

  test "explicit no-auth resolves without a grant for Person and non-Person actors", %{
    person: person
  } do
    attrs = %{
      name: "no-auth-#{Ecto.UUID.generate()}",
      provider: "local",
      auth_kind: "none",
      request_format: "raw",
      user_level: false,
      metadata: %{},
      personal_credential_policy: :disabled,
      secret_binding: :configuration
    }

    assert {:ok, %{credential_id: id, global_grant: nil}} =
             Connect.save_credential_configuration(nil, attrs, :remove, @opts)

    for actor <- [nil, %{person_id: person.id}] do
      assert {:ok, resolved} = Connect.resolve_credential(id, actor, @opts)
      assert resolved.grant_id == nil
      assert resolved.owner_type == "org"
      assert resolved.auth_kind == "none"
      assert resolved.authentication == %{}
    end
  end

  test "no-auth cannot enable personal policy or persist grant material" do
    attrs = %{
      name: "invalid-no-auth-#{Ecto.UUID.generate()}",
      provider: "local",
      auth_kind: "none",
      request_format: "raw",
      user_level: false,
      metadata: %{},
      personal_credential_policy: :optional,
      secret_binding: :configuration
    }

    assert {:error, :invalid_configuration} =
             Connect.save_credential_configuration(nil, attrs, :remove, @opts)

    assert {:error, :invalid_configuration} =
             Connect.save_credential_configuration(
               nil,
               attrs
               |> Map.put(:personal_credential_policy, :disabled)
               |> Map.put(:api_key, "forbidden"),
               :remove,
               @opts
             )
  end

  property "disabled and nonperson ignore arbitrary personal material", %{person: person} do
    c = credential(:disabled)
    org = slot(c, :org, :active)
    personal = slot(c, {:person, person.id}, :active)

    check all(
            key <- string(:alphanumeric, max_length: 40),
            state <- member_of(["active", "revoked", "expired"]),
            max_runs: 15
          ) do
      Repo.update!(Ecto.Changeset.change(personal, api_key: key, status: state))

      for actor <- [nil, %{person_id: person.id}] do
        assert {:ok, r} = Connect.resolve_credential(c, actor, @opts)
        assert {r.grant_id, r.authentication} == {org.id, %{api_key: "org-secret"}}
      end
    end
  end

  property "selected failure never falls back regardless of global material", %{person: person} do
    c = credential(:optional)
    g = slot(c, {:person, person.id}, :revoked)
    slot(c, :org, :active)

    check all(delta <- integer(-10_000..10_000), max_runs: 15) do
      Repo.update!(Ecto.Changeset.change(g, expires_at: DateTime.add(@now, delta)))

      assert Connect.resolve_credential(c, %{person_id: person.id}, @opts) ==
               error(c, :credential_revoked)
    end
  end

  defp credential(policy, kind \\ "api_key") do
    {:ok, c} =
      Connect.create_credential(%{
        name: "resolver-#{Ecto.UUID.generate()}",
        provider: "example",
        auth_kind: kind,
        secret_binding: :grant,
        personal_credential_policy: policy,
        client_id: "client",
        metadata:
          if(kind == "oauth2", do: %{"token_url" => "https://provider.example/token"}, else: %{})
      })

    c
  end

  defp slot(_c, _owner, :absent), do: nil

  defp slot(c, owner, state) do
    {type, id} = if owner == :org, do: {"org", nil}, else: {"person", elem(owner, 1)}

    material =
      if c.auth_kind == "oauth2",
        do: %{access_token: "#{type}-secret", refresh_token: "refresh-secret"},
        else: %{api_key: "#{type}-secret"}

    attrs = Map.merge(material, %{owner_type: type, owner_id: id, status: to_string(state)})
    %Grant{} |> Connect.change_credential_grant(c, attrs) |> Repo.insert!()
  end

  defp error(c, reason, owner_type \\ "person")

  defp error(c, reason, _owner_type)
       when reason in [
              :personal_credential_required,
              :global_credential_missing,
              :person_unavailable
            ],
       do: {:error, %{credential_id: c.id, reason: reason}}

  defp error(c, reason, nil), do: {:error, %{credential_id: c.id, reason: reason}}

  defp error(c, reason, owner_type),
    do: {:error, %{credential_id: c.id, reason: reason, owner_type: owner_type}}

  defp change_records(c, g, {target, field, value}) do
    if target in [:grant, :both], do: Repo.update!(Ecto.Changeset.change(g, [{field, value}]))

    if target in [:credential, :both],
      do: Repo.update!(Ecto.Changeset.change(c, [{field, value}]))
  end
end
