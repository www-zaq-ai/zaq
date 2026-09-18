defmodule Zaq.Engine.Connect.MutationConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.{Credential, Grant}
  alias Zaq.Repo

  for operation <- [:replace, :revoke, :remove], occupied? <- [false, true] do
    test "independent committed #{operation} serializes behind credential lock (occupied: #{occupied?})" do
      config =
        Sandbox.unboxed_run(Repo, fn ->
          {:ok, row} =
            Connect.create_credential(%{
              name: "race-#{Ecto.UUID.generate()}",
              provider: "example",
              auth_kind: "api_key"
            })

          if unquote(occupied?) do
            {:ok, _} = Connect.replace_credential_grant(row, :org, %{api_key: "initial"})
          end

          row
        end)

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(from c in Credential, where: c.id == ^config.id)

          Repo.delete_all(
            from j in Oban.Job,
              where:
                j.queue == "connect_credential_notifications" and
                  fragment("args->>'credential_id' = ?", ^to_string(config.id))
          )
        end)
      end)

      parent = self()

      holder =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              Repo.one!(from c in Credential, where: c.id == ^config.id, lock: "FOR UPDATE")
              %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
              send(parent, {:locked, self(), backend})

              receive do
                :release -> Connect.replace_credential_grant(config, :org, %{api_key: "first"})
              after
                5_000 -> raise "lock barrier timeout"
              end
            end)
          end)
        end)

      assert_receive {:locked, writer, first_backend}, 5_000

      contender =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:ready, backend})

            case unquote(operation) do
              :replace -> Connect.replace_credential_grant(config, :org, %{api_key: "second"})
              :revoke -> Connect.revoke_credential_grant(config, :org)
              :remove -> Connect.remove_credential_grant(config, :org)
            end
          end)
        end)

      assert_receive {:ready, second_backend}, 5_000
      refute first_backend == second_backend

      Sandbox.unboxed_run(Repo, fn ->
        assert_blocked_by(
          second_backend,
          first_backend,
          System.monotonic_time(:millisecond) + 3_000
        )
      end)

      send(writer, :release)
      assert {:ok, {:ok, first}} = Task.await(holder, 5_000)
      assert {:ok, result} = Task.await(contender, 5_000)

      Sandbox.unboxed_run(Repo, fn ->
        case unquote(operation) do
          :replace ->
            assert result.grant_id == first.grant_id
            assert Repo.get!(Grant, first.grant_id).api_key == "second"

          :revoke ->
            assert result.grant_id == first.grant_id
            assert Repo.get!(Grant, first.grant_id).status == "revoked"
            assert Repo.get!(Grant, first.grant_id).api_key == nil

          :remove ->
            refute Repo.get(Grant, first.grant_id)
        end
      end)
    end
  end

  # Observe PostgreSQL's actual lock graph before releasing the holder. A bounded
  # observation loop is needed because a client-side ready message precedes the
  # query; there is no production notification when PostgreSQL enters a lock wait.
  # No sleeps, elapsed-time success assertions, or production test hooks are used.
  defp assert_blocked_by(waiter, holder, deadline) do
    %{rows: [[blocked?]]} =
      Repo.query!("SELECT $1::integer = ANY(pg_blocking_pids($2::integer))", [holder, waiter])

    unless blocked? do
      assert System.monotonic_time(:millisecond) < deadline,
             "contender never entered a PostgreSQL lock wait behind the credential holder"

      assert_blocked_by(waiter, holder, deadline)
    end
  end
end
