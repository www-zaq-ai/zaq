defmodule Zaq.Engine.Connect.FoundationAcceptanceTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.{People, Person}
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Grant, MutationEvents, PersonCredentials, PersonLifecycle}

  test "optional to required lifecycle keeps ownership, write-only material and event dependencies aligned" do
    alice = Repo.insert!(Person.changeset(%Person{}, %{full_name: "Alice"}))
    bob = Repo.insert!(Person.changeset(%Person{}, %{full_name: "Bob"}))

    assert {:ok, config} =
             Connect.save_credential_configuration(
               nil,
               %{
                 name: Ecto.UUID.generate(),
                 provider: "example",
                 auth_kind: "api_key",
                 secret_binding: :grant,
                 personal_credential_policy: :optional
               },
               {:replace, %{api_key: "GLOBAL_ACCEPTANCE_SENTINEL"}}
             )

    id = config.credential_id

    assert {:ok, %{credential_id: ^id, status: "active"} = dto} =
             PersonCredentials.put_own_authentication(alice, id, %{
               api_key: "ALICE_ACCEPTANCE_SENTINEL"
             })

    assert map_size(dto) == 2
    assert {:ok, personal} = Connect.resolve_credential(id, %{person_id: alice.id})
    assert personal.authentication == %{api_key: "ALICE_ACCEPTANCE_SENTINEL"}
    assert personal.owner_id == alice.id
    assert {:ok, global} = Connect.resolve_credential(id, %{person_id: bob.id})
    assert global.authentication == %{api_key: "GLOBAL_ACCEPTANCE_SENTINEL"}
    assert global.owner_type == "org"

    assert %{rows: [[ciphertext]]} =
             Repo.query!("SELECT api_key FROM connect_grants WHERE id = $1", [personal.grant_id])

    assert String.starts_with?(ciphertext, "enc:")
    refute ciphertext =~ "ACCEPTANCE_SENTINEL"
    assert {:ok, summaries} = PersonCredentials.list_available(alice)
    refute inspect([summaries, dto, personal]) =~ "ACCEPTANCE_SENTINEL"

    assert {:ok, _} = PersonCredentials.revoke_own_grant(alice, id)

    assert {:error, %{reason: :credential_revoked}} =
             Connect.resolve_credential(id, %{person_id: alice.id})

    assert Repo.get!(Grant, personal.grant_id).api_key == nil
    assert {:ok, _} = PersonCredentials.remove_own_grant(alice, id)
    assert {:ok, %{grant_id: global_id}} = Connect.resolve_credential(id, %{person_id: alice.id})
    assert global_id == global.grant_id

    assert {:ok, _} =
             Connect.save_credential_configuration(id, %{personal_credential_policy: :required})

    assert {:error, %{reason: :personal_credential_required}} =
             Connect.resolve_credential(id, %{person_id: alice.id})

    assert {:ok, %{grant_id: ^global_id}} = Connect.resolve_credential(id, nil)

    assert {:ok, _} =
             PersonCredentials.put_own_authentication(alice, id, %{
               api_key: "MERGED_ACCEPTANCE_SENTINEL"
             })

    assert {:ok, _} = People.merge_persons(bob, alice)

    assert {:error, %{reason: :person_unavailable}} =
             Connect.resolve_credential(id, %{person_id: alice.id})

    assert {:error, :unauthorized} = PersonCredentials.list_available(alice)
    assert {:ok, merged} = Connect.resolve_credential(id, %{person_id: bob.id})
    assert merged.authentication == %{api_key: "MERGED_ACCEPTANCE_SENTINEL"}
    assert merged.owner_id == bob.id
    assert {:ok, %{grants_deleted: 0}} = PersonLifecycle.reconcile()

    jobs =
      Repo.all(
        from j in Oban.Job, where: fragment("?->>'credential_id'", j.args) == ^to_string(id)
      )

    assert Enum.all?(jobs, &(MutationEvents.validate(&1.args) == :ok))

    assert Enum.any?(
             jobs,
             &(&1.args["kind"] == "grant_revoked" and &1.args["owner_id"] == alice.id)
           )

    assert Enum.any?(jobs, &(&1.args["owner_id"] == bob.id))
    refute inspect(jobs) =~ "ACCEPTANCE_SENTINEL"
  end
end
