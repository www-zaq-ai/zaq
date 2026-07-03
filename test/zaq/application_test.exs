defmodule Zaq.ApplicationTest do
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Workflows

  setup do
    prev_roles = System.get_env("ROLES")
    prev_app_roles = Application.get_env(:zaq, :roles)
    prev_e2e_routes = Application.get_env(:zaq, :e2e_routes)
    prev_e2e = Application.get_env(:zaq, :e2e)

    on_exit(fn ->
      if prev_roles do
        System.put_env("ROLES", prev_roles)
      else
        System.delete_env("ROLES")
      end

      Application.put_env(:zaq, :roles, prev_app_roles)
      Application.put_env(:zaq, :e2e_routes, prev_e2e_routes)
      Application.put_env(:zaq, :e2e, prev_e2e)
    end)

    :ok
  end

  test "config_change/3 returns :ok" do
    assert :ok = Zaq.Application.config_change(%{}, %{}, [])
  end

  test "prep_stop/1 returns same state" do
    state = %{foo: :bar}
    assert Zaq.Application.prep_stop(state) == state
  end

  @valid_node %{
    name: "fetch",
    type: "action",
    module: "Zaq.Engine.Workflows.Test.InboxWithResults",
    params: %{},
    index: 0
  }
  @source_event %{
    "request" => nil,
    "assigns" => %{"trigger_type" => "manual"},
    "trace_id" => Ecto.UUID.generate()
  }

  defp running_run_with_step do
    {:ok, wf} =
      Workflows.create_workflow(%{name: "App Stop", status: "active", nodes: [@valid_node]})

    {:ok, run} = Workflows.create_run(wf, @source_event)
    {:ok, run} = Workflows.update_run(run, %{status: "running"})

    {:ok, step_run} =
      Workflows.create_step_run(run, %{step_name: "fetch", step_index: 0, status: "running"})

    {run, step_run}
  end

  # Marks `run` as driven by *this* node, mirroring `WorkflowRunAgent.execute/2`,
  # so prep_stop's node-scoped sweep treats it as locally owned.
  defp register_local_driver(run) do
    {:ok, _} = Registry.register(Zaq.Engine.Workflows.RunRegistry, run.id, nil)
    run
  end

  describe "prep_stop/1 on an engine-role node" do
    setup do
      stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
      System.delete_env("ROLES")
      Application.put_env(:zaq, :roles, [:engine])
      :ok
    end

    test "proactively interrupts in-flight runs it is driving with the graceful_shutdown reason" do
      {run, step_run} = running_run_with_step()
      register_local_driver(run)

      assert Zaq.Application.prep_stop(%{}) == %{}

      interrupted = Workflows.get_run!(run.id)
      assert interrupted.status == "interrupted"

      recovered_step =
        run.id |> Workflows.list_step_runs() |> Enum.find(&(&1.id == step_run.id))

      assert recovered_step.status == "failed"
      assert recovered_step.errors["reason"] == "graceful_shutdown"
    end

    test "does not interrupt a stale run being driven by a peer engine node" do
      # Running in the DB but not registered in *this* node's RunRegistry, i.e.
      # another engine node owns it — a rolling deploy must leave it executing.
      {peer_run, peer_step} = running_run_with_step()

      assert Zaq.Application.prep_stop(%{}) == %{}

      assert Workflows.get_run!(peer_run.id).status == "running"

      untouched_step =
        peer_run.id |> Workflows.list_step_runs() |> Enum.find(&(&1.id == peer_step.id))

      assert untouched_step.status == "running"
    end
  end

  describe "prep_stop/1 on a non-engine-role node" do
    setup do
      stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
      System.delete_env("ROLES")
      Application.put_env(:zaq, :roles, [:bo])
      :ok
    end

    test "does not touch runs it never executed" do
      {run, step_run} = running_run_with_step()

      assert Zaq.Application.prep_stop(%{}) == %{}

      # A BO-only node's shutdown must never interrupt a run that could still
      # be executing on a live engine node elsewhere in the cluster.
      untouched = Workflows.get_run!(run.id)
      assert untouched.status == "running"

      untouched_step =
        run.id |> Workflows.list_step_runs() |> Enum.find(&(&1.id == step_run.id))

      assert untouched_step.status == "running"
    end
  end

  test "start/2 handles ROLES from app config when env var is missing" do
    System.delete_env("ROLES")
    Application.put_env(:zaq, :roles, [:agent])
    Application.put_env(:zaq, :e2e_routes, false)
    Application.put_env(:zaq, :e2e, false)

    assert {:error, {:already_started, _pid}} = Zaq.Application.start(:normal, [])
  end

  test "start/2 parses ROLES env and handles e2e flags enabled" do
    System.put_env("ROLES", "agent, channels")
    Application.put_env(:zaq, :roles, [:bo])
    Application.put_env(:zaq, :e2e_routes, true)
    Application.put_env(:zaq, :e2e, true)

    assert {:error, {:already_started, _pid}} = Zaq.Application.start(:normal, [])
  end
end
