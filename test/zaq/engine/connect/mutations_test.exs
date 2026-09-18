defmodule Zaq.Engine.Connect.MutationsTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Accounts.Person
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Credential, Grant}
  alias Zaq.System.SecretConfig

  defp attrs(extra) do
    Map.merge(
      %{name: "mutation-#{Ecto.UUID.generate()}", provider: "example", auth_kind: "api_key"},
      extra
    )
  end

  defp credential(extra \\ %{}) do
    {:ok, row} = Connect.create_credential(attrs(extra))
    row
  end

  defp private_key do
    key = :public_key.generate_key({:rsa, 1024, 65_537})
    :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
  end

  test "atomic policy completeness, absence, keep and safe results" do
    for policy <- [:disabled, :optional, :required] do
      config = attrs(%{personal_credential_policy: policy})
      result = Connect.save_credential_configuration(nil, config)

      if policy == :required do
        assert {:ok,
                %{credential_id: id, personal_credential_policy: :required, global_grant: nil}} =
                 result

        assert Repo.get!(Credential, id).name == config.name
      else
        assert {:error, :global_grant_unusable} = result
        refute Repo.get_by(Credential, name: config.name)
      end

      assert {:ok, saved} =
               Connect.save_credential_configuration(
                 nil,
                 Map.put(config, :name, "with-global-#{Ecto.UUID.generate()}"),
                 {:replace, %{api_key: "SENTINEL"}}
               )

      assert Map.keys(saved) |> Enum.sort() == [
               :credential_id,
               :global_grant,
               :personal_credential_policy
             ]

      assert saved.global_grant == %{
               credential_id: saved.credential_id,
               grant_id: saved.global_grant.grant_id,
               status: "active"
             }

      refute inspect(saved) =~ "SENTINEL"
      assert {:ok, ^saved} = Connect.save_credential_configuration(saved.credential_id, %{})
    end
  end

  test "global removal is atomic, idempotent, and valid only for required policy" do
    assert {:ok, saved} =
             Connect.save_credential_configuration(
               nil,
               attrs(%{personal_credential_policy: :disabled}),
               {:replace, %{api_key: "global"}}
             )

    grant_id = saved.global_grant.grant_id

    assert {:error, :global_grant_unusable} =
             Connect.save_credential_configuration(saved.credential_id, %{}, :remove)

    assert Repo.get!(Grant, grant_id).status == "active"

    assert {:ok,
            %{
              credential_id: credential_id,
              personal_credential_policy: :required,
              global_grant: nil
            }} =
             Connect.save_credential_configuration(
               saved.credential_id,
               %{personal_credential_policy: :required},
               :remove
             )

    assert credential_id == saved.credential_id
    refute Repo.get(Grant, grant_id)

    assert {:ok, %{global_grant: nil, personal_credential_policy: :required}} =
             Connect.save_credential_configuration(saved.credential_id, %{}, :remove)

    assert {:error, :global_grant_unusable} =
             Connect.save_credential_configuration(
               saved.credential_id,
               %{personal_credential_policy: :optional},
               :remove
             )

    assert Repo.get!(Credential, saved.credential_id).personal_credential_policy == :required
  end

  test "global removal permits an atomic auth change when no Person grant remains" do
    config =
      credential(%{
        personal_credential_policy: :required,
        secret_binding: :grant
      })

    assert {:ok, global} = Connect.replace_credential_grant(config, :org, %{api_key: "global"})

    assert {:ok, %{global_grant: nil}} =
             Connect.save_credential_configuration(
               config,
               %{
                 auth_kind: "oauth2",
                 client_id: "client",
                 issuer: nil,
                 key_id: nil
               },
               :remove
             )

    refute Repo.get(Grant, global.grant_id)
    assert Repo.reload!(config).auth_kind == "oauth2"
  end

  test "global grant status, expiry, corruption and auth compatibility fail closed" do
    config = credential()
    assert {:ok, dto} = Connect.replace_credential_grant(config, :org, %{api_key: "key"})
    grant = Repo.get!(Grant, dto.grant_id)

    for changes <- [
          %{status: "revoked"},
          %{status: "expired"},
          %{expires_at: ~U[2000-01-01 00:00:00Z]},
          %{auth_kind: "oauth2"},
          %{provider: "other"},
          %{request_format: "raw"},
          %{scopes: ["other"]}
        ] do
      Repo.update!(Ecto.Changeset.change(grant, changes))

      assert {:error, :global_grant_unusable} =
               Connect.save_credential_configuration(config, %{name: "rolled-back"})

      assert Repo.reload!(config).name == config.name

      Repo.update!(
        Ecto.Changeset.change(
          Repo.reload!(grant),
          Map.take(Map.from_struct(grant), Map.keys(changes))
        )
      )
    end

    for ciphertext <- ["enc:broken", "enc:v1:AA:AA:AA"] do
      Repo.query!("UPDATE connect_grants SET api_key = $1 WHERE id = $2", [ciphertext, grant.id])
      assert {:error, :global_grant_unusable} = Connect.save_credential_configuration(config, %{})
    end
  end

  test "OAuth accepts pre-obtained access material and validates local expiry only" do
    config = credential(%{auth_kind: "oauth2", client_id: "client"})

    assert {:error, :invalid_material} =
             Connect.replace_credential_grant(config, :org, %{refresh_token: "refresh"})

    assert {:error, :invalid_material} =
             Connect.replace_credential_grant(config, :org, %{
               access_token: "access",
               expires_at: ~U[2000-01-01 00:00:00Z]
             })

    assert {:ok, _} =
             Connect.save_credential_configuration(
               config,
               %{},
               {:replace,
                %{
                  access_token: "access",
                  refresh_token: "refresh",
                  expires_at: ~U[2099-01-01 00:00:00Z]
                }}
             )
  end

  test "JWT grant-owned material and configuration compatibility" do
    key = private_key()

    config =
      credential(%{
        auth_kind: "jwt_bearer",
        secret_binding: :grant,
        issuer: "issuer",
        key_id: "key-id",
        metadata: %{"auth_profile_id" => "service_account"}
      })

    assert {:error, :invalid_material} = Connect.replace_credential_grant(config, :org, %{})

    for malformed <- ["not-a-key", "-----BEGIN PRIVATE KEY-----\nbad\n-----END PRIVATE KEY-----"] do
      assert {:error, :invalid_material} =
               Connect.replace_credential_grant(config, :org, %{private_key: malformed})
    end

    assert {:ok, _} =
             Connect.save_credential_configuration(
               config,
               %{},
               {:replace, %{private_key: key}}
             )

    assert {:error, :incompatible_live_grants} =
             Connect.save_credential_configuration(config, %{issuer: "new-issuer"})

    assert {:ok, _} =
             Connect.save_credential_configuration(
               config,
               %{issuer: "new-issuer"},
               {:replace, %{private_key: key}}
             )
  end

  test "policy transitions preserve Person rows; auth changes require cleanup of incompatible live grants" do
    config = credential()
    person = Repo.insert!(%Person{full_name: "Owner"})

    {:ok, personal} =
      Connect.replace_credential_grant(config, {:person, person.id}, %{api_key: "person-key"})

    before = Repo.get!(Grant, personal.grant_id)

    assert {:ok, _} =
             Connect.save_credential_configuration(config, %{
               personal_credential_policy: :required
             })

    assert {:error, :global_grant_unusable} =
             Connect.save_credential_configuration(config, %{
               personal_credential_policy: :optional
             })

    assert {:ok, _} =
             Connect.save_credential_configuration(
               config,
               %{personal_credential_policy: :disabled},
               {:replace, %{api_key: "global"}}
             )

    assert Repo.reload!(before) == before

    assert {:error, :incompatible_live_grants} =
             Connect.save_credential_configuration(
               config,
               %{auth_kind: "oauth2", client_id: "client"},
               {:replace, %{access_token: "token"}}
             )

    assert {:ok, _} = Connect.revoke_credential_grant(config, {:person, person.id})

    assert {:ok, _} =
             Connect.save_credential_configuration(
               config,
               %{auth_kind: "oauth2", client_id: "client"},
               {:replace, %{access_token: "token"}}
             )

    assert Repo.reload!(before).auth_kind == "api_key"
    assert Repo.reload!(before).api_key == nil
  end

  test "replacement reloads stale configuration, retains slot ID and fully replaces secrets" do
    config = credential(%{auth_kind: "oauth2", client_id: "client"})

    {:ok, first} =
      Connect.replace_credential_grant(config, :org, %{access_token: "one", refresh_token: "old"})

    {:ok, _} = Connect.revoke_credential_grant(config, :org)
    {:ok, _} = Connect.update_credential(config, %{scopes: ["current"]})
    assert {:ok, second} = Connect.replace_credential_grant(config, :org, %{access_token: "two"})
    assert first == second
    grant = Repo.get!(Grant, second.grant_id)
    assert grant.scopes == ["current"]
    assert grant.refresh_token == nil
    assert grant.access_token == "two"
    assert grant.status == "active"
  end

  test "cleanup is idempotent, credential-owner bound and bypasses inactive/missing Person checks" do
    config = credential()
    other = credential()
    person = Repo.insert!(%Person{full_name: "Owner"})

    {:ok, dto} =
      Connect.replace_credential_grant(config, {:person, person.id}, %{api_key: "secret"})

    Repo.update!(Ecto.Changeset.change(person, status: "inactive"))

    assert {:error, :person_unavailable} =
             Connect.replace_credential_grant(config, {:person, person.id}, %{api_key: "new"})

    assert {:ok, %{grant_id: nil, status: "absent"}} =
             Connect.remove_credential_grant(other, {:person, person.id})

    for _ <- 1..2 do
      assert {:ok, %{grant_id: id, status: "revoked"}} =
               Connect.revoke_credential_grant(config, {:person, person.id})

      assert id == dto.grant_id
      assert Repo.get!(Grant, id).api_key == nil
    end

    Repo.delete!(Repo.reload!(person))

    assert {:error, :person_unavailable} =
             Connect.replace_credential_grant(config, {:person, person.id}, %{api_key: "new"})

    assert {:ok, _} = Connect.revoke_credential_grant(config, {:person, person.id})

    assert {:ok, %{status: "absent"}} =
             Connect.remove_credential_grant(config, {:person, person.id})

    assert {:ok, %{grant_id: nil, status: "absent"}} =
             Connect.remove_credential_grant(config, {:person, person.id})

    refute Repo.get(Grant, dto.grant_id)
  end

  test "outer rollback undoes successful composed mutations" do
    config = credential()

    assert {:error, :outer_abort} =
             Repo.transaction(fn ->
               assert {:ok, _} =
                        Connect.save_credential_configuration(
                          config,
                          %{name: "temporary"},
                          {:replace, %{api_key: "key"}}
                        )

               assert {:ok, _} = Connect.revoke_credential_grant(config, :org)
               Repo.rollback(:outer_abort)
             end)

    assert Repo.reload!(config).name == config.name
    refute Repo.get_by(Grant, credential_id: config.id)
  end

  test "untrusted input is rejected without schemas, params, metadata or sentinel leakage" do
    config = credential()

    for material <- [
          %{},
          %{api_key: ""},
          %{api_key: "   "},
          %{api_key: nil},
          %{api_key: 123},
          %{api_key: "••••••••"},
          %{api_key: "secret", metadata: %{"token" => "SENTINEL"}},
          %{api_key: "secret", owner_id: 1},
          "SENTINEL"
        ] do
      assert {:error, :invalid_material} =
               Connect.replace_credential_grant(config, :org, material)
    end

    assert {:error, :invalid_configuration} =
             Connect.save_credential_configuration(config, %{metadata: %{"token" => "SENTINEL"}})

    assert {:error, :invalid_configuration} =
             Connect.save_credential_configuration(config, %{name: "x", client_secret: "SENTINEL"})

    assert {:error, :invalid_owner} =
             Connect.replace_credential_grant(config, {:person, nil}, %{api_key: "key"})

    assert {:error, :not_found} = Connect.replace_credential_grant(-1, :org, %{api_key: "key"})

    assert {:error, :invalid_instruction} =
             Connect.save_credential_configuration(config, %{}, %{})

    assert {:error, :invalid_configuration} =
             Connect.save_credential_configuration(config, "SENTINEL")

    refute Repo.get_by(Grant, credential_id: config.id)
  end

  property "enc-prefixed client material is always encrypted as plaintext, never accepted as ciphertext" do
    check all(suffix <- string(:alphanumeric, min_length: 1, max_length: 32), max_runs: 15) do
      config = credential()
      secret = "enc:" <> suffix
      assert {:ok, dto} = Connect.replace_credential_grant(config, :org, %{api_key: secret})
      assert Repo.get!(Grant, dto.grant_id).api_key == secret

      %{rows: [[stored]]} =
        Repo.query!("SELECT api_key FROM connect_grants WHERE id = $1", [dto.grant_id])

      refute stored == secret
      refute inspect(Repo.get!(Grant, dto.grant_id)) =~ secret
      assert {:ok, _} = Connect.save_credential_configuration(config, %{})
    end
  end

  test "encryption failures roll back configuration and retain existing encrypted slot" do
    Code.ensure_loaded!(Zaq.TestSupport.ConnectEncryptionConfig)
    config = credential()
    {:ok, dto} = Connect.replace_credential_grant(config, :org, %{api_key: "original"})

    for encryption_config <- [
          [],
          [encryption_key: "invalid"],
          [encryption_key: String.duplicate("k", 32), key_id: "bad:id"]
        ] do
      opts = [
        config: Zaq.TestSupport.ConnectEncryptionConfig,
        encryption_config: encryption_config
      ]

      assert {:error, :encryption_failed} =
               Connect.save_credential_configuration(
                 config,
                 %{name: "rollback"},
                 {:replace, %{api_key: "SENTINEL"}},
                 opts
               )

      assert Repo.reload!(config).name == config.name
      assert Repo.get!(Grant, dto.grant_id).api_key == "original"

      assert {:error, :encryption_failed} =
               Connect.save_credential_configuration(
                 nil,
                 attrs(%{client_secret: "enc:SENTINEL", personal_credential_policy: :required}),
                 :keep,
                 opts
               )
    end
  end

  test "configuration secrets encrypt enc prefix, omission retains and explicit blanks reject" do
    config = credential(%{personal_credential_policy: :required})

    assert {:ok, _} =
             Connect.save_credential_configuration(config, %{"client_secret" => "enc:SENTINEL"})

    assert Repo.reload!(config).client_secret == "enc:SENTINEL"
    refute inspect(Repo.reload!(config)) =~ "SENTINEL"
    assert {:ok, _} = Connect.save_credential_configuration(config, %{})
    assert Repo.reload!(config).client_secret == "enc:SENTINEL"

    for value <- [nil, "", "••••••••", %{}] do
      assert {:error, :invalid_configuration} =
               Connect.save_credential_configuration(config, %{client_secret: value})
    end

    assert {:error, :invalid_configuration} =
             Connect.save_credential_configuration(config, %{provider: "http:999999999"})

    assert {:error, :invalid_configuration} =
             Connect.save_credential_configuration(config, %{
               metadata: %{subject: %{secret: "SENTINEL"}}
             })

    assert {:error, :invalid_configuration} =
             Connect.save_credential_configuration(config, %{metadata: nil})
  end

  test "all auth kinds enforce expiry at the exact clock boundary and global policy states" do
    now = ~U[2030-01-01 00:00:00Z]

    for {auth, extra, material} <- [
          {"api_key", %{}, %{api_key: "key"}},
          {"oauth2", %{client_id: "client"}, %{access_token: "access"}},
          {"jwt_bearer",
           %{
             secret_binding: :grant,
             issuer: "issuer",
             key_id: "key-id",
             metadata: %{"auth_profile_id" => "service_account"}
           }, %{private_key: private_key()}}
        ] do
      config = credential(Map.put(extra, :auth_kind, auth))

      assert {:error, :invalid_material} =
               Connect.replace_credential_grant(config, :org, Map.put(material, :expires_at, now),
                 now: now
               )

      assert {:ok, dto} =
               Connect.replace_credential_grant(
                 config,
                 :org,
                 Map.put(material, :expires_at, DateTime.add(now, 1)),
                 now: now
               )

      for policy <- [:disabled, :optional, :required] do
        assert {:ok, _} =
                 Connect.save_credential_configuration(
                   config,
                   %{personal_credential_policy: policy},
                   :keep,
                   now: now
                 )
      end

      assert {:error, :global_grant_unusable} =
               Connect.save_credential_configuration(
                 config,
                 %{personal_credential_policy: :optional},
                 :keep,
                 now: DateTime.add(now, 1)
               )

      assert {:ok, _} = Connect.revoke_credential_grant(config, :org)
      assert Repo.get!(Grant, dto.grant_id).status == "revoked"

      assert {:ok, _} =
               Connect.save_credential_configuration(config, %{
                 personal_credential_policy: :required
               })

      assert {:error, :global_grant_unusable} =
               Connect.save_credential_configuration(config, %{
                 personal_credential_policy: :disabled
               })
    end
  end

  test "malformed replacements cannot silently retain previously valid secrets" do
    config = credential()
    {:ok, dto} = Connect.replace_credential_grant(config, :org, %{api_key: "original"})

    for material <- [
          %{},
          %{api_key: ""},
          %{api_key: "next", expires_at: "bad"},
          %{api_key: "next", access_token: "wrong-kind"},
          %{:api_key => "one", "api_key" => "two"}
        ] do
      assert {:error, :invalid_material} =
               Connect.replace_credential_grant(config, :org, material)

      assert Repo.get!(Grant, dto.grant_id).api_key == "original"
    end

    assert {:ok, ^dto} =
             Connect.replace_credential_grant(config, :org, %{"api_key" => "original"})

    assert {:ok, _} = Connect.revoke_credential_grant(config, :org)
    assert {:ok, ^dto} = Connect.replace_credential_grant(config, :org, %{api_key: "reconnected"})
  end

  test "literal missing identity and invalid credential references do not resolve aliases" do
    config = credential()

    assert {:error, :person_unavailable} =
             Connect.replace_credential_grant(config, {:person, 999_999_999}, %{api_key: "key"})

    for ref <- [nil, %Credential{}, "bad"] do
      assert {:error, :not_found} = Connect.replace_credential_grant(ref, :org, %{api_key: "key"})
    end

    assert {:ok, %{status: "absent"}} = Connect.revoke_credential_grant(config, :org)
    Repo.delete!(config)
    assert {:error, :not_found} = Connect.save_credential_configuration(config, %{})
  end

  for operation <- [:replace, :revoke], ciphertext_kind <- [:corrupt, :unavailable_key] do
    test "#{operation} clears raw #{ciphertext_kind} ciphertext even when Ecto loads nil" do
      Code.ensure_loaded!(Zaq.TestSupport.ConnectEncryptionConfig)

      ciphertext =
        case unquote(ciphertext_kind) do
          :corrupt ->
            "enc:broken"

          :unavailable_key ->
            {:ok, encrypted} =
              SecretConfig.encrypt("OLD-SENTINEL",
                config: Zaq.TestSupport.ConnectEncryptionConfig,
                encryption_config: [
                  encryption_key: String.duplicate("z", 32),
                  key_id: "unavailable-review-key"
                ]
              )

            encrypted
        end

      config = credential(%{auth_kind: "oauth2", client_id: "client"})
      {:ok, dto} = Connect.replace_credential_grant(config, :org, %{access_token: "old"})

      Repo.query!(
        "UPDATE connect_grants SET api_key = $1, access_token = $1, refresh_token = $1, private_key = $1 WHERE id = $2",
        [ciphertext, dto.grant_id]
      )

      loaded = Repo.get!(Grant, dto.grant_id)

      assert Enum.all?(
               [loaded.api_key, loaded.access_token, loaded.refresh_token, loaded.private_key],
               &is_nil/1
             )

      case unquote(operation) do
        :replace ->
          assert {:ok, ^dto} =
                   Connect.replace_credential_grant(config, :org, %{access_token: "new"})

          assert %{rows: [[nil, stored, nil, nil]]} =
                   Repo.query!(
                     "SELECT api_key, access_token, refresh_token, private_key FROM connect_grants WHERE id = $1",
                     [dto.grant_id]
                   )

          assert {:ok, "new"} = SecretConfig.decrypt(stored)

        :revoke ->
          for _ <- 1..2 do
            assert {:ok, %{status: "revoked"}} = Connect.revoke_credential_grant(config, :org)

            assert %{rows: [[nil, nil, nil, nil]]} =
                     Repo.query!(
                       "SELECT api_key, access_token, refresh_token, private_key FROM connect_grants WHERE id = $1",
                       [dto.grant_id]
                     )
          end
      end
    end
  end

  for field <- [:user_level, :scopes], operation <- [:create, :update] do
    test "#{operation} rejects explicit null #{field} with a safe error before persistence" do
      config = credential(%{personal_credential_policy: :required})
      {:ok, dto} = Connect.replace_credential_grant(config, :org, %{api_key: "original"})
      input = attrs(%{personal_credential_policy: :required}) |> Map.put(unquote(field), nil)
      ref = if unquote(operation) == :create, do: nil, else: config

      assert {:error, :invalid_configuration} =
               Connect.save_credential_configuration(
                 ref,
                 input,
                 {:replace, %{api_key: "SENTINEL"}}
               )

      refute Repo.get_by(Credential, name: input.name)
      assert Repo.reload!(config).name == config.name
      assert Repo.get!(Grant, dto.grant_id).api_key == "original"

      string_input = Map.new(input, fn {key, value} -> {Atom.to_string(key), value} end)

      assert {:error, :invalid_configuration} =
               Connect.save_credential_configuration(ref, string_input)

      assert {:ok, _} =
               Connect.save_credential_configuration(config, %{user_level: false, scopes: []})
    end
  end

  test "nested failed save aborts outer writes without leaking changeset values" do
    config = credential()

    assert {:error, :rollback} =
             Repo.transaction(fn ->
               Repo.update!(Ecto.Changeset.change(config, name: "outer"))

               assert {:error, :invalid_material} =
                        Connect.save_credential_configuration(
                          config,
                          %{name: "inner"},
                          {:replace, %{api_key: ""}}
                        )
             end)

    assert Repo.reload!(config).name == config.name
  end
end
