defmodule Zaq.Accounts.PersonMergeConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Accounts.{People, Person, Team}
  alias Zaq.Repo

  # These races need committed fixtures and independent connections, never a
  # shared DataCase sandbox. Only team interleavings need the alias/team fixture.
  setup context do
    if context[:team_race], do: team_fixture(), else: :ok
  end

  defp team_fixture do
    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        teams =
          for name <- ["A", "B", "C"] do
            {:ok, team} =
              People.create_team(%{
                name: "Concurrency #{name} #{System.unique_integer([:positive])}"
              })

            team.id
          end

        [a, b, _c] = teams
        # The survivor has the higher ID: the merger locks the loser first.
        {:ok, loser} = People.create_person(%{full_name: "Loser", team_ids: [b]})
        {:ok, survivor} = People.create_person(%{full_name: "Survivor", team_ids: [a]})
        {:ok, old_alias} = People.create_person(%{full_name: "Earlier identity"})
        {:ok, _} = People.merge_persons(loser, old_alias)
        %{survivor: survivor, loser: loser, loser_alias: old_alias, teams: teams}
      end)

    ids = Enum.map([fixture.survivor, fixture.loser, fixture.loser_alias], & &1.id)
    cleanup_records(from(p in Person, where: p.id in ^ids), fixture.teams)

    fixture
  end

  test "ordinary person creation and team mutations do not wait for an unrelated merge lock" do
    email = "lock-independent-#{System.unique_integer([:positive])}@example.com"

    team =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, team} = People.create_team(%{name: email})
        team
      end)

    cleanup_records(from(p in Person, where: p.email == ^email), [team.id])
    parent = self()

    holder =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT pg_advisory_xact_lock(20577, 1)")
            send(parent, :locked)

            receive do
              :release -> :ok
            end
          end)
        end)
      end)

    assert_receive :locked

    writer =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          {:ok, person} = People.create_person(%{full_name: "Independent", email: email})
          {:ok, person} = People.assign_team(person, team.id)
          People.unassign_team(person, team.id)
        end)
      end)

    try do
      assert {:ok, {:ok, person}} = Task.yield(writer, 2_000)
      assert person.email == email
      assert person.team_ids == []
    after
      send(holder.pid, :release)
      Task.await(holder)
      Task.shutdown(writer)
    end
  end

  test "opposing concurrent merges serialize without creating a cycle" do
    ids =
      Sandbox.unboxed_run(Repo, fn ->
        for name <- ["Concurrent A", "Concurrent B"] do
          {:ok, person} = People.create_person(%{full_name: name})
          person.id
        end
      end)

    cleanup_records(from(p in Person, where: p.id in ^ids))
    [a, b] = ids
    parent = self()

    tasks =
      for {survivor, loser} <- [{a, b}, {b, a}] do
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:ready, self()})

            receive do
              :merge -> People.merge_persons(survivor, loser)
            end
          end)
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _pid})
    Enum.each(tasks, &send(&1.pid, :merge))
    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:error, :self_merge} in results

    Sandbox.unboxed_run(Repo, fn ->
      assert People.get_person(a).id == People.get_person(b).id
    end)
  end

  for operation <- [:assign_team, :unassign_team], target <- [:survivor, :loser, :loser_alias] do
    @tag team_race: true
    test "#{operation} on #{target} preserves merged teams after its initial read", fixture do
      operation = unquote(operation)
      target = unquote(target)
      person = Map.fetch!(fixture, target)
      {team, expected} = expected_change(operation, target, fixture.teams)

      # Pause at the real Repo query boundary AFTER the initial identity read,
      # before the caller can compute/write memberships. No sleeps or polling.
      {writer, barrier} = paused_task(:first, fn -> apply(People, operation, [person, team]) end)

      try do
        assert_receive {:person_read, ^barrier}, 5_000

        assert {:ok, _} =
                 Sandbox.unboxed_run(Repo, fn ->
                   People.merge_persons(fixture.survivor, fixture.loser)
                 end)

        send(writer.pid, {:resume, barrier})
        assert {:ok, updated} = Task.await(writer, 5_000)
        assert updated.id == fixture.survivor.id
        assert Enum.sort(updated.team_ids) == Enum.sort(expected)

        Sandbox.unboxed_run(Repo, fn ->
          assert Enum.sort(People.get_person!(person.id).team_ids) == Enum.sort(expected)
        end)
      after
        send(writer.pid, {:resume, barrier})
        Task.shutdown(writer, :brutal_kill)
      end
    end

    @tag team_race: true
    test "merge preserves #{operation} on locked #{target} without reversing lock order",
         fixture do
      operation = unquote(operation)
      target = unquote(target)
      person = Map.fetch!(fixture, target)
      {team, expected} = expected_change(operation, target, fixture.teams)

      {writer, writer_barrier} =
        paused_task(:locked, fn -> apply(People, operation, [person, team]) end)

      try do
        assert_receive {:person_read, ^writer_barrier}, 5_000

        {merger, merge_barrier} =
          paused_task(:first, fn -> People.merge_persons(fixture.survivor, fixture.loser) end)

        try do
          # Merger has read the pre-edit profile, while the mutation owns exactly
          # one row lock. It must use its later locked snapshot, not that read.
          assert_receive {:person_read, ^merge_barrier}, 5_000
          send(writer.pid, {:resume, writer_barrier})
          assert {:ok, _} = Task.await(writer, 5_000)
          send(merger.pid, {:resume, merge_barrier})
          assert {:ok, merged} = Task.await(merger, 5_000)
          assert Enum.sort(merged.team_ids) == Enum.sort(expected)
        after
          send(merger.pid, {:resume, merge_barrier})
          Task.shutdown(merger, :brutal_kill)
        end
      after
        send(writer.pid, {:resume, writer_barrier})
        Task.shutdown(writer, :brutal_kill)
      end
    end
  end

  for operation <- [:assign_team, :unassign_team] do
    @tag team_race: true
    test "#{operation} returns not_found when the ID is forgotten during resolution", fixture do
      [a, b, c] = fixture.teams

      {writer, barrier} =
        paused_task(:first, fn ->
          apply(People, unquote(operation), [fixture.loser, c])
        end)

      try do
        assert_receive {:person_read, ^barrier}, 5_000

        assert {:ok, _} =
                 Sandbox.unboxed_run(Repo, fn ->
                   People.merge_persons(fixture.survivor, fixture.loser, retain_redirect: false)
                 end)

        send(writer.pid, {:resume, barrier})
        assert {:error, :not_found} = Task.await(writer, 5_000)

        Sandbox.unboxed_run(Repo, fn ->
          assert Enum.sort(People.get_person!(fixture.survivor.id).team_ids) == Enum.sort([a, b])
          assert People.get_person(fixture.loser_alias.id).id == fixture.survivor.id
        end)
      after
        send(writer.pid, {:resume, barrier})
        Task.shutdown(writer, :brutal_kill)
      end
    end
  end

  defp cleanup_records(people_query, team_ids \\ []) do
    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(people_query)
        Repo.delete_all(from t in Team, where: t.id in ^team_ids)
      end)
    end)
  end

  defp expected_change(:assign_team, _target, [a, b, c]), do: {c, [a, b, c]}
  defp expected_change(:unassign_team, :survivor, [a, b, _c]), do: {a, [b]}
  defp expected_change(:unassign_team, _loser, [a, b, _c]), do: {b, [a]}

  defp paused_task(mode, fun) do
    parent = self()
    barrier = make_ref()

    task =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          handler = {__MODULE__, barrier}

          :ok =
            :telemetry.attach(handler, [:zaq, :repo, :query], &__MODULE__.pause_person_read/4, %{
              owner: self(),
              parent: parent,
              barrier: barrier,
              mode: mode
            })

          try do
            fun.()
          after
            :telemetry.detach(handler)
          end
        end)
      end)

    {task, barrier}
  end

  @doc "Synchronizes tests at a completed Person read on the querying process only."
  def pause_person_read(_event, _measurements, metadata, config) do
    query = Map.get(metadata, :query, "")
    matches = String.starts_with?(query, "SELECT") and String.contains?(query, "FROM \"people\"")
    matches = matches and (config.mode == :first or String.contains?(query, "FOR UPDATE"))

    if self() == config.owner and matches and not Process.get(config.barrier, false) do
      Process.put(config.barrier, true)
      send(config.parent, {:person_read, config.barrier})

      receive do
        {:resume, barrier} when barrier == config.barrier -> :ok
      after
        10_000 -> raise "Person query barrier was not released"
      end
    end
  end
end
