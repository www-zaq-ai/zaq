defmodule Zaq.Engine.Workflows.ValidatedExecutionTest do
  use Zaq.DataCase, async: true

  alias Jido.Action.Error
  alias Zaq.Agent.Tools.General.{DecodeBase64, EncodeBase64}
  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.{ExecutionPolicy, Step, StepRunner, Workflow}
  alias Zaq.Engine.Workflows.Test.{AttemptProbe, ValidationProbe}
  alias Zaq.Repo

  @event %{request: nil, assigns: %{trigger_type: "manual"}}

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  defp workflow(nodes, edges) do
    Repo.insert!(%Workflow{
      name: "validated-#{System.unique_integer([:positive])}",
      status: "active",
      nodes: Enum.map(nodes, &struct(Step.Node, &1)),
      edges: Enum.map(edges, &struct(Step.Edge, &1))
    })
  end

  for timeout <- [nil, 1_000] do
    test "minimal Base64 inputs receive defaults with timeout #{inspect(timeout)}" do
      wf = workflow([], [])
      {:ok, run} = Workflows.create_run(wf, @event)

      for {mod, data, output} <- [
            {EncodeBase64, "hello", %{encoded: "aGVsbG8="}},
            {DecodeBase64, "aGVsbG8=", %{decoded: "hello", text?: true, byte_size: 5}}
          ] do
        name = mod.name()

        params = %{
          wrapped_module: mod,
          run_id: run.id,
          step_name: name,
          step_index: 0,
          timeout_ms: unquote(timeout),
          data: data
        }

        assert {:ok, result} =
                 Jido.Exec.run(StepRunner, params, %{}, ExecutionPolicy.outer_options())

        assert Map.take(result, Map.keys(output)) == output
        row = Workflows.get_terminal_step_run(run.id, name)
        assert row.input == %{"data" => data}
        assert row.status == "completed"
      end
    end
  end

  test "workflow EncodeBase64 applies omitted defaults through the execution seam" do
    wf =
      workflow(
        [
          %{
            name: "encode",
            type: "action",
            module: "Zaq.Agent.Tools.General.EncodeBase64",
            params: %{"data" => "hello"},
            index: 0
          }
        ],
        []
      )

    assert {:ok, %{status: "completed"} = run} = Workflows.create_and_start_run(wf, @event)

    step = Workflows.get_terminal_step_run(run.id, "encode")

    assert step.status == "completed"
    assert step.input == %{"data" => "hello"}

    # `aGVsbG8=` proves both declared defaults were applied: the standard
    # alphabet and enabled padding. A direct `EncodeBase64.run/2` call would
    # fail its required `variant`/`padding` pattern match instead.
    assert step.results["encoded"] == "aGVsbG8="
  end

  test "required, type and enum violations persist validation failures" do
    wf = workflow([], [])
    {:ok, run} = Workflows.create_run(wf, @event)

    for {input, index} <- Enum.with_index([%{}, %{data: 42}, %{data: "hello", variant: "bad"}]) do
      params =
        Map.merge(input, %{
          wrapped_module: EncodeBase64,
          run_id: run.id,
          step_name: "invalid-#{index}",
          step_index: index
        })

      assert {:error, error} =
               Jido.Exec.run(StepRunner, params, %{}, ExecutionPolicy.outer_options())

      assert Error.to_map(error).type == :validation_error
      row = Workflows.get_terminal_step_run(run.id, "invalid-#{index}")
      assert row.status == "failed"
      assert row.errors["type"] == "validation_error"
      assert row.results == nil
    end
  end

  test "map bodies validate Base64 defaults through the same persisted boundary" do
    wf =
      workflow(
        [
          %{
            name: "emit",
            type: "action",
            module: "Zaq.Engine.Workflows.Test.EmitItems",
            params: %{},
            index: 0
          },
          %{
            name: "m",
            type: "map",
            index: 1,
            params: %{
              "over" => "items",
              "strategy" => "fail_workflow",
              "body" => [
                %{
                  "name" => "encode",
                  "type" => "action",
                  "module" => "Zaq.Agent.Tools.General.EncodeBase64",
                  "params" => %{"data" => "hello"}
                },
                %{
                  "name" => "decode",
                  "type" => "action",
                  "module" => "Zaq.Agent.Tools.General.DecodeBase64",
                  "params" => %{"data" => "aGVsbG8="}
                }
              ]
            }
          }
        ],
        [%{from: "emit", to: "m"}]
      )

    assert {:ok, run} = Workflows.create_and_start_run(wf, @event)
    assert run.status == "completed"

    for index <- 0..2 do
      assert Workflows.get_terminal_step_run(run.id, "m/encode[#{index}]").results["encoded"] ==
               "aGVsbG8="

      assert Workflows.get_terminal_step_run(run.id, "m/decode[#{index}]").results["decoded"] ==
               "hello"
    end
  end

  test "validation hooks run once and actual action metadata replaces wrapper metadata" do
    {:ok, run} = Workflows.create_run(workflow([], []), @event)

    params = %{
      wrapped_module: ValidationProbe,
      run_id: run.id,
      step_name: "probe",
      step_index: 0,
      observer: self() |> :erlang.pid_to_list() |> to_string()
    }

    assert {:ok, %{value: 1}} =
             Jido.Exec.run(StepRunner, params, %{}, ExecutionPolicy.outer_options())

    assert_receive :before_params
    assert_receive {:after_params, 1}
    assert_receive {:executed, "workflow_validation_probe", nil, false}
    assert_receive :before_output
    assert_receive :after_output
    refute_received :before_params
    refute_received :before_output

    assert Workflows.get_terminal_step_run(run.id, "probe").input == %{
             "observer" => params.observer
           }
  end

  test "refinement failure prevents execution and output failure is never retried" do
    {:ok, run} = Workflows.create_run(workflow([], []), @event)

    params = %{
      wrapped_module: ValidationProbe,
      run_id: run.id,
      step_name: "probe",
      step_index: 0,
      observer: self() |> :erlang.pid_to_list() |> to_string(),
      __map_index__: 0,
      __map_strategy__: "retry"
    }

    assert {:ok, %{"__map_error__" => true}} = StepRunner.run(Map.put(params, :value, 0), %{})
    assert_receive :before_params
    refute_received {:after_params, _}
    refute_received {:executed, _, _, _}

    assert {:ok, %{"__map_error__" => true}} =
             StepRunner.run(%{params | step_name: "output"}, %{invalid_output: true})

    assert_receive :before_params
    assert_receive {:after_params, 1}
    assert_receive {:executed, "workflow_validation_probe", nil, false}
    assert_receive :before_output
    refute_received :after_output
    refute_received {:executed, _, _, _}
    row = Workflows.get_terminal_step_run(run.id, "output[0]")
    assert row.errors["type"] == "validation_error"
    assert row.results == nil
  end

  test "persisted retry forks have three transient attempts but one deterministic attempt" do
    {:ok, run} = Workflows.create_run(workflow([], []), @event)

    for mode <- [:transient, :deterministic] do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

      params = %{
        wrapped_module: AttemptProbe,
        run_id: run.id,
        step_name: Atom.to_string(mode),
        step_index: 0,
        __map_index__: 0,
        __map_strategy__: "retry"
      }

      assert {:ok, result} =
               Jido.Exec.run(
                 StepRunner,
                 params,
                 %{counter: counter, mode: mode},
                 ExecutionPolicy.outer_options()
               )

      if mode == :transient do
        assert result.attempt == 3
        assert Agent.get(counter, & &1) == 3
      else
        assert result["__map_error__"]
        assert Agent.get(counter, & &1) == 1
      end
    end

    assert length(Workflows.list_step_runs(run.id)) == 2
  end

  test "persists structured non-retryable failures after one workflow-boundary attempt" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

    {:ok, run} = Workflows.create_run(workflow([], []), @event)

    params = %{
      wrapped_module: AttemptProbe,
      run_id: run.id,
      step_name: "structured_failure",
      step_index: 0
    }

    assert {:error, error} =
             Jido.Exec.run(
               StepRunner,
               params,
               %{counter: counter, mode: :deterministic},
               ExecutionPolicy.outer_options()
             )

    assert Error.to_map(error).type == :execution_error
    assert Error.to_map(error).message == "rejected"
    assert Agent.get(counter, & &1) == 1

    step = Workflows.get_terminal_step_run(run.id, "structured_failure")
    assert step.status == "failed"
    assert step.results == nil
    assert step.errors["type"] == "execution_error"
    assert step.errors["message"] == "rejected"
    assert step.errors["details"]["retry"] == false
    assert step.errors["retryable?"] == false
  end

  test "times out an action process, persists failure, and performs no extra attempt" do
    counter = start_supervised!({Agent, fn -> 0 end})
    {:ok, run} = Workflows.create_run(workflow([], []), @event)

    params = %{
      wrapped_module: AttemptProbe,
      run_id: run.id,
      step_name: "timed_failure",
      step_index: 0,
      timeout_ms: 30
    }

    assert {:error, error} =
             Jido.Exec.run(
               StepRunner,
               params,
               %{counter: counter, mode: :timeout, owner: self()},
               ExecutionPolicy.outer_options()
             )

    assert Error.to_map(error).type == :timeout
    assert_receive {:attempt_started, pid, 1}
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}
    refute Process.alive?(pid)
    assert Agent.get(counter, & &1) == 1

    step = Workflows.get_terminal_step_run(run.id, "timed_failure")
    assert step.status == "failed"
    assert step.results == nil
    assert step.errors["type"] == "timeout"
    assert step.errors["reason"] =~ "timed out after 30ms"
  end
end
