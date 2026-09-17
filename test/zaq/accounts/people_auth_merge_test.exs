defmodule Zaq.Accounts.PeopleAuthMergeTest do
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.{
    People,
    PeopleAuth,
    PeoplePermissionGrant,
    PeoplePermissions,
    PersonLoginChallenge,
    PersonSession
  }

  setup do
    Repo.delete_all(PeoplePermissionGrant)
    {:ok, _} = PeoplePermissions.grant(:everyone, :access_profile)

    participants =
      for index <- 1..3 do
        {:ok, person} = People.create_person(%{full_name: "Auth merge #{index}"})
        ip = {0, 0, 0, 0, 0, 0, 1, rem(person.id, 65_536)}
        {:ok, issued} = PeopleAuth.issue_challenge(person, ip)
        {:ok, auth} = PeopleAuth.verify_challenge(issued.challenge_id, issued.code)
        {:ok, challenge} = PeopleAuth.issue_challenge(person, ip)
        %{person: person, auth: auth, challenge: challenge}
      end

    %{participants: participants}
  end

  test "merge revokes survivor and all losers without transferring credentials", %{
    participants: [survivor | losers] = participants
  } do
    assert {:ok, merged} = People.merge_persons(survivor.person, Enum.map(losers, & &1.person))
    assert merged.id == survivor.person.id
    assert Repo.get!(PersonSession, survivor.auth.session.id).revoked_at
    assert Repo.get!(PersonLoginChallenge, survivor.challenge.challenge_id).invalidated_at

    for %{person: person, auth: auth, challenge: challenge} <- participants do
      assert People.get_person(person.id).id == merged.id
      assert {:error, :invalid_session} = PeopleAuth.authenticate(auth.token)

      assert {:error, :invalid_challenge} =
               PeopleAuth.verify_challenge(challenge.challenge_id, challenge.code)
    end

    for loser <- losers do
      refute Repo.get(PersonSession, loser.auth.session.id)
      refute Repo.get(PersonLoginChallenge, loser.challenge.challenge_id)
    end

    assert {:ok, sessions} = PeopleAuth.list_sessions(merged)
    assert Enum.map(sessions, & &1.id) == [survivor.auth.session.id]
  end

  test "outer merge rollback restores authentication for every participant", %{
    participants: [survivor | losers] = participants
  } do
    assert {:error, :later_failure} =
             Repo.transaction(fn ->
               assert {:ok, _} =
                        People.merge_persons(survivor.person, Enum.map(losers, & &1.person))

               assert Repo.get!(PersonSession, survivor.auth.session.id).revoked_at
               Repo.rollback(:later_failure)
             end)

    for %{auth: auth, challenge: challenge} <- participants do
      assert {:ok, _} = PeopleAuth.authenticate(auth.token)
      refute Repo.get!(PersonLoginChallenge, challenge.challenge_id).invalidated_at
      assert {:ok, _} = PeopleAuth.verify_challenge(challenge.challenge_id, challenge.code)
    end
  end

  test "merge can revoke when current authentication config is corrupt", %{
    participants: [survivor | losers]
  } do
    {:ok, _} = Zaq.System.set_config("people_access.otp_max_attempts", "corrupt")
    assert {:ok, _} = People.merge_persons(survivor.person, Enum.map(losers, & &1.person))
    assert Repo.get!(PersonSession, survivor.auth.session.id).revoked_at
    assert Repo.get!(PersonLoginChallenge, survivor.challenge.challenge_id).invalidated_at
  end
end
