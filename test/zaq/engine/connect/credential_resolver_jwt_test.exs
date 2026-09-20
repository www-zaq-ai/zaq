defmodule Zaq.Engine.Connect.CredentialResolverJWTTest do
  use Zaq.DataCase, async: true
  alias Zaq.Accounts.Person
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.Grant

  @now ~U[2026-09-14 12:00:00Z]

  setup do
    person = Repo.insert!(Person.changeset(%Person{}, %{full_name: "JWT resolver"}))
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])

    {:ok, c} =
      Connect.create_credential(%{
        name: "jwt-#{Ecto.UUID.generate()}",
        provider: "example",
        auth_kind: "jwt_bearer",
        secret_binding: :grant,
        personal_credential_policy: :required,
        issuer: "issuer",
        key_id: "key-id",
        scopes: ["read"],
        metadata: %{
          "auth_profile_id" => "domain_delegated_service_account",
          "subject" => "delegate"
        }
      })

    g =
      %Grant{}
      |> Connect.change_credential_grant(c, %{
        owner_type: "person",
        owner_id: person.id,
        private_key: pem
      })
      |> Repo.insert!()

    %{c: c, g: g, pem: pem, actor: %{person_id: person.id}}
  end

  test "JWT returns only signing material and configured profile", %{
    c: c,
    g: g,
    pem: pem,
    actor: actor
  } do
    assert {:ok, r} = Connect.resolve_credential(c, actor, now: @now)
    assert r.auth_kind == "jwt_bearer"
    assert r.request_format == "bearer"
    assert r.grant_id == g.id

    assert r.authentication == %{
             private_key: pem,
             issuer: "issuer",
             key_id: "key-id",
             subject: "delegate",
             scopes: ["read"],
             auth_profile_id: "domain_delegated_service_account"
           }

    refute inspect(r) =~ "PRIVATE KEY"
    assert {:error, _} = Jason.encode(r)
  end

  for value <- [nil, "broken", "", "••••••••"] do
    @value value
    test "JWT invalid material #{inspect(value)} cannot use configuration key", %{
      c: c,
      g: g,
      pem: pem,
      actor: actor
    } do
      Repo.update!(Ecto.Changeset.change(c, private_key: pem))
      Repo.update!(Ecto.Changeset.change(g, private_key: @value))

      assert Connect.resolve_credential(c, actor, now: @now) ==
               {:error,
                %{credential_id: c.id, reason: :credential_unavailable, owner_type: "person"}}
    end
  end

  test "JWT invalid profile rejects even with usable PEM", %{c: c, actor: actor} do
    Repo.update!(
      Ecto.Changeset.change(c,
        metadata: %{"auth_profile_id" => "unknown", "subject" => "delegate"}
      )
    )

    assert Connect.resolve_credential(c, actor, now: @now) ==
             {:error,
              %{credential_id: c.id, reason: :credential_unavailable, owner_type: "person"}}
  end

  test "RSA private material and service account profile are supported", %{
    c: c,
    g: g,
    actor: actor
  } do
    key = :public_key.generate_key({:rsa, 1024, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
    Repo.update!(Ecto.Changeset.change(c, metadata: %{"auth_profile_id" => "service_account"}))
    Repo.update!(Ecto.Changeset.change(g, private_key: pem, subject: nil))
    assert {:ok, r} = Connect.resolve_credential(c, actor, now: @now)
    assert r.authentication.private_key == pem
    assert r.authentication.subject == nil
    assert r.authentication.auth_profile_id == "service_account"
  end

  test "public PEM and malformed DER are not private signing material", %{
    c: c,
    g: g,
    actor: actor
  } do
    public =
      :public_key.pem_encode([
        :public_key.pem_entry_encode(:RSAPublicKey, {:RSAPublicKey, 123, 65_537})
      ])

    broken = "-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----\n"

    for pem <- [public, broken] do
      Repo.update!(Ecto.Changeset.change(g, private_key: pem))

      assert Connect.resolve_credential(c, actor, now: @now) ==
               {:error,
                %{credential_id: c.id, reason: :credential_unavailable, owner_type: "person"}}
    end
  end

  test "delegated JWT cannot omit its subject", %{c: c, g: g, actor: actor} do
    Repo.update!(
      Ecto.Changeset.change(c,
        metadata: %{"auth_profile_id" => "domain_delegated_service_account"}
      )
    )

    Repo.update!(Ecto.Changeset.change(g, subject: nil))

    assert Connect.resolve_credential(c, actor, now: @now) ==
             {:error,
              %{credential_id: c.id, reason: :credential_unavailable, owner_type: "person"}}
  end
end
