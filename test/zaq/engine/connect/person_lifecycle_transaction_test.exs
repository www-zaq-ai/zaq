defmodule Zaq.Engine.Connect.PersonLifecycleTransactionTest do
  use Zaq.DataCase, async: false
  alias Zaq.Accounts.{People, Person}
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Grant, PersonLifecycle, SecretReconciliationWorker}

  test "invalid merge transfer rolls back grants and emits no notifications" do
    survivor = Repo.insert!(Person.changeset(%Person{}, %{full_name: "Survivor"}))
    loser = Repo.insert!(Person.changeset(%Person{}, %{full_name: "Loser"}))

    {:ok, credential} =
      Connect.create_credential(%{
        name: Ecto.UUID.generate(),
        provider: "example",
        auth_kind: "api_key"
      })

    {:ok, grant} =
      Connect.replace_credential_grant(credential, {:person, loser.id}, %{api_key: "retained"})

    stored_grant = Repo.get!(Grant, grant.grant_id)
    original_owner = {stored_grant.owner_type, stored_grant.owner_id}

    original_ciphertext =
      Repo.query!("SELECT api_key FROM connect_grants WHERE id = $1", [grant.grant_id]).rows
      |> hd()
      |> hd()

    before_jobs = Repo.aggregate(Oban.Job, :count)

    assert {:error, :connect_lifecycle_failed} =
             Repo.transaction(fn -> PersonLifecycle.merge_people(0, [loser.id]) end)

    unchanged_grant = Repo.get!(Grant, grant.grant_id)
    assert {unchanged_grant.owner_type, unchanged_grant.owner_id} == original_owner

    unchanged_ciphertext =
      Repo.query!("SELECT api_key FROM connect_grants WHERE id = $1", [grant.grant_id]).rows
      |> hd()
      |> hd()

    assert unchanged_ciphertext == original_ciphertext
    assert Repo.get!(Person, survivor.id)
    assert Repo.get!(Person, loser.id)
    assert Repo.aggregate(Oban.Job, :count) == before_jobs
  end

  test "real event insertion failure rolls back merge, delete, bulk delete and orphan cleanup" do
    person = Repo.insert!(Person.changeset(%Person{}, %{full_name: "Owner"}))
    survivor = Repo.insert!(Person.changeset(%Person{}, %{full_name: "Survivor"}))

    {:ok, c} =
      Connect.create_credential(%{
        name: Ecto.UUID.generate(),
        provider: "example",
        auth_kind: "api_key"
      })

    {:ok, g} = Connect.replace_credential_grant(c, {:person, person.id}, %{api_key: "retained"})
    before = Repo.aggregate(Oban.Job, :count)

    Repo.query!(
      "ALTER TABLE oban_jobs ADD CONSTRAINT lifecycle_event_failure CHECK (queue <> 'connect_credential_notifications') NOT VALID"
    )

    for operation <- [
          fn -> People.merge_persons(survivor, person) end,
          fn -> People.delete_person(person) end,
          fn -> People.bulk_delete_people([person.id, survivor.id]) end
        ] do
      assert {:error, :mutation_event_enqueue_failed} = operation.()
      assert Repo.get!(Grant, g.grant_id).api_key == "retained"
      assert Repo.get(Person, person.id)
      assert Repo.aggregate(Oban.Job, :count) == before
    end

    Repo.delete!(person)
    assert {:error, :mutation_event_enqueue_failed} = PersonLifecycle.reconcile()
    assert {:error, :reconciliation_failed} = SecretReconciliationWorker.perform(%Oban.Job{})
    assert Repo.get!(Grant, g.grant_id).api_key == "retained"
    assert Repo.aggregate(Oban.Job, :count) == before
  end

  test "worker sanitizes unexpected database errors" do
    Repo.query!("ALTER TABLE connect_oauth_attempts RENAME TO lifecycle_unavailable_attempts")
    assert {:error, :reconciliation_failed} = SecretReconciliationWorker.perform(%Oban.Job{})
  end
end
