defmodule Zaq.Engine.Connect.OAuthConfigurationBoundaryTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties
  alias Zaq.Accounts.{People, Person}
  alias Zaq.Engine.Connect.{Credential, Mutations}

  defp attrs do
    %{
      name: "boundary-#{Ecto.UUID.generate()}",
      provider: "example",
      auth_kind: "oauth2",
      client_id: "client",
      secret_binding: :grant,
      personal_credential_policy: :required
    }
  end

  test "credential candidate representation contains only owned configuration fields" do
    credential = %Credential{
      name: "Candidate",
      provider: "example",
      auth_kind: "oauth2",
      client_id: "client",
      secret_binding: :grant,
      id: 99,
      inserted_at: ~U[2026-10-10 00:00:00Z]
    }

    candidate = Credential.oauth_configuration_attrs(credential)
    refute Map.has_key?(candidate, :id)
    refute Map.has_key?(candidate, :grants)
    refute Map.has_key?(candidate, :inserted_at)
    assert {:ok, restored} = Credential.restore_oauth_configuration(Jason.encode!(candidate))
    assert restored.client_id == credential.client_id
    assert restored.id == nil
    assert {:error, :invalid_configuration} = Credential.restore_oauth_configuration("bad-json")
  end

  property "personal eligibility is owned by the credential and independent of legacy user level" do
    check all(
            policy <- member_of([:disabled, :optional, :required]),
            binding <- member_of([:grant, :configuration]),
            legacy <- boolean()
          ) do
      credential = %Credential{
        personal_credential_policy: policy,
        secret_binding: binding,
        user_level: legacy
      }

      assert Credential.personal_grants_enabled?(credential) ==
               (binding == :grant and policy in [:optional, :required])
    end
  end

  test "OAuth configuration validation requires a caller transaction and rejects changed binding" do
    assert {:error, :transaction_required} = Mutations.prepare_person_oauth_configuration(1)
    {:ok, dto} = Mutations.save_credential_configuration(nil, attrs())
    fingerprint = Mutations.oauth_configuration_fingerprint(dto.credential_id)

    binding = %{
      credential_id: dto.credential_id,
      provider: "example",
      owner: {:person, 1},
      config_fingerprint: fingerprint,
      candidate_config: nil
    }

    assert {:error, :transaction_required} = Mutations.validate_oauth_configuration(binding)

    assert {:ok, %Credential{}} =
             Repo.transaction(fn ->
               {:ok, credential} = Mutations.validate_oauth_configuration(binding)
               credential
             end)

    assert {:error, :invalid_attempt} =
             Repo.transaction(fn ->
               case Mutations.validate_oauth_configuration(%{binding | config_fingerprint: <<0>>}) do
                 {:error, reason} -> Repo.rollback(reason)
               end
             end)
  end

  test "active literal identity lookup rejects nil, inactive and absent identities" do
    person = Repo.insert!(Person.changeset(%Person{}, %{full_name: "Literal owner"}))
    assert People.get_active_literal_person(person.id).id == person.id
    assert People.get_active_literal_person(nil) == nil
    assert People.get_active_literal_person("#{person.id}") == nil
    Repo.update!(Ecto.Changeset.change(person, status: "inactive"))
    assert People.get_active_literal_person(person.id) == nil
    Repo.delete!(Repo.get!(Person, person.id))
    assert People.get_active_literal_person(person.id) == nil
  end
end
