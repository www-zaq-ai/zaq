defmodule Zaq.Engine.Connect.PersonLifecycleConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Accounts.{People, Person}
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Credential, Grant, PersonCredentials, PersonLifecycle}
  alias Zaq.Repo

  setup do
    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        person = Repo.insert!(Person.changeset(%Person{}, %{full_name: "Lifecycle race"}))
        survivor = Repo.insert!(Person.changeset(%Person{}, %{full_name: "Survivor"}))

        {:ok, c} =
          Connect.create_credential(%{
            name: Ecto.UUID.generate(),
            provider: "example",
            auth_kind: "api_key",
            secret_binding: :grant,
            personal_credential_policy: :disabled
          })

        %{person: person, survivor: survivor, credential: c}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from c in Credential, where: c.id == ^fixture.credential.id)

        Repo.delete_all(
          from p in Person, where: p.id in ^[fixture.person.id, fixture.survivor.id]
        )

        Repo.delete_all(
          from j in Oban.Job,
            where: fragment("?->>'credential_id'", j.args) == ^to_string(fixture.credential.id)
        )
      end)
    end)

    fixture
  end

  for action <- [:delete, :merge] do
    test "accepted late storage orphan after #{action} is unresolvable even disabled and erased next pass",
         f do
      parent = self()

      task =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            changeset =
              Connect.change_credential_grant(%Grant{}, f.credential, %{
                owner_type: "person",
                owner_id: f.person.id,
                api_key: "late-secret"
              })

            assert changeset.valid?
            send(parent, :validated)

            receive do
              :insert -> Repo.insert(changeset)
            after
              5_000 -> flunk("storage barrier timeout")
            end
          end)
        end)

      assert_receive :validated, 5_000
      Sandbox.unboxed_run(Repo, fn -> mutate(unquote(action), f) end)
      send(task.pid, :insert)
      assert {:ok, orphan} = Task.await(task, 5_000)

      Sandbox.unboxed_run(Repo, fn ->
        assert {:error, %{reason: :person_unavailable}} =
                 Connect.resolve_credential(f.credential, %{person: %{id: f.person.id}})

        assert {:error, :unauthorized} = PersonCredentials.list_available(f.person)
        assert Repo.get(Grant, orphan.id)
        assert {:ok, %{grants_deleted: 1}} = PersonLifecycle.reconcile()
        refute Repo.get(Grant, orphan.id)
        assert Repo.get(Person, f.survivor.id)
        assert {:ok, %{grants_deleted: 0}} = PersonLifecycle.reconcile()
      end)
    end
  end

  test "concurrent cleanup is idempotent and emits exactly one deletion dependency", f do
    orphan =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, g} =
          Connect.replace_credential_grant(f.credential, {:person, f.person.id}, %{
            api_key: "orphan"
          })

        Repo.delete!(f.person)
        g
      end)

    tasks =
      for _ <- 1..2,
          do:
            Task.async(fn -> Sandbox.unboxed_run(Repo, fn -> PersonLifecycle.reconcile() end) end)

    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.sum(Enum.map(results, fn {:ok, r} -> r.grants_deleted end)) == 1

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(
               from(j in Oban.Job,
                 where:
                   fragment("?->>'grant_id'", j.args) == ^to_string(orphan.grant_id) and
                     fragment("?->>'kind'", j.args) == "grant_deleted"
               ),
               :count
             ) == 1
    end)
  end

  test "canonical credential lock and merger Person locks cannot deadlock and merge retains latest issue",
       f do
    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, _} =
               Connect.replace_credential_grant(f.credential, {:person, f.person.id}, %{
                 api_key: "before"
               })
    end)

    {writer, writer_ref} =
      paused_query("connect_credentials", fn ->
        Connect.replace_credential_grant(f.credential, {:person, f.person.id}, %{
          api_key: "latest"
        })
      end)

    assert_receive {:selected, ^writer_ref}, 5_000
    # The credential lock is held. Pause merger at its first Connect query, after
    # the existing advisory and Person locks. Writer must not need either lock.
    {merger, merge_ref} =
      paused_query("connect_grants", fn -> People.merge_persons(f.survivor, f.person) end)

    assert_receive {:selected, ^merge_ref}, 5_000
    send(writer.pid, {:resume, writer_ref})
    assert {:ok, issued} = Task.await(writer, 5_000)
    send(merger.pid, {:resume, merge_ref})
    assert {:ok, _} = Task.await(merger, 5_000)

    Sandbox.unboxed_run(Repo, fn ->
      assert %{owner_id: owner, api_key: "latest"} = Repo.get!(Grant, issued.grant_id)
      assert owner == f.survivor.id
    end)
  end

  test "reconciliation rechecks a selected owner after acquiring credential locks", f do
    grant =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, grant} =
          Connect.replace_credential_grant(f.credential, {:person, f.person.id}, %{
            api_key: "keep"
          })

        Repo.delete!(f.person)
        grant
      end)

    {task, ref} = paused_query("connect_grants", fn -> PersonLifecycle.reconcile() end)
    assert_receive {:selected, ^ref}, 5_000
    # An explicit restoration tests the destructive recheck. Operationally IDs must
    # not be reused: arbitrary new identities must never inherit this credential.
    Sandbox.unboxed_run(Repo, fn ->
      Repo.insert!(%Person{id: f.person.id, full_name: "Restored original"})
    end)

    send(task.pid, {:resume, ref})
    assert {:ok, %{grants_deleted: 0}} = Task.await(task, 5_000)
    Sandbox.unboxed_run(Repo, fn -> assert Repo.get!(Grant, grant.grant_id).api_key == "keep" end)
  end

  for action <- [:delete, :merge] do
    test "authenticated issuance paused after identity read rejects after #{action}", f do
      Sandbox.unboxed_run(Repo, fn ->
        assert {:ok, _} =
                 Connect.update_credential(f.credential, %{personal_credential_policy: :required})
      end)

      {task, ref} =
        paused_query("people", fn ->
          PersonCredentials.put_own_authentication(f.person, f.credential.id, %{api_key: "late"})
        end)

      assert_receive {:selected, ^ref}, 5_000
      Sandbox.unboxed_run(Repo, fn -> mutate(unquote(action), f) end)
      send(task.pid, {:resume, ref})
      assert {:error, :unauthorized} = Task.await(task, 5_000)
    end
  end

  defp mutate(:delete, f), do: assert({:ok, _} = People.delete_person(f.person))
  defp mutate(:merge, f), do: assert({:ok, _} = People.merge_persons(f.survivor, f.person))

  defp paused_query(source, fun) do
    ref = make_ref()
    parent = self()

    task =
      Task.async(fn ->
        receive do
          :start -> Sandbox.unboxed_run(Repo, fun)
        end
      end)

    :ok =
      :telemetry.attach(ref, [:zaq, :repo, :query], &__MODULE__.pause_query/4, %{
        caller: task.pid,
        parent: parent,
        ref: ref,
        source: source
      })

    on_exit(fn -> :telemetry.detach(ref) end)
    send(task.pid, :start)
    {task, ref}
  end

  def pause_query(_, _, metadata, config) do
    if self() == config.caller and metadata.source == config.source and
         not Process.get(config.ref, false) do
      Process.put(config.ref, true)
      send(config.parent, {:selected, config.ref})

      receive do
        {:resume, ref} when ref == config.ref -> :ok
      after
        5_000 -> raise "query barrier timeout"
      end
    end
  end
end
