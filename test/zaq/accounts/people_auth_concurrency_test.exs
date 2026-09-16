defmodule Zaq.Accounts.PeopleAuthConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox

  alias Zaq.Accounts.{
    People,
    PeopleAuth,
    PeoplePermissions,
    Person,
    PersonLoginChallenge,
    PersonSession,
    Team
  }

  alias Zaq.Repo

  setup do
    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, team} =
          People.create_team(%{name: "Auth race #{System.unique_integer([:positive])}"})

        {:ok, _} = PeoplePermissions.grant({:team, team.id}, :access_profile)
        {:ok, person} = People.create_person(%{full_name: "Auth race", team_ids: [team.id]})
        {:ok, survivor} = People.create_person(%{full_name: "Auth survivor", team_ids: [team.id]})

        %{
          team: team,
          person: person,
          survivor: survivor,
          ip: {0, 0, 0, 0, 0, 0, 2, rem(person.id, 65_536)}
        }
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        ids = [fixture.person.id, fixture.survivor.id]
        Repo.delete_all(from p in Person, where: p.id in ^ids)
        Repo.delete_all(from t in Team, where: t.id == ^fixture.team.id)
      end)
    end)

    fixture
  end

  test "simultaneous verification returns exactly one bearer token", %{person: person, ip: ip} do
    {:ok, challenge} = Sandbox.unboxed_run(Repo, fn -> PeopleAuth.issue_challenge(person, ip) end)

    results =
      race(
        for _ <- 1..6,
            do: fn -> PeopleAuth.verify_challenge(challenge.challenge_id, challenge.code) end
      )

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :invalid_challenge}, &1)) == 5

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(from(s in PersonSession, where: s.person_id == ^person.id), :count) ==
               1
    end)
  end

  test "simultaneous malformed attempts commit without exceeding the current cap", %{
    person: person,
    ip: ip
  } do
    {:ok, challenge} = Sandbox.unboxed_run(Repo, fn -> PeopleAuth.issue_challenge(person, ip) end)

    results =
      race(for _ <- 1..8, do: fn -> PeopleAuth.verify_challenge(challenge.challenge_id, nil) end)

    assert Enum.all?(results, &(&1 == {:error, :invalid_challenge}))

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.get!(PersonLoginChallenge, challenge.challenge_id).attempt_count == 5
    end)
  end

  test "simultaneous issuance leaves one unfinished challenge", %{person: person, ip: ip} do
    results = race(for _ <- 1..3, do: fn -> PeopleAuth.issue_challenge(person, ip) end)
    assert Enum.all?(results, &match?({:ok, _}, &1))

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(
               from(c in PersonLoginChallenge,
                 where: c.person_id == ^person.id and is_nil(c.invalidated_at)
               ),
               :count
             ) == 1
    end)
  end

  for operation <- [:revoke, :merge] do
    test "#{operation} waits for in-flight verification and revokes its session", %{
      person: person,
      survivor: survivor,
      ip: ip
    } do
      {:ok, challenge} =
        Sandbox.unboxed_run(Repo, fn -> PeopleAuth.issue_challenge(person, ip) end)

      parent = self()

      verifier =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              {:ok, auth} = PeopleAuth.verify_challenge(challenge.challenge_id, challenge.code)
              send(parent, {:verified, auth})

              receive do
                :release -> auth
              end
            end)
          end)
        end)

      assert_receive {:verified, auth}, 5_000

      revoker =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, :revoking)

            case unquote(operation) do
              :revoke -> PeopleAuth.revoke_all_sessions(person)
              :merge -> People.merge_persons(survivor, person)
            end
          end)
        end)

      try do
        assert_receive :revoking
        send(verifier.pid, :release)
        assert {:ok, ^auth} = Task.await(verifier, 5_000)
        assert {:ok, _} = Task.await(revoker, 5_000)

        Sandbox.unboxed_run(Repo, fn ->
          assert {:error, :invalid_session} = PeopleAuth.authenticate(auth.token)
        end)
      after
        send(verifier.pid, :release)
        Task.shutdown(verifier)
        Task.shutdown(revoker)
      end
    end
  end

  defp race(functions) do
    parent = self()

    tasks =
      Enum.map(functions, fn fun ->
        Task.async(fn -> run_racer(fun, parent) end)
      end)

    for _ <- tasks, do: assert_receive({:ready, _}, 5_000)
    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 10_000))
  end

  defp run_racer(fun, parent) do
    Sandbox.unboxed_run(Repo, fn ->
      send(parent, {:ready, self()})

      receive do
        :go -> fun.()
      end
    end)
  end
end
