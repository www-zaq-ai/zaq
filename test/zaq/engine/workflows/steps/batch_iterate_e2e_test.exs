defmodule Zaq.Engine.Workflows.Steps.BatchIterateE2ETest do
  @moduledoc """
  End-to-end integration tests for the Batch → Iterate workflow pattern.

  Full stack exercised:
    DagBuilder (node resolution, edge conditions, batch/iterate injection)
    → StepRunner (step_run persistence)
    → Batch (chunk orchestration)
    → Iterate (per-item pipeline)
    → Contact pipeline actions (status filter, sequence filter, dispatcher)

  Trigger path:
    Workflows.create_trigger/1 + assign_workflow_to_trigger/2
    → TriggerNode.fire/2 (creates run + executes synchronously)
    → DB assertions on step_runs

  Dataset: 12 contacts, batch_size: 4 → 3 batches.
  Expected outcomes per batch (strategy: :skip_and_continue):
    - Contacts where active: false → :inactive error
    - Contacts where in_sequence: true → :in_sequence error
    - Remaining contacts → dispatched (results)

  Global counts: 6 dispatched, 3 inactive, 3 in_sequence.
  """

  use Zaq.DataCase, async: false

  alias Zaq.Engine.TriggerNode
  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.WorkflowRunAgent

  # ── Module names (used in workflow definition JSON) ───────────────────────────

  @batch_module "Zaq.Agent.Tools.Workflow.Batch"
  @iterate_module "Zaq.Agent.Tools.Workflow.Iterate"
  @condition_module "Zaq.Agent.Tools.Workflow.Condition"

  @list_contacts_module "Zaq.Engine.Workflows.Steps.BatchIterateE2ETest.ListContacts"
  @dispatch_module "Zaq.Engine.Workflows.Steps.BatchIterateE2ETest.DispatchContact"
  @sleep_module "Zaq.Engine.Workflows.Test.SleepMs"

  # ── Inline action modules ─────────────────────────────────────────────────────

  defmodule ListContacts do
    @moduledoc false
    use Jido.Action,
      name: "e2e_list_contacts",
      schema: [source: [type: :string, required: false, doc: "Optional data source label."]],
      output_schema: [contacts: [type: :list, required: true]]

    use Zaq.Engine.Workflows.Action

    # 12 contacts: mix of active/inactive and in_sequence/not
    # Active + not_in_sequence (6) → will be dispatched
    # active: false (3)            → filtered by CheckContactStatus
    # in_sequence: true (3)        → filtered by CheckEmailSeq
    @contacts [
      %{name: "Alice", active: true, in_sequence: false},
      %{name: "Bob", active: false, in_sequence: false},
      %{name: "Carol", active: true, in_sequence: true},
      %{name: "Dave", active: true, in_sequence: false},
      %{name: "Eve", active: false, in_sequence: false},
      %{name: "Frank", active: true, in_sequence: false},
      %{name: "Grace", active: true, in_sequence: true},
      %{name: "Hank", active: true, in_sequence: false},
      %{name: "Iris", active: false, in_sequence: true},
      %{name: "Jake", active: true, in_sequence: false},
      %{name: "Kate", active: true, in_sequence: true},
      %{name: "Leo", active: true, in_sequence: false}
    ]

    @impl Jido.Action
    def run(_params, _ctx), do: {:ok, %{contacts: @contacts}}
  end

  defmodule DispatchContact do
    @moduledoc false
    use Jido.Action,
      name: "e2e_dispatch_contact",
      schema: [input: [type: :map, required: true]],
      output_schema: [dispatched: [type: :map, required: true]]

    use Zaq.Engine.Workflows.Action

    @impl Jido.Action
    def run(%{input: contact}, _ctx), do: {:ok, %{dispatched: contact}}
  end

  # ── Workflow factory ──────────────────────────────────────────────────────────

  # DAG: list_contacts --(contacts not empty)--> batch_contacts
  #        batch_contacts.params.process:      [iterate_contacts (inline)]
  #        batch_contacts.params.post_process: [sleep_between   (inline)]
  #          iterate_contacts.params.pipeline: [check_status, check_seq, dispatch (inline)]
  # batch_size: 4 over 12 contacts -> 3 chunks.
  # strategy: :skip_and_continue (inactive + in_sequence collected as errors).
  #
  # The workflow has exactly 2 top-level DAG nodes. All orchestrator internals
  # live as inline maps inside params — no scoped nodes in the top-level list.
  defp contact_batch_workflow do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "Contact Batch E2E #{System.unique_integer()}",
        status: "active",
        nodes: [
          %{
            name: "list_contacts",
            type: "action",
            module: @list_contacts_module,
            params: %{},
            index: 0
          },
          %{
            name: "batch_contacts",
            type: "action",
            module: @batch_module,
            params: %{
              "batch_size" => 4,
              "strategy" => "skip_and_continue",
              "process" => [
                %{
                  "name" => "iterate_contacts",
                  "type" => "action",
                  "module" => @iterate_module,
                  "params" => %{
                    "strategy" => "skip_and_continue",
                    "pipeline" => [
                      %{
                        "name" => "condition_active",
                        "type" => "action",
                        "module" => @condition_module,
                        "params" => %{
                          "conditions" => [%{"key" => "active", "value" => true}]
                        }
                      },
                      %{
                        "name" => "condition_not_in_seq",
                        "type" => "action",
                        "module" => @condition_module,
                        "params" => %{
                          "conditions" => [%{"key" => "in_sequence", "value" => false}]
                        }
                      },
                      %{
                        "name" => "dispatch",
                        "type" => "action",
                        "module" => @dispatch_module,
                        "params" => %{}
                      }
                    ]
                  }
                }
              ],
              "post_process" => [
                %{
                  "name" => "sleep_between",
                  "type" => "action",
                  "module" => @sleep_module,
                  "params" => %{"duration_ms" => 0}
                }
              ]
            },
            index: 1
          }
        ],
        edges: [
          %{
            from: "list_contacts",
            to: "batch_contacts",
            # DAG-level edge condition: only proceed if contacts list is non-empty
            condition: %{"field" => "contacts", "op" => "not_empty"},
            # Rename: list_contacts.contacts → batch_contacts.items
            mapping: %{"items" => "contacts"}
          }
        ]
      })

    wf
  end

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  # ── DagBuilder validation ─────────────────────────────────────────────────────

  describe "DagBuilder: workflow builds cleanly" do
    test "workflow creation succeeds — DagBuilder resolves all scoped nodes" do
      wf = contact_batch_workflow()
      assert wf.status == "active"
    end

    test "scoped nodes (iterate, check_status, check_seq, dispatch, sleep) excluded from DAG" do
      wf = contact_batch_workflow()

      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, finished} = WorkflowRunAgent.execute(run)

      step_names = finished |> step_runs() |> Enum.map(& &1.step_name) |> MapSet.new()

      # Only top-level DAG nodes get step_run rows
      assert MapSet.member?(step_names, "list_contacts")
      assert MapSet.member?(step_names, "batch_contacts")

      # All scoped nodes must NOT have step_run rows
      refute MapSet.member?(step_names, "iterate_contacts")
      refute MapSet.member?(step_names, "condition_active")
      refute MapSet.member?(step_names, "condition_not_in_seq")
      refute MapSet.member?(step_names, "dispatch")
      refute MapSet.member?(step_names, "sleep_between")
    end
  end

  # ── Direct run execution ──────────────────────────────────────────────────────

  describe "WorkflowRunAgent execution: Batch → Iterate pipeline" do
    test "workflow completes successfully" do
      wf = contact_batch_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())

      assert {:ok, finished} = WorkflowRunAgent.execute(run)
      assert finished.status == "completed"
    end

    test "aggregate map row summarizes 12 items: 6 successful + 6 errors" do
      wf = contact_batch_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, _} = WorkflowRunAgent.execute(run)

      batch_run = batch_step_run(run)

      # per-item fan-out: 6 contacts complete the pipeline, 6 isolated failures
      assert length(batch_run.results["results"]) == 6
      assert length(batch_run.results["errors"]) == 6
      assert batch_run.results["count"] == 12
    end

    test "each error entry carries the item index and failed-condition reason" do
      wf = contact_batch_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, _} = WorkflowRunAgent.execute(run)

      for err <- batch_step_run(run).results["errors"] do
        assert is_integer(err["index"])
        assert err["reason"] =~ "condition_failed"
      end
    end

    test "6 contacts dispatched total across all 3 batches" do
      wf = contact_batch_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, _} = WorkflowRunAgent.execute(run)

      dispatched = total_dispatched(run)
      assert length(dispatched) == 6
    end

    test "dispatched contacts are the ones that are active and not in sequence" do
      wf = contact_batch_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, _} = WorkflowRunAgent.execute(run)

      dispatched_names =
        total_dispatched(run)
        |> Enum.map(&(Map.get(&1, "name") || Map.get(&1, :name)))
        |> Enum.sort()

      assert dispatched_names == ~w[Alice Dave Frank Hank Jake Leo]
    end

    test "6 contacts skipped total (3 inactive + 3 in_sequence)" do
      wf = contact_batch_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, _} = WorkflowRunAgent.execute(run)

      errors = total_iterate_errors(run)
      assert length(errors) == 6
    end

    test "3 contacts fail the active condition, 3 fail the in_sequence condition" do
      wf = contact_batch_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, _} = WorkflowRunAgent.execute(run)

      reasons =
        total_iterate_errors(run)
        |> Enum.map(&to_string(Map.get(&1, "reason") || Map.get(&1, :reason)))

      assert Enum.count(reasons, &String.contains?(&1, "active")) == 3
      assert Enum.count(reasons, &String.contains?(&1, "in_sequence")) == 3
    end
  end

  # ── Edge condition ────────────────────────────────────────────────────────────

  describe "edge condition: contacts not_empty" do
    test "condition passes — workflow runs batch when contacts present" do
      wf = contact_batch_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, finished} = WorkflowRunAgent.execute(run)

      assert finished.status == "completed"
      assert batch_step_run(run) != nil
    end

    test "condition blocks — batch does not run when contacts list is empty" do
      # Patch: override list_contacts to return no contacts by using a workflow
      # variant that substitutes an inline empty-list action.
      # We verify via a workflow that has no downstream step_run for batch.
      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "Empty Contact Batch #{System.unique_integer()}",
          status: "active",
          nodes: [
            %{
              name: "list_contacts",
              type: "action",
              module: @list_contacts_module,
              params: %{},
              index: 0
            },
            %{
              name: "batch_contacts",
              type: "action",
              module: @batch_module,
              params: %{
                "batch_size" => 4,
                "strategy" => "skip_and_continue",
                "process" => [
                  %{
                    "name" => "iterate_contacts",
                    "type" => "action",
                    "module" => @iterate_module,
                    "params" => %{
                      "pipeline" => [
                        %{
                          "name" => "dispatch",
                          "type" => "action",
                          "module" => @dispatch_module,
                          "params" => %{}
                        }
                      ]
                    }
                  }
                ]
              },
              index: 1
            }
          ],
          edges: [
            %{
              from: "list_contacts",
              to: "batch_contacts",
              # This condition will be FALSE because contacts list has items —
              # so we test the opposite: use "empty" op to skip batch
              condition: %{"field" => "contacts", "op" => "empty"},
              mapping: %{"items" => "contacts"}
            }
          ]
        })

      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, finished} = WorkflowRunAgent.execute(run)

      assert finished.status == "completed"

      step_names = finished |> step_runs() |> Enum.map(& &1.step_name)

      # list_contacts ran, but batch was pruned by the false edge condition
      assert "list_contacts" in step_names
      refute "batch_contacts" in step_names
    end
  end

  # ── Trigger path ──────────────────────────────────────────────────────────────

  describe "trigger path: TriggerNode.fire/2 → workflow run" do
    test "firing trigger creates and completes a workflow run" do
      wf = contact_batch_workflow()

      {:ok, trigger} =
        Workflows.create_trigger(%{
          event_name: "e2e.contact.batch.#{System.unique_integer()}",
          enabled: true
        })

      {:ok, _} = Workflows.assign_workflow_to_trigger(trigger, wf)

      # TriggerNode.fire/2 is synchronous: Task.async_stream |> Stream.run()
      # blocks until all workflow runs complete.
      TriggerNode.fire(trigger.event_name, trigger_event())

      # Query the run created by the trigger
      [run] = Workflows.list_runs(wf.id)
      assert run.status == "completed"
    end

    test "trigger-fired run produces correct batch results (same as direct execution)" do
      wf = contact_batch_workflow()

      {:ok, trigger} =
        Workflows.create_trigger(%{
          event_name: "e2e.contact.batch.#{System.unique_integer()}",
          enabled: true
        })

      {:ok, _} = Workflows.assign_workflow_to_trigger(trigger, wf)

      TriggerNode.fire(trigger.event_name, trigger_event())

      [run] = Workflows.list_runs(wf.id)

      dispatched_names =
        total_dispatched(run)
        |> Enum.map(&(Map.get(&1, "name") || Map.get(&1, :name)))
        |> Enum.sort()

      assert dispatched_names == ~w[Alice Dave Frank Hank Jake Leo]
    end

    test "disabled trigger does not fire workflow" do
      wf = contact_batch_workflow()

      {:ok, trigger} =
        Workflows.create_trigger(%{
          event_name: "e2e.contact.batch.#{System.unique_integer()}",
          enabled: false
        })

      {:ok, _} = Workflows.assign_workflow_to_trigger(trigger, wf)

      TriggerNode.fire(trigger.event_name, trigger_event())

      assert Workflows.list_runs(wf.id) == []
    end
  end

  # ── Per-fork visibility (replaces the old opaque chunk/item log trail) ─────────

  describe "per-fork visibility: one StepRun per item" do
    # All fork rows for a given body step, e.g. "batch_contacts/dispatch[3]".
    defp fork_rows(run, step) do
      run
      |> step_runs()
      |> Enum.filter(&String.starts_with?(&1.step_name, "batch_contacts/#{step}["))
    end

    test "every contact is its own dispatch fork row (12 contacts)" do
      wf = contact_batch_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, _} = WorkflowRunAgent.execute(run)

      # 6 contacts reach dispatch and complete; the other 6 short-circuit at a
      # failed condition, so their dispatch fork never runs.
      dispatched = fork_rows(run, "dispatch")
      assert length(dispatched) == 6
      assert Enum.all?(dispatched, &(&1.status == "completed"))
    end

    test "isolated failures are recorded as failed_fatal condition fork rows" do
      wf = contact_batch_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, _} = WorkflowRunAgent.execute(run)

      failed =
        run
        |> step_runs()
        |> Enum.filter(
          &(String.starts_with?(&1.step_name, "batch_contacts/condition_") and
              &1.status == "failed_fatal")
        )

      # 3 fail the active check + 3 fail the in_sequence check
      assert length(failed) == 6
    end

    test "per-fork failures do not fail the run (skip_and_continue)" do
      wf = contact_batch_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, finished} = WorkflowRunAgent.execute(run)

      assert finished.status == "completed"
    end

    test "post_process tail runs once per successful fork" do
      wf = contact_batch_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, _} = WorkflowRunAgent.execute(run)

      sleeps = fork_rows(run, "sleep_between")
      assert length(sleeps) == 6
      assert Enum.all?(sleeps, &(&1.status == "completed"))
    end

    test "aggregate batch_contacts row is present with its first log a step_completed" do
      wf = contact_batch_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, finished} = WorkflowRunAgent.execute(run)

      [first | _] = batch_step_run(run).logs
      assert Map.get(first, "event") == "step_completed"

      assert finished.log_summary.timeline
             |> Enum.any?(&(&1.step_name == "batch_contacts"))
    end
  end

  # ── Single combined-condition workflow ───────────────────────────────────────

  # Both conditions (active: true AND in_sequence: false) merged into one Condition
  # node. Contacts that violate multiple conditions produce a single error whose
  # reason lists all failing keys (e.g. "condition_failed:active,in_sequence").
  defp combined_condition_workflow do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "Combined Condition E2E #{System.unique_integer()}",
        status: "active",
        nodes: [
          %{
            name: "list_contacts",
            type: "action",
            module: @list_contacts_module,
            params: %{},
            index: 0
          },
          %{
            name: "batch_contacts",
            type: "action",
            module: @batch_module,
            params: %{
              "batch_size" => 4,
              "strategy" => "skip_and_continue",
              "process" => [
                %{
                  "name" => "iterate_contacts",
                  "type" => "action",
                  "module" => @iterate_module,
                  "params" => %{
                    "strategy" => "skip_and_continue",
                    "pipeline" => [
                      %{
                        "name" => "condition_eligibility",
                        "type" => "action",
                        "module" => @condition_module,
                        "params" => %{
                          "conditions" => [
                            %{"key" => "active", "value" => true},
                            %{"key" => "in_sequence", "value" => false}
                          ]
                        }
                      },
                      %{
                        "name" => "dispatch",
                        "type" => "action",
                        "module" => @dispatch_module,
                        "params" => %{}
                      }
                    ]
                  }
                }
              ]
            },
            index: 1
          }
        ],
        edges: [
          %{
            from: "list_contacts",
            to: "batch_contacts",
            condition: %{"field" => "contacts", "op" => "not_empty"},
            mapping: %{"items" => "contacts"}
          }
        ]
      })

    wf
  end

  describe "single combined-condition step" do
    test "same 6 contacts dispatched as in the two-step variant" do
      wf = combined_condition_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, _} = WorkflowRunAgent.execute(run)

      dispatched_names =
        total_dispatched(run)
        |> Enum.map(&(Map.get(&1, "name") || Map.get(&1, :name)))
        |> Enum.sort()

      assert dispatched_names == ~w[Alice Dave Frank Hank Jake Leo]
    end

    test "6 contacts skipped in total" do
      wf = combined_condition_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, _} = WorkflowRunAgent.execute(run)

      assert length(total_iterate_errors(run)) == 6
    end

    test "contacts failing multiple conditions produce a single error listing all failed keys" do
      # Iris is active: false AND in_sequence: true — both fail in one step.
      wf = combined_condition_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, _} = WorkflowRunAgent.execute(run)

      reasons =
        total_iterate_errors(run)
        |> Enum.map(&to_string(Map.get(&1, "reason") || Map.get(&1, :reason)))

      # Iris fails both → reason contains both keys
      multi_fail =
        Enum.filter(
          reasons,
          &(String.contains?(&1, "active") and String.contains?(&1, "in_sequence"))
        )

      assert length(multi_fail) == 1

      # Bob and Eve are inactive but not in_sequence → fail only active
      active_only =
        Enum.filter(
          reasons,
          &(String.contains?(&1, "active") and not String.contains?(&1, "in_sequence"))
        )

      assert length(active_only) == 2

      # Carol, Grace, Kate are active but in_sequence → fail only in_sequence
      seq_only =
        Enum.filter(
          reasons,
          &(String.contains?(&1, "in_sequence") and not String.contains?(&1, "active"))
        )

      assert length(seq_only) == 3
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp source_event do
    %{
      "request" => nil,
      "assigns" => %{"trigger_type" => "manual"},
      "trace_id" => Ecto.UUID.generate()
    }
  end

  defp trigger_event do
    Zaq.Event.new(
      %{"trigger_type" => "event"},
      :engine,
      name: :e2e_contact_batch,
      trace_id: Ecto.UUID.generate()
    )
  end

  defp step_runs(run) do
    Workflows.list_step_runs(run.id)
  end

  defp batch_step_run(run) do
    run |> step_runs() |> Enum.find(&(&1.step_name == "batch_contacts"))
  end

  # Per-fork visibility model: each contact is its own `batch_contacts/dispatch[i]`
  # StepRun. Dispatched contacts are read from those rows (the dispatch step's
  # `dispatched` output), not from the aggregate — the aggregate's per-fork result is
  # the post_process (`sleep_between`) tail.
  defp total_dispatched(run) do
    run
    |> step_runs()
    |> Enum.filter(
      &(String.starts_with?(&1.step_name, "batch_contacts/dispatch[") and
          &1.status == "completed")
    )
    |> Enum.map(&(&1.results && &1.results["dispatched"]))
    |> Enum.reject(&is_nil/1)
  end

  # Per-item errors come from the aggregate map row's flat `errors` list
  # (`%{index, item, reason}` per isolated `failed_fatal` fork).
  defp total_iterate_errors(run) do
    run
    |> batch_step_run()
    |> Map.get(:results, %{})
    |> Map.get("errors", [])
  end
end
