defmodule Zaq.Engine.Connect.CanonicalStorageTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Accounts.Person
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Credential, Grant}
  alias Zaq.Types.EncryptedString

  defp credential(attrs \\ %{}) do
    {:ok, credential} =
      Connect.create_credential(
        Map.merge(
          %{
            name: "canonical-#{System.unique_integer([:positive])}",
            provider: "example",
            auth_kind: "api_key",
            scopes: ["read"]
          },
          attrs
        )
      )

    credential
  end

  defp insert_grant(credential, attrs) do
    %Grant{}
    |> Connect.change_credential_grant(credential, attrs)
    |> Repo.insert(mode: :savepoint)
  end

  test "policy defaults disabled independently of user_level and rejects null and unknown values" do
    assert credential().personal_credential_policy == :disabled
    assert credential(%{user_level: true}).personal_credential_policy == :disabled

    for value <- [nil, "unknown"] do
      changeset = Credential.changeset(%Credential{}, %{personal_credential_policy: value})
      assert errors_on(changeset).personal_credential_policy
    end

    for value <- [:disabled, :optional, :required] do
      assert credential(%{personal_credential_policy: value}).personal_credential_policy == value
    end
  end

  test "explicit grant secret binding permits JWT configuration without weakening legacy validation" do
    attrs = %{
      auth_kind: "jwt_bearer",
      issuer: "issuer",
      key_id: "key-id",
      metadata: %{"auth_profile_id" => "service_account"},
      personal_credential_policy: :required
    }

    changeset = Credential.changeset(%Credential{}, attrs)
    assert errors_on(changeset).private_key == ["can't be blank"]
    config = credential(Map.put(attrs, :secret_binding, :grant))
    assert config.private_key == nil

    assert {:ok, grant} =
             insert_grant(config, %{
               owner_type: "org",
               issuer: "issuer",
               key_id: "key-id",
               private_key: "grant-owned-key"
             })

    assert Repo.reload!(grant).private_key == "grant-owned-key"

    assert %{rows: [[stored]]} =
             Repo.query!("SELECT private_key FROM connect_grants WHERE id = $1", [grant.id])

    assert EncryptedString.encrypted?(stored)
  end

  test "canonical auth fields derive from configuration for all auth kinds and both key formats" do
    for {kind, config_attrs, secrets} <- [
          {"api_key", %{}, %{api_key: "personal-key"}},
          {"oauth2", %{client_id: "client"}, %{access_token: "personal-token"}},
          {"jwt_bearer",
           %{
             secret_binding: :grant,
             issuer: "issuer",
             key_id: "key-id",
             metadata: %{"auth_profile_id" => "service_account"}
           }, %{issuer: "issuer", key_id: "key-id", private_key: "personal-key"}}
        ],
        string_keys? <- [false, true] do
      config = credential(Map.put(config_attrs, :auth_kind, kind))

      attrs =
        Map.merge(secrets, %{
          owner_type: "org",
          provider: "hostile",
          auth_kind: "hostile",
          request_format: "raw",
          scopes: ["admin"],
          credential_id: -1,
          resource_type: "mcp",
          resource_id: "hostile",
          issuer: "hostile",
          key_id: "hostile",
          subject: "hostile"
        })

      attrs = if string_keys?, do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end), else: attrs
      assert {:ok, grant} = insert_grant(config, attrs)
      assert grant.credential_id == config.id
      assert grant.provider == "example"
      assert grant.auth_kind == kind
      assert grant.request_format == "bearer"
      assert grant.scopes == ["read"]
      assert grant.resource_type == "connect_credential"
      assert grant.resource_id == to_string(config.id)
      assert grant.issuer == config.issuer
      assert grant.key_id == config.key_id
      assert grant.subject == nil
    end
  end

  test "canonical secrets never fall back to configuration secrets" do
    config = credential(%{api_key: "company-key"})
    assert {:error, changeset} = insert_grant(config, %{owner_type: "org"})
    assert errors_on(changeset).api_key == ["can't be blank"]
  end

  test "a retained slot can be reconnected in place" do
    config = credential()

    assert {:ok, grant} =
             insert_grant(config, %{owner_type: "org", status: "revoked", api_key: "old"})

    assert {:ok, reconnected} =
             grant
             |> Connect.change_credential_grant(config, %{
               status: "active",
               api_key: "replacement"
             })
             |> Repo.update()

    assert reconnected.id == grant.id
    assert Repo.reload!(reconnected).api_key == "replacement"
    assert reconnected.status == "active"
  end

  test "canonical OAuth grants participate in the shared scheduled refresh selection" do
    config = credential(%{auth_kind: "oauth2", client_id: "client"})

    assert {:ok, grant} =
             insert_grant(config, %{
               owner_type: "org",
               access_token: "token",
               refresh_token: "refresh",
               expires_at: ~U[2020-01-01 00:00:00Z]
             })

    assert Enum.any?(Connect.expiring_oauth_grants(), &(&1.id == grant.id))
  end

  test "trusted storage checks current active Person on creation and update without resolving aliases" do
    config = credential()
    person = Repo.insert!(%Person{full_name: "Grant owner"})
    attrs = %{owner_type: "person", owner_id: person.id, api_key: "key"}
    assert {:ok, grant} = insert_grant(config, attrs)
    assert grant.owner_id == person.id

    for invalid <- [%{owner_id: nil}, %{owner_id: "invalid"}, %{owner_id: -1}] do
      assert {:error, _} = insert_grant(config, Map.merge(attrs, invalid))
    end

    Repo.update!(Ecto.Changeset.change(person, status: "inactive"))

    assert {:error, changeset} =
             grant |> Connect.change_credential_grant(config, %{}) |> Repo.update()

    assert errors_on(changeset).owner_id == ["must reference a current active Person"]
    Repo.delete!(person)
    Repo.insert!(%Person{full_name: "Survivor", merged_person_ids: [person.id]})
    assert {:error, changeset} = insert_grant(config, attrs)
    assert errors_on(changeset).owner_id == ["must reference a current active Person"]
    assert Repo.get!(Grant, grant.id).owner_id == person.id
  end

  property "canonical resource coordinates are server-derived for arbitrary client coordinates" do
    check all(
            resource_id <- string(:alphanumeric, min_length: 1, max_length: 30),
            resource_type <- member_of(["mcp", "data_source", "ai_provider_credential"])
          ) do
      for coordinates <- [
            %{resource_id: resource_id},
            %{resource_type: resource_type},
            %{resource_id: resource_id, resource_type: resource_type}
          ] do
        changeset =
          Connect.change_credential_grant(
            %Grant{},
            %Credential{id: 1, provider: "example", auth_kind: "api_key"},
            Map.merge(coordinates, %{owner_type: "org", api_key: "key"})
          )

        assert changeset.valid?
        assert Ecto.Changeset.get_field(changeset, :resource_type) == "connect_credential"
        assert Ecto.Changeset.get_field(changeset, :resource_id) == "1"
      end
    end
  end

  test "canonical user ownership and org IDs are rejected" do
    config = credential()

    for owner <- [
          %{owner_type: "user", owner_id: 1},
          %{owner_type: "org", owner_id: 1}
        ] do
      assert {:error, _} = insert_grant(config, Map.put(owner, :api_key, "key"))
    end
  end

  test "canonical owner updates validate the new literal identity" do
    config = credential()
    person = Repo.insert!(%Person{full_name: "New owner"})
    {:ok, grant} = insert_grant(config, %{owner_type: "org", api_key: "secret"})

    assert {:error, _} =
             grant
             |> Connect.change_credential_grant(config, %{owner_type: "person", owner_id: -1})
             |> Repo.update()

    assert {:ok, updated} =
             grant
             |> Connect.change_credential_grant(config, %{
               owner_type: "person",
               owner_id: person.id
             })
             |> Repo.update()

    assert updated.owner_id == person.id
    assert updated.resource_id == to_string(config.id)
  end

  test "org and multiple Person owners have independent slots on one credential" do
    config = credential()

    for _ <- 1..2 do
      person = Repo.insert!(%Person{full_name: "Independent owner"})

      assert {:ok, _} =
               insert_grant(config, %{
                 owner_type: "person",
                 owner_id: person.id,
                 api_key: "personal-key"
               })
    end

    assert {:ok, _} = insert_grant(config, %{owner_type: "org", api_key: "global-key"})
    assert Repo.aggregate(from(g in Grant, where: g.credential_id == ^config.id), :count) == 3
  end

  test "one slot per credential and owner persists across all statuses" do
    person = Repo.insert!(%Person{full_name: "Grant owner"})

    for status <- ["active", "revoked", "expired"],
        owner <- [
          %{owner_type: "org"},
          %{owner_type: "person", owner_id: person.id}
        ] do
      config = credential()
      attrs = Map.merge(owner, %{api_key: "key", status: status})
      assert {:ok, grant} = insert_grant(config, attrs)
      assert {:error, changeset} = insert_grant(config, Map.put(attrs, :status, "active"))
      assert errors_on(changeset).credential_id == ["has already been taken"]
      assert Repo.reload!(grant).status == status
      assert {:ok, _} = Connect.delete_credential(config)
      assert Repo.get(Grant, grant.id) == nil
      assert {:error, changeset} = insert_grant(config, attrs)
      assert errors_on(changeset).credential_id == ["does not exist"]
    end
  end

  test "legacy issue list and resolve remain resource bound with canonical rows present" do
    config = credential(%{auth_kind: "oauth2", client_id: "client"})
    assert {:ok, _} = insert_grant(config, %{owner_type: "org", access_token: "canonical"})

    for {owner, id} <- [{"org", nil}, {"user", 123}] do
      attrs = %{
        credential_id: config.id,
        resource_type: "mcp",
        resource_id: "legacy",
        owner_type: owner,
        owner_id: id,
        access_token: "legacy"
      }

      assert {:ok, grant} = Connect.issue_grant(attrs)
      assert grant.resource_type == "mcp"
      assert grant.resource_id == "legacy"
      assert [listed] = Connect.list_grants(credential_id: config.id, owner_type: owner)
      assert listed.id == grant.id
      assert Connect.get_active_grant(Map.put(attrs, :provider, config.provider)).id == grant.id
      assert {:ok, "legacy"} = Connect.resolve_bearer_token(attrs)
    end

    assert {:error, _} =
             Connect.issue_grant(%{
               credential_id: config.id,
               resource_type: "connect_credential",
               resource_id: to_string(config.id),
               owner_type: "org",
               access_token: "bypass"
             })
  end
end
