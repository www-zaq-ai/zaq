unless Code.ensure_loaded?(Zaq.Repo.Migrations.AddCanonicalConnectGrantStorage) do
  Code.require_file(
    "../../../../priv/repo/migrations/20260913102416_add_canonical_connect_grant_storage.exs",
    __DIR__
  )
end

defmodule Zaq.Engine.Connect.CanonicalConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Accounts.Person
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Credential, Grant}
  alias Zaq.Repo

  test "accepted deletion between current-Person check and insert can leave an orphan" do
    {credential, person} =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, credential} =
          Connect.create_credential(%{
            name: "orphan-#{Ecto.UUID.generate()}",
            provider: "example",
            auth_kind: "api_key"
          })

        {credential, Repo.insert!(%Person{full_name: "Concurrent owner"})}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from c in Credential, where: c.id == ^credential.id)
        Repo.delete_all(from p in Person, where: p.id == ^person.id)
      end)
    end)

    parent = self()

    task =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          changeset =
            Connect.change_credential_grant(%Grant{}, credential, %{
              owner_type: "person",
              owner_id: person.id,
              api_key: "orphan-secret"
            })

          assert changeset.valid?
          %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:checked, self(), backend})

          receive do
            :insert -> Repo.insert(changeset)
          after
            5_000 -> raise "orphan barrier timed out"
          end
        end)
      end)

    assert_receive {:checked, writer, writer_backend}, 5_000

    Sandbox.unboxed_run(Repo, fn ->
      %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
      refute backend == writer_backend
      Repo.delete!(person)
    end)

    send(writer, :insert)
    assert {:ok, grant} = Task.await(task, 5_000)

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.get(Person, person.id) == nil
      assert Repo.reload!(grant).api_key == "orphan-secret"
      changeset = Connect.change_credential_grant(grant, credential, %{api_key: "replacement"})
      assert {:error, _} = Repo.update(changeset)
    end)
  end

  test "real rollback refuses canonical data and configuration without losing secrets" do
    # Committed fixtures survive the expected migrator transaction rollback.
    Sandbox.unboxed_run(Repo, fn ->
      {:ok, config} =
        Connect.create_credential(%{
          name: "rollback-#{Ecto.UUID.generate()}",
          provider: "example",
          auth_kind: "api_key"
        })

      person = Repo.insert!(%Person{full_name: "Rollback owner"})

      try do
        {:ok, grant} =
          %Grant{}
          |> Connect.change_credential_grant(
            config,
            %{
              owner_type: "person",
              owner_id: person.id,
              api_key: "secret",
              status: "revoked"
            }
          )
          |> Repo.insert()

        migration = Zaq.Repo.Migrations.AddCanonicalConnectGrantStorage
        version = 20_260_913_102_416

        assert_raise Postgrex.Error, ~r/canonical Connect grants exist/, fn ->
          Ecto.Migrator.down(Repo, version, migration, log: false, migration_lock: false)
        end

        assert Repo.reload!(grant).api_key == "secret"

        assert :already_up =
                 Ecto.Migrator.up(Repo, version, migration, log: false, migration_lock: false)

        Repo.delete!(grant)
        {:ok, _} = Connect.update_credential(config, %{secret_binding: :grant})

        assert_raise Postgrex.Error, ~r/canonical Connect configuration exists/, fn ->
          Ecto.Migrator.down(Repo, version, migration, log: false, migration_lock: false)
        end

        assert Repo.reload!(config).secret_binding == :grant
      after
        Repo.delete_all(from c in Credential, where: c.id == ^config.id)
        Repo.delete_all(from p in Person, where: p.id == ^person.id)
      end
    end)
  end

  for owner_type <- ["org", "person"] do
    test "concurrent committed inserts occupy exactly one #{owner_type} slot" do
      {credential, person} =
        Sandbox.unboxed_run(Repo, fn ->
          {:ok, credential} =
            Connect.create_credential(%{
              name: "race-#{Ecto.UUID.generate()}",
              provider: "example",
              auth_kind: "api_key"
            })

          person = Repo.insert!(%Person{full_name: "Race owner"})
          {credential, person}
        end)

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(from c in Credential, where: c.id == ^credential.id)
          Repo.delete_all(from p in Person, where: p.id == ^person.id)
        end)
      end)

      owner =
        case unquote(owner_type) do
          "org" -> %{owner_type: "org"}
          "person" -> %{owner_type: "person", owner_id: person.id}
        end

      parent = self()

      tasks =
        for status <- ["revoked", "expired"] do
          Task.async(fn ->
            Sandbox.unboxed_run(Repo, fn ->
              %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
              send(parent, {:ready, self(), backend})

              receive do
                :insert ->
                  %Grant{}
                  |> Connect.change_credential_grant(
                    credential,
                    Map.merge(owner, %{api_key: "secret", status: status})
                  )
                  |> Repo.insert()
              after
                5_000 -> raise "insert barrier timed out"
              end
            end)
          end)
        end

      assert_receive {:ready, first, backend1}, 5_000
      assert_receive {:ready, second, backend2}, 5_000
      refute backend1 == backend2
      send(first, :insert)
      send(second, :insert)
      results = Enum.map(tasks, &Task.await(&1, 5_000))
      assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
      assert [{:error, changeset}] = Enum.filter(results, &match?({:error, _}, &1))
      assert Zaq.DataCase.errors_on(changeset).credential_id == ["has already been taken"]

      Sandbox.unboxed_run(Repo, fn ->
        assert [stored] = Repo.all(from g in Grant, where: g.credential_id == ^credential.id)
        assert stored.id == winner.id
        assert stored.status in ["revoked", "expired"]
        assert stored.api_key == "secret"
      end)
    end
  end
end
