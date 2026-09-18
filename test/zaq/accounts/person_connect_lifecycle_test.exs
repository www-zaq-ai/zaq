defmodule Zaq.Accounts.PersonConnectLifecycleTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Accounts.{People, Person}
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Credential, Grant, MutationEvents, OAuthAttempt, PersonCredentials}
  alias Zaq.System.SecretConfig

  test "multiple losers use persisted ID order per credential, preserving raw winner ciphertext" do
    survivor = person()
    first = person()
    last = person()
    a = credential()
    b = credential()
    c = credential()
    first_grant = grant(a, first)
    discarded = grant(a, last)
    second_grant = grant(b, last)
    untouched = grant(c, survivor)
    before = ciphertext(first_grant)
    untouched_before = ciphertext(untouched)
    attempts = Enum.map([survivor, first, last], &attempt(a, &1))
    clear_jobs()

    assert {:ok, merged} = People.merge_persons(survivor, [last, first, last])
    assert merged.id == survivor.id
    assert Repo.get!(Grant, first_grant.id).owner_id == survivor.id
    assert Repo.get!(Grant, second_grant.id).owner_id == survivor.id
    assert ciphertext(first_grant) == before
    assert ciphertext(untouched) == untouched_before
    refute Repo.get(Grant, discarded.id)
    for attempt <- attempts, do: refute(Repo.get(OAuthAttempt, attempt.id))
    assert {:error, :unauthorized} = PersonCredentials.list_available(first)

    assert Enum.sort(Enum.map(events(), &{&1["credential_id"], &1["owner_id"]})) ==
             Enum.sort([
               {a.id, first.id},
               {a.id, last.id},
               {a.id, survivor.id},
               {b.id, last.id},
               {b.id, survivor.id}
             ])

    assert Enum.all?(events(), &(MutationEvents.validate(&1) == :ok))
  end

  test "legacy revoke rejects a stale canonical grant after real merge; bound revoke targets survivor" do
    survivor = person()
    loser = person()
    credential = credential()
    stale = grant(credential, loser)
    assert {:ok, _} = People.merge_persons(survivor, loser)
    clear_jobs()

    assert {:error, :canonical_grant_requires_owner} = Connect.revoke_grant(stale)
    assert Repo.get!(Grant, stale.id).status == "active"
    assert events() == []
    assert {:ok, _} = Connect.revoke_credential_grant(credential, {:person, survivor.id})
    assert [%{"kind" => "grant_revoked", "owner_id" => owner}] = events()
    assert owner == survivor.id
    assert Repo.get!(Grant, stale.id).api_key == nil
  end

  property "an existing survivor slot wins every status combination without changing ciphertext" do
    check all(
            left <- member_of(~w(active revoked expired)),
            right <- member_of(~w(active revoked expired)),
            max_runs: 12
          ) do
      survivor = person()
      loser = person()
      credential = credential()
      retained = grant(credential, survivor, left)
      removed = grant(credential, loser, right)
      original = ciphertext(retained)
      clear_jobs()
      assert {:ok, _} = People.merge_persons(survivor, loser)
      assert ciphertext(retained) == original
      assert Repo.get!(Grant, retained.id).status == left
      refute Repo.get(Grant, removed.id)
      assert Enum.sort(Enum.map(events(), & &1["owner_id"])) == Enum.sort([survivor.id, loser.id])
    end
  end

  test "single permanent deletion erases grants and attempts and preserves return contract" do
    person = person()
    credential = credential()
    grant = grant(credential, person)
    attempt = attempt(credential, person)
    clear_jobs()
    assert {:ok, %Person{id: id, __meta__: %{state: :deleted}}} = People.delete_person(person)
    assert id == person.id
    refute Repo.get(Grant, grant.id)
    refute Repo.get(OAuthAttempt, attempt.id)
    assert [%{"owner_id" => ^id, "kind" => "grant_deleted"}] = events()
    assert Repo.get(Credential, credential.id)
  end

  for status <- ~w(active revoked expired) do
    test "loser-only #{status} transfers to an inactive survivor without requiring usable secrets" do
      survivor = person()
      loser = person()
      credential = credential()
      transferred = grant(credential, loser, unquote(status))
      # Deliberately unreadable ciphertext must remain byte-for-byte intact.
      Repo.query!("UPDATE connect_grants SET api_key = 'enc:broken' WHERE id = $1", [
        transferred.id
      ])

      Repo.update!(Person.update_changeset(survivor, %{status: "inactive"}))
      original = ciphertext(transferred)
      assert {:ok, _} = People.merge_persons(survivor, loser)
      assert ciphertext(transferred) == original
      assert Repo.get!(Grant, transferred.id).owner_id == survivor.id
      assert Repo.get!(Grant, transferred.id).status == unquote(status)
    end
  end

  test "owner-only changesets reject invalid IDs and retain canonical collision constraints" do
    survivor = person()
    loser = person()
    credential = credential()
    grant(credential, survivor)
    loser_grant = grant(credential, loser)

    for id <- [nil, 0, -1] do
      refute Grant.transfer_owner_changeset(loser_grant, id).valid?
    end

    assert {:error, changeset} =
             loser_grant |> Grant.transfer_owner_changeset(survivor.id) |> Repo.update()

    assert changeset.errors[:credential_id]
  end

  test "bulk deletion with two IDs resolving to the same Person preserves failed-ID contract" do
    survivor = person()
    loser = person()
    assert {:ok, _} = People.merge_persons(survivor, loser)

    assert {:ok, %{deleted_count: 0, failed_ids: [id]}} =
             People.bulk_delete_people([survivor.id, loser.id])

    assert id == loser.id
    assert Repo.get(Person, survivor.id)
  end

  test "failed post-merge resource edit rolls back transferred grant, cancellation and event jobs" do
    survivor = person()
    loser = person()
    credential = credential()
    grant = grant(credential, loser)
    attempt = attempt(credential, loser)
    original = ciphertext(grant)
    clear_jobs()

    assert {:error, :channel_not_found} =
             People.update_person_resource(survivor, %{}, [%{"id" => 9_000_000_000}], %{
               merge_with_person_id: loser.id
             })

    assert Repo.get!(Grant, grant.id).owner_id == loser.id
    assert ciphertext(grant) == original
    assert Repo.get(OAuthAttempt, attempt.id)
    assert events() == []
  end

  test "bulk failure and outer merge/delete failure roll back encrypted rows, attempts and jobs" do
    survivor = person()
    loser = person()
    credential = credential()
    grant = grant(credential, loser)
    attempt = attempt(credential, loser)
    original = ciphertext(grant)
    clear_jobs()

    assert {:ok, %{deleted_count: 0, failed_ids: [9_000_000_000]}} =
             People.bulk_delete_people([loser.id, 9_000_000_000])

    for action <- [
          fn -> People.merge_persons(survivor, loser) end,
          fn -> People.delete_person(loser) end,
          fn -> People.bulk_delete_people([loser.id, survivor.id]) end
        ] do
      assert {:error, :abort} =
               Repo.transaction(fn ->
                 assert {:ok, _} = action.()
                 Repo.rollback(:abort)
               end)

      assert ciphertext(grant) == original
      assert Repo.get(OAuthAttempt, attempt.id)
      assert Repo.get(Person, loser.id)
      assert events() == []
    end

    assert {:ok, %{deleted_count: 2, failed_ids: []}} =
             People.bulk_delete_people([loser.id, survivor.id])

    refute Repo.get(Grant, grant.id)
    refute Repo.get(OAuthAttempt, attempt.id)
  end

  defp person, do: Repo.insert!(Person.changeset(%Person{}, %{full_name: "Lifecycle"}))

  defp credential do
    {:ok, dto} =
      Connect.save_credential_configuration(nil, %{
        name: Ecto.UUID.generate(),
        provider: "example",
        auth_kind: "api_key",
        secret_binding: :grant,
        personal_credential_policy: :required
      })

    Repo.get!(Credential, dto.credential_id)
  end

  defp grant(credential, person, status \\ "active") do
    {:ok, dto} =
      Connect.replace_credential_grant(credential, {:person, person.id}, %{
        api_key: Ecto.UUID.generate()
      })

    Repo.get!(Grant, dto.grant_id) |> Ecto.Changeset.change(status: status) |> Repo.update!()
  end

  defp attempt(credential, person) do
    {:ok, encrypted} = SecretConfig.encrypt("pkce-secret")

    Repo.insert!(
      OAuthAttempt.changeset(%OAuthAttempt{}, %{
        id: Ecto.UUID.generate(),
        credential_id: credential.id,
        owner_type: "person",
        owner_id: person.id,
        provider: "example",
        config_fingerprint: <<1>>,
        redirect_uri: "https://example.com/callback",
        pkce_verifier: encrypted,
        expires_at: DateTime.add(DateTime.utc_now(), 600)
      })
    )
  end

  defp ciphertext(grant),
    do:
      Repo.query!(
        "SELECT api_key, access_token, refresh_token, private_key FROM connect_grants WHERE id = $1",
        [grant.id]
      ).rows

  defp clear_jobs, do: Repo.delete_all(Oban.Job)

  defp events,
    do:
      Repo.all(
        from j in Oban.Job, where: j.queue == "connect_credential_notifications", select: j.args
      )
end
