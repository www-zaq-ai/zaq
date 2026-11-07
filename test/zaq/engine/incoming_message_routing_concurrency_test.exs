defmodule Zaq.Engine.IncomingMessageRoutingConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Engine.{IncomingMessageRouting, IncomingMessageRoutingRule}
  alias Zaq.Repo
  alias Zaq.System, as: ZaqSystem
  alias Zaq.SystemConfigFixtures

  setup do
    {credential, agent} =
      Sandbox.unboxed_run(Repo, fn ->
        assert IncomingMessageRouting.get_rule(%{}) == nil
        credential = SystemConfigFixtures.ai_credential_fixture()

        agent =
          Repo.insert!(%ConfiguredAgent{
            name: "Bootstrap race #{System.unique_integer([:positive])}",
            job: "Answer",
            model: "gpt-4.1-mini",
            credential_id: credential.id,
            conversation_enabled: true,
            active: true
          })

        {credential, agent}
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        # This synchronous suite owns the previously absent global scope.
        assert {:ok, _} = IncomingMessageRouting.delete_rule(%{})
        Repo.delete!(agent)
        assert {:ok, _} = ZaqSystem.delete_ai_provider_credential(credential)
      end)
    end)

    %{agent: agent}
  end

  for mode <- [:none, :agent] do
    test "bootstrap preserves a concurrent administrative #{mode} insert", %{agent: agent} do
      owner = self()
      mode = unquote(mode)

      admin =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              assert {:ok, rule} =
                       IncomingMessageRouting.upsert_rule(%{}, route_attrs(mode, agent))

              send(owner, {:admin_inserted, self(), rule})

              receive do
                :commit -> rule
              after
                10_000 -> flunk("administrative transaction was not released")
              end
            end)
          end)
        end)

      assert_receive {:admin_inserted, admin_pid, original}, 5_000

      bootstrap =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
            send(owner, {:bootstrap_connection, pid})

            IncomingMessageRouting.apply_rule_commands([
              %{
                routing_mode: :agent,
                configured_agent_id: agent.id,
                write_mode: :insert_if_absent
              }
            ])
          end)
        end)

      assert_receive {:bootstrap_connection, backend_pid}, 5_000
      assert_waiting_on_transaction(backend_pid, System.monotonic_time(:millisecond) + 5_000)
      send(admin_pid, :commit)
      assert {:ok, ^original} = Task.await(admin, 10_000)

      assert {:ok, %{results: [%{status: "noop", rule: %{id: id}}]}} =
               Task.await(bootstrap, 10_000)

      assert id == original.id

      Sandbox.unboxed_run(Repo, fn ->
        assert IncomingMessageRouting.get_rule(%{}) == original
        assert Repo.aggregate(global_rules(), :count) == 1
      end)
    end
  end

  test "two bootstrap writers converge and a later administrator can still update", %{
    agent: agent
  } do
    owner = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(owner, {:ready, self()})

            receive do
              :go ->
                IncomingMessageRouting.apply_rule_commands([
                  %{routing_mode: :none, write_mode: :insert_if_absent}
                ])
            after
              5_000 -> flunk("bootstrap writer was not released")
            end
          end)
        end)
      end

    for _ <- tasks do
      assert_receive {:ready, pid}, 5_000
      send(pid, :go)
    end

    statuses =
      Enum.map(tasks, fn task ->
        assert {:ok, %{results: [%{status: status}]}} = Task.await(task, 10_000)
        status
      end)

    assert Enum.sort(statuses) == ["inserted", "noop"]

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.aggregate(global_rules(), :count) == 1

      assert {:ok, _} =
               IncomingMessageRouting.upsert_rule(%{}, %{
                 routing_mode: :agent,
                 configured_agent_id: agent.id
               })

      assert IncomingMessageRouting.get_rule(%{}).configured_agent_id == agent.id
    end)
  end

  defp route_attrs(:none, _agent), do: %{routing_mode: :none}
  defp route_attrs(:agent, agent), do: %{routing_mode: :agent, configured_agent_id: agent.id}

  defp global_rules do
    from r in IncomingMessageRoutingRule,
      where:
        is_nil(r.person_id) and is_nil(r.channel_config_id) and
          is_nil(r.retrieval_channel_id) and is_nil(r.topic_id)
  end

  defp assert_waiting_on_transaction(pid, deadline) do
    %{rows: [[blocked]]} =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [pid])
      end)

    if not blocked do
      assert System.monotonic_time(:millisecond) < deadline,
             "bootstrap never blocked on the unique index"

      receive do
      after
        10 -> assert_waiting_on_transaction(pid, deadline)
      end
    end
  end
end
