defmodule Zaq.Engine.Connect.PersonCredentialsTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias Zaq.Accounts.{Person, User}
  alias Zaq.Engine.Api
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Grant, OAuth, OAuthState, PersonCredentials}
  alias Zaq.Event
  alias Zaq.Identity.ActorNormalizer

  defp person do
    Repo.insert!(Person.changeset(%Person{}, %{full_name: "Credential owner"}))
  end

  defp credential(attrs \\ %{}) do
    {:ok, credential} =
      Connect.create_credential(
        Map.merge(
          %{
            name: "personal-#{Ecto.UUID.generate()}",
            provider: "example",
            auth_kind: "api_key",
            secret_binding: :grant,
            personal_credential_policy: :required
          },
          attrs
        )
      )

    credential
  end

  defp summary(credential, status \\ "absent", expires_at \\ nil) do
    %{
      credential_id: credential.id,
      name: credential.name,
      provider: credential.provider,
      auth_kind: credential.auth_kind,
      personal_credential_policy: credential.personal_credential_policy,
      status: status,
      expires_at: expires_at
    }
  end

  defp assert_unauthorized(actor, id) do
    assert {:error, :unauthorized} = PersonCredentials.list_available(actor)
    assert {:error, :unauthorized} = PersonCredentials.get_own_status(actor, id)

    assert {:error, :unauthorized} =
             PersonCredentials.put_own_authentication(actor, id, %{api_key: "secret"})

    assert {:error, :unauthorized} = PersonCredentials.revoke_own_grant(actor, id)
    assert {:error, :unauthorized} = PersonCredentials.remove_own_grant(actor, id)
  end

  test "only eligible canonical configurations; policy and user ownership stay independent" do
    owner = person()

    for binding <- [:grant, :configuration], policy <- [:disabled, :optional, :required] do
      config = credential(%{secret_binding: binding, personal_credential_policy: policy})

      if binding == :grant and policy in [:optional, :required] do
        assert {:ok, dto} = PersonCredentials.get_own_status(owner, config.id)
        assert dto == summary(config)
      else
        assert {:error, :not_found} = PersonCredentials.get_own_status(owner, config.id)

        assert {:error, :not_found} =
                 PersonCredentials.put_own_authentication(owner, config.id, %{api_key: "key"})
      end
    end

    assert {:ok, available} = PersonCredentials.list_available(owner)
    assert length(available) == 2
    assert Enum.all?(available, &(&1.status == "absent"))

    assert Enum.sort(Enum.map(available, & &1.personal_credential_policy)) == [
             :optional,
             :required
           ]
  end

  test "typed trusted backend input rejects actor maps, flags, BO identities and flat legacy IDs" do
    owner = person()
    config = credential()

    for actor <- [
          nil,
          owner.id,
          %Person{id: owner.id},
          %{owner | id: nil},
          %{owner | id: 0},
          %{owner | id: 18_446_744_073_709_551_616},
          %User{id: owner.id},
          %{person_id: owner.id},
          %{"person_id" => owner.id},
          %{person: %{id: owner.id}},
          %{person: owner, person_id: owner.id + 1},
          %{authenticated: true, trusted: true, person: owner},
          %{skip_permissions: true, person_id: nil},
          %{person: owner, user_id: owner.id},
          ActorNormalizer.from_person_payload(nil, %{id: owner.id})
        ] do
      assert_unauthorized(actor, config.id)
    end
  end

  test "reload literal active identity: inactive, deleted, missing and stale merge aliases reject" do
    owner = person()
    config = credential()
    Repo.update!(Person.update_changeset(owner, %{status: "inactive"}))
    assert_unauthorized(owner, config.id)
    Repo.delete!(Repo.reload!(owner))
    survivor = person()

    Repo.update!(Person.merge_result_changeset(survivor, %{merged_person_ids: [owner.id]}))
    assert_unauthorized(owner, config.id)
    assert_unauthorized(%{owner | id: 2_147_483_647}, config.id)
    assert {:ok, _} = PersonCredentials.list_available(survivor)
  end

  property "arbitrary actor maps are never an authenticated backend Person" do
    check all(actor <- map_of(string(:alphanumeric, max_length: 12), integer(), max_length: 8)) do
      assert_unauthorized(actor, 1)
    end
  end

  test "write-only API key replacement and own status never disclose global or other owners" do
    owner = person()
    other = person()
    config = credential(%{personal_credential_policy: :optional, api_key: "CONFIG_SENTINEL"})
    {:ok, _} = Connect.replace_credential_grant(config, :org, %{api_key: "GLOBAL_SENTINEL"})

    {:ok, foreign} =
      Connect.replace_credential_grant(config, {:person, other.id}, %{api_key: "OTHER_SENTINEL"})

    assert {:ok, dto} = PersonCredentials.get_own_status(owner, config.id)
    assert dto == summary(config)

    log =
      capture_log(fn ->
        assert {:ok, %{credential_id: id, status: "active"} = result} =
                 PersonCredentials.put_own_authentication(owner, config.id, %{
                   "api_key" => "OWN_SENTINEL"
                 })

        assert id == config.id
        assert map_size(result) == 2
        assert {:ok, dto} = PersonCredentials.get_own_status(owner, config.id)
        assert dto == summary(config, "active")
        assert {:ok, [^dto]} = PersonCredentials.list_available(owner)
      end)

    refute log =~ "SENTINEL"

    grant =
      Repo.get_by!(Grant, credential_id: config.id, owner_type: "person", owner_id: owner.id)

    assert grant.api_key == "OWN_SENTINEL"
    assert Repo.get!(Grant, foreign.grant_id).api_key == "OTHER_SENTINEL"

    assert [[ciphertext]] =
             Repo.query!("SELECT api_key FROM connect_grants WHERE id = $1", [grant.id]).rows

    assert String.starts_with?(ciphertext, "enc:")
    refute ciphertext =~ "SENTINEL"

    assert Repo.exists?(
             from j in Oban.Job, where: fragment("?->>'kind'", j.args) == "grant_replaced"
           )
  end

  test "statuses and expiration reflect only the own retained slot, with no metadata" do
    owner = person()
    config = credential(%{metadata: %{"client_secret" => "CONFIG_SENTINEL"}})

    {:ok, grant_dto} =
      Connect.replace_credential_grant(config, {:person, owner.id}, %{api_key: "key"})

    grant = Repo.get!(Grant, grant_dto.grant_id)

    for {stored, expiry, status} <- [
          {"active", nil, "active"},
          {"active", ~U[2099-01-01 00:00:00Z], "active"},
          {"active", ~U[2000-01-01 00:00:00Z], "expired"},
          {"expired", nil, "expired"},
          {"revoked", ~U[2000-01-01 00:00:00Z], "revoked"}
        ] do
      Repo.update!(
        Ecto.Changeset.change(Repo.reload!(grant), %{
          status: stored,
          expires_at: expiry,
          metadata: %{
            "account_id" => %{"access_token" => "NESTED_SENTINEL"},
            "email" => "SENTINEL"
          }
        })
      )

      assert {:ok, dto} = PersonCredentials.get_own_status(owner, config.id)
      assert dto == summary(config, status, expiry)
      refute inspect(dto) =~ "SENTINEL"
    end
  end

  test "cross-credential grant IDs, unknown IDs and malformed references yield safe errors" do
    owner = person()
    other = person()
    config = credential()

    {:ok, foreign} =
      Connect.replace_credential_grant(config, {:person, other.id}, %{api_key: "secret"})

    for id <- [
          nil,
          0,
          -1,
          18_446_744_073_709_551_616,
          "bad",
          %Grant{id: foreign.grant_id},
          %{credential_id: config.id, grant_id: foreign.grant_id},
          2_147_483_647
        ] do
      assert {:error, :not_found} = PersonCredentials.get_own_status(owner, id)

      assert {:error, :not_found} =
               PersonCredentials.put_own_authentication(owner, id, %{api_key: "key"})

      assert {:error, :not_found} = PersonCredentials.revoke_own_grant(owner, id)
      assert {:error, :not_found} = PersonCredentials.remove_own_grant(owner, id)
    end

    assert {:ok, %{credential_id: id, status: "absent"}} =
             PersonCredentials.remove_own_grant(owner, config.id)

    assert id == config.id
    assert Repo.get!(Grant, foreign.grant_id).status == "active"
  end

  test "replacement reactivates the same slot, clears omitted expiration and rolls back with events" do
    owner = person()
    config = credential()
    expiry = ~U[2099-01-01 00:00:00Z]

    assert {:ok, _} =
             PersonCredentials.put_own_authentication(owner, config.id, %{
               api_key: "first",
               expires_at: expiry
             })

    original = Repo.get_by!(Grant, credential_id: config.id, owner_id: owner.id)
    assert {:ok, _} = PersonCredentials.revoke_own_grant(owner, config.id)

    assert {:ok, %{credential_id: id, status: "active"}} =
             PersonCredentials.put_own_authentication(owner, config.id, %{api_key: "second"})

    assert id == config.id
    current = Repo.reload!(original)
    assert current.api_key == "second"
    assert current.expires_at == nil
    assert current.status == "active"
    count = Repo.aggregate(Oban.Job, :count)

    assert {:error, :outer_rollback} =
             Repo.transaction(fn ->
               assert {:ok, _} = PersonCredentials.remove_own_grant(owner, config.id)
               Repo.rollback(:outer_rollback)
             end)

    assert Repo.reload!(original).api_key == "second"
    assert Repo.aggregate(Oban.Job, :count) == count
  end

  test "legacy org/user slots and canonical Person slots are distinct even for colliding IDs" do
    owner = person()
    config = credential(%{user_level: true})

    for type <- ["org", "user"] do
      assert {:ok, grant} =
               Connect.issue_grant(%{
                 credential_id: config.id,
                 owner_type: type,
                 owner_id: owner.id,
                 resource_type: "mcp",
                 resource_id: "legacy",
                 api_key: "legacy"
               })

      assert grant.owner_type == type
      assert Repo.reload!(grant).api_key == "legacy"
    end

    assert {:ok, dto} = PersonCredentials.get_own_status(owner, config.id)
    assert dto == summary(config)
    assert {:ok, _} = PersonCredentials.revoke_own_grant(owner, config.id)
    assert {:ok, _} = PersonCredentials.remove_own_grant(owner, config.id)
    assert Enum.all?(Connect.list_grants(credential_id: config.id), &(&1.status == "active"))
  end

  property "unknown material keys never change ownership or expose submitted values" do
    owner = person()
    config = credential()

    check all(
            key <-
              member_of(
                ~w(owner_id owner_type person_id credential_id grant_id provider scopes auth_kind secret_binding personal_credential_policy metadata client_id client_secret issuer key_id subject resource_id)
              ),
            value <- string(:alphanumeric, min_length: 1, max_length: 40)
          ) do
      assert {:error, :invalid_material} =
               PersonCredentials.put_own_authentication(owner, config.id, %{
                 "api_key" => "key",
                 key => value
               })

      refute Repo.exists?(from g in Grant, where: g.credential_id == ^config.id)
    end
  end

  test "malformed material, duplicate keys, wrong auth material and encryption errors are sanitized" do
    Code.ensure_loaded!(Zaq.TestSupport.ConnectEncryptionConfig)
    owner = person()
    config = credential()

    for material <- [
          nil,
          [],
          "SENTINEL",
          %Person{},
          %{},
          %{api_key: nil},
          %{api_key: ""},
          %{api_key: "••••••••"},
          %{api_key: %{"secret" => "SENTINEL"}},
          %{"api_key" => "SENTINEL", api_key: "key"},
          %{private_key: "SENTINEL"},
          %{api_key: "key", expires_at: %{"secret" => "SENTINEL"}}
        ] do
      assert {:error, :invalid_material} =
               PersonCredentials.put_own_authentication(owner, config.id, material)
    end

    assert {:error, :encryption_failed} =
             PersonCredentials.put_own_authentication(owner, config.id, %{api_key: "SENTINEL"},
               config: Zaq.TestSupport.ConnectEncryptionConfig,
               encryption_config: []
             )

    refute Repo.exists?(from g in Grant, where: g.credential_id == ^config.id)
  end

  test "disabled retained slots allow repeated private cleanup but reject replacement" do
    owner = person()
    config = credential()

    assert {:ok, _} =
             PersonCredentials.put_own_authentication(owner, config.id, %{api_key: "key"})

    {:ok, config} = Connect.update_credential(config, %{personal_credential_policy: :disabled})
    assert {:ok, []} = PersonCredentials.list_available(owner)
    assert {:ok, dto} = PersonCredentials.get_own_status(owner, config.id)
    assert dto == summary(config, "active")

    assert {:error, :not_found} =
             PersonCredentials.put_own_authentication(owner, config.id, %{api_key: "new"})

    for _ <- 1..2 do
      assert {:ok, result} = PersonCredentials.revoke_own_grant(owner, config.id)
      assert result == %{credential_id: config.id, status: "revoked"}
    end

    grant = Repo.get_by!(Grant, credential_id: config.id, owner_id: owner.id)
    assert is_nil(grant.api_key)

    for _ <- 1..2 do
      assert {:ok, result} = PersonCredentials.remove_own_grant(owner, config.id)
      assert result == %{credential_id: config.id, status: "absent"}
    end

    assert {:ok, %{status: "absent"}} = PersonCredentials.revoke_own_grant(owner, config.id)
    assert {:error, :not_found} = PersonCredentials.get_own_status(owner, config.id)
  end

  test "JWT material uses canonical config; OAuth input remains deferred" do
    owner = person()

    config =
      credential(%{
        auth_kind: "jwt_bearer",
        issuer: "issuer",
        key_id: "key-id",
        metadata: %{"auth_profile_id" => "service_account"}
      })

    key = :public_key.generate_key({:rsa, 1024, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    assert {:error, :invalid_material} =
             PersonCredentials.put_own_authentication(owner, config.id, %{api_key: "wrong"})

    assert {:error, :invalid_material} =
             PersonCredentials.put_own_authentication(owner, config.id, %{private_key: "bad"})

    assert {:ok, %{status: "active"}} =
             PersonCredentials.put_own_authentication(owner, config.id, %{private_key: pem})

    grant = Repo.get_by!(Grant, credential_id: config.id, owner_id: owner.id)
    assert grant.private_key == pem
    assert grant.issuer == "issuer"
    assert grant.key_id == "key-id"
    oauth = credential(%{auth_kind: "oauth2", client_id: "client"})

    assert {:error, :unsupported_auth_kind} =
             PersonCredentials.put_own_authentication(owner, oauth.id, %{access_token: "SENTINEL"})
  end

  test "legacy Engine issuance and OAuth context cannot establish Person ownership" do
    owner = person()
    config = credential(%{auth_kind: "oauth2", client_id: "client"})

    for attrs <- [
          %{owner_type: "person", owner_id: owner.id},
          %{owner_type: :person, owner_id: owner.id},
          %{"owner_type" => "person", "owner_id" => owner.id},
          %{"owner_type" => :person, "owner_id" => owner.id},
          %{"owner_type" => "person", owner_type: "org"}
        ] do
      assert {:error, :person_management_required} = Connect.issue_grant(attrs)
      event = Event.new(%{attrs: attrs}, :engine)

      assert Api.handle_event(event, :connect_issue_grant, %{}).response ==
               {:error, :person_management_required}

      assert {:error, :person_management_required} = OAuth.build_authorize_url(config, attrs)
      event = Event.new(%{credential: config, context: attrs}, :engine)

      assert Api.handle_event(event, :connect_oauth_build_authorize_url, %{}).response ==
               {:error, :person_management_required}
    end

    for owner_type <- ["person", :person] do
      state =
        OAuthState.sign(%{
          "credential_id" => config.id,
          "provider" => config.provider,
          "owner_type" => owner_type,
          "owner_id" => owner.id
        })

      assert {:error, :person_management_required} =
               OAuth.finalize_callback(config.provider, %{"state" => state, "code" => "SENTINEL"})
    end
  end
end
