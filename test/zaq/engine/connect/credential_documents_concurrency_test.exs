defmodule Zaq.Engine.Connect.CredentialDocumentsConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Zaq.CredentialDocumentFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.Credential
  alias Zaq.Repo

  setup do
    binding = Sandbox.unboxed_run(Repo, &credential_document_fixture/0)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from c in ChannelConfig, where: c.id == ^binding.channel_config_id)
        Repo.delete_all(from c in Credential, where: c.id == ^binding.credential_id)

        Repo.delete_all(
          from j in Oban.Job,
            where:
              j.queue == "connect_credential_notifications" and
                fragment("args->>'credential_id' = ?", ^to_string(binding.credential_id))
        )
      end)
    end)

    %{binding: binding}
  end

  for first_operation <- [:put, :revoke, :disable] do
    test "independent writer waits for committed #{first_operation} and revalidates", %{
      binding: binding
    } do
      parent = self()

      holder =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              config =
                Repo.one!(
                  from c in ChannelConfig,
                    where: c.id == ^binding.channel_config_id,
                    lock: "FOR UPDATE"
                )

              %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
              send(parent, {:locked, self(), backend})

              receive do
                :commit -> first_operation(unquote(first_operation), binding, config)
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
            operation(binding, :put, "second", "second-value")
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

      send(writer, :commit)
      assert {:ok, :ok} = Task.await(holder, 5_000)
      result = Task.await(contender, 5_000)

      Sandbox.unboxed_run(Repo, fn ->
        case unquote(first_operation) do
          :put ->
            assert result == :ok
            assert {:ok, "first-value"} = operation(binding, :get, "first")
            assert {:ok, "second-value"} = operation(binding, :get, "second")

          :revoke ->
            assert result == {:error, :credential_revoked}

          :disable ->
            assert result == {:error, :connector_unavailable}
        end
      end)
    end
  end

  test "outer rollback erases both document mutation and its notification", %{binding: binding} do
    Sandbox.unboxed_run(Repo, fn ->
      count = Repo.aggregate(notification_query(binding), :count)

      assert {:error, :abort} =
               Repo.transaction(fn ->
                 assert :ok = operation(binding, :put, "uncommitted", "private")
                 Repo.rollback(:abort)
               end)

      assert :error = operation(binding, :get, "uncommitted")
      assert Repo.aggregate(notification_query(binding), :count) == count
    end)
  end

  defp first_operation(:put, binding, _config),
    do: operation(binding, :put, "first", "first-value")

  defp first_operation(:revoke, binding, _config) do
    {:ok, _} = Connect.revoke_credential_grant(binding.credential_id, :org)
    :ok
  end

  defp first_operation(:disable, _binding, config) do
    Repo.update!(Ecto.Changeset.change(config, enabled: false))
    :ok
  end

  defp operation(binding, op, key, value \\ nil),
    do:
      Connect.credential_document(%{
        binding: binding,
        op: op,
        namespace: "session",
        key: key,
        value: value
      })

  defp notification_query(binding) do
    from j in Oban.Job,
      where:
        j.queue == "connect_credential_notifications" and
          fragment("args->>'credential_id' = ?", ^to_string(binding.credential_id))
  end

  # Observe the actual PostgreSQL lock graph, not a sleep or shared sandbox connection.
  defp assert_blocked_by(waiter, holder, deadline) do
    %{rows: [[blocked?]]} =
      Repo.query!("SELECT $1::integer = ANY(pg_blocking_pids($2::integer))", [holder, waiter])

    unless blocked? do
      assert System.monotonic_time(:millisecond) < deadline,
             "writer never waited for the connector transaction"

      assert_blocked_by(waiter, holder, deadline)
    end
  end
end
