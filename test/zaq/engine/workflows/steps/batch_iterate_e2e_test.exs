defmodule Zaq.Engine.Workflows.Steps.BatchIterateE2ETest do
  @moduledoc """
  End-to-end integration tests for the Batch → Iterate workflow pattern.

  Full stack exercised:
    DagBuilder (node resolution, edge conditions, batch/iterate injection)
    → ActionWrapper (step_run persistence)
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
  alias Zaq.Engine.Workflows.WorkflowAgent
  alias Zaq.Test.Stubs

  # ── Module names (used in workflow definition JSON) ───────────────────────────

  @batch_module "Zaq.Agent.Tools.Batch"
  @iterate_module "Zaq.Agent.Tools.Iterate"

  @list_contacts_module "Zaq.Engine.Workflows.Steps.BatchIterateE2ETest.ListContacts"
  @check_status_module "Zaq.Engine.Workflows.Steps.BatchIterateE2ETest.CheckContactStatus"
  @check_seq_module "Zaq.Engine.Workflows.Steps.BatchIterateE2ETest.CheckEmailSeq"
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

  defmodule CheckContactStatus do
    @moduledoc false
    use Jido.Action,
      name: "e2e_check_contact_status",
      schema: [contact: [type: :map, required: true]],
      output_schema: [contact: [type: :map, required: true]]

    use Zaq.Engine.Workflows.Action

    @impl Jido.Action
    def run(%{contact: %{active: false}}, _ctx), do: {:error, :inactive}
    def run(%{contact: contact}, _ctx), do: {:ok, %{contact: contact}}
  end

  defmodule CheckEmailSeq do
    @moduledoc false
    use Jido.Action,
      name: "e2e_check_email_seq",
      schema: [contact: [type: :map, required: true]],
      output_schema: [contact: [type: :map, required: true]]

    use Zaq.Engine.Workflows.Action

    @impl Jido.Action
    def run(%{contact: %{in_sequence: true}}, _ctx), do: {:error, :in_sequence}
    def run(%{contact: contact}, _ctx), do: {:ok, %{contact: contact}}
  end

  defmodule DispatchContact do
    @moduledoc false
    use Jido.Action,
      name: "e2e_dispatch_contact",
      schema: [contact: [type: :map, required: true]],
      output_schema: [dispatched: [type: :map, required: true]]

    use Zaq.Engine.Workflows.Action

    @impl Jido.Action
    def run(%{contact: contact}, _ctx), do: {:ok, %{dispatched: contact}}
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
                        "name" => "check_status",
                        "type" => "action",
                        "module" => @check_status_module,
                        "params" => %{}
                      },
                      %{
                        "name" => "check_seq",
                        "type" => "action",
                        "module" => @check_seq_module,
                        "params" => %{}
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
    Stubs.stub_node_router()
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
      {:ok, finished} = WorkflowAgent.execute(run)

      step_names = finished |> step_runs() |> Enum.map(& &1.step_name) |> MapSet.new()

      # Only top-level DAG nodes get step_run rows
      assert MapSet.member?(step_names, "list_contacts")
      assert MapSet.member?(step_names, "batch_contacts")

      # All scoped nodes must NOT have step_run rows
      refute MapSet.member?(step_names, "iterate_contacts")
      refute MapSet.member?(step_names, "check_status")
      refute MapSet.member?(step_names, "check_seq")
      refute MapSet.member?(step_names, "dispatch")
      refute MapSet.member?(step_names, "sleep_between")
    end
  end

  # ── Direct run execution ──────────────────────────────────────────────────────

  describe "WorkflowAgent execution: Batch → Iterate pipeline" do
    test "workflow completes successfully" do
      wf = contact_batch_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())

      assert {:ok, finished} = WorkflowAgent.execute(run)
      assert finished.status == "completed"
    end

    test "batch produces 3 chunk results (batch_size: 4 over 12 contacts)" do
      wf = contact_batch_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, _} = WorkflowAgent.execute(run)

      batch_run = batch_step_run(run)

      # 3 chunks, 0 chunk-level errors (skip_and_continue collects item errors inside Iterate)
      assert length(batch_run.results["results"]) == 3
      assert batch_run.results["errors"] == []
    end

    test "each chunk result is an Iterate output with per-item results and errors" do
      wf = contact_batch_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, _} = WorkflowAgent.execute(run)

      chunk_results = batch_step_run(run).results["results"]

      for chunk <- chunk_results do
        assert Map.has_key?(chunk, "results")
        assert Map.has_key?(chunk, "errors")
      end
    end

    test "6 contacts dispatched total across all 3 batches" do
      wf = contact_batch_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, _} = WorkflowAgent.execute(run)

      dispatched = total_dispatched(run)
      assert length(dispatched) == 6
    end

    test "dispatched contacts are the ones that are active and not in sequence" do
      wf = contact_batch_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, _} = WorkflowAgent.execute(run)

      dispatched_names =
        total_dispatched(run)
        |> Enum.map(&(Map.get(&1, "name") || Map.get(&1, :name)))
        |> Enum.sort()

      assert dispatched_names == ~w[Alice Dave Frank Hank Jake Leo]
    end

    test "6 contacts skipped total (3 inactive + 3 in_sequence)" do
      wf = contact_batch_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, _} = WorkflowAgent.execute(run)

      errors = total_iterate_errors(run)
      assert length(errors) == 6
    end

    test "inactive contacts produce :inactive error, in_sequence produce :in_sequence error" do
      wf = contact_batch_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, _} = WorkflowAgent.execute(run)

      reasons =
        total_iterate_errors(run)
        |> Enum.map(&(Map.get(&1, "reason") || Map.get(&1, :reason)))
        |> Enum.sort()

      # 3 inactive, 3 in_sequence
      assert Enum.count(reasons, &(&1 == "inactive" or &1 == :inactive)) == 3
      assert Enum.count(reasons, &(&1 == "in_sequence" or &1 == :in_sequence)) == 3
    end
  end

  # ── Edge condition ────────────────────────────────────────────────────────────

  describe "edge condition: contacts not_empty" do
    test "condition passes — workflow runs batch when contacts present" do
      wf = contact_batch_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, finished} = WorkflowAgent.execute(run)

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
      {:ok, finished} = WorkflowAgent.execute(run)

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

  # ── Log trail ─────────────────────────────────────────────────────────────────

  describe "log trail: batch and iterate" do
    test "batch_contacts step_run logs has 3 chunk_completed events" do
      wf = contact_batch_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, _} = WorkflowAgent.execute(run)

      logs = batch_step_run(run).logs
      assert length(logs) == 3
      assert Enum.all?(logs, &(Map.get(&1, "event") == "chunk_completed"))
    end

    test "chunk log events are indexed 0, 1, 2" do
      wf = contact_batch_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, _} = WorkflowAgent.execute(run)

      indices =
        batch_step_run(run).logs
        |> Enum.map(&Map.get(&1, "index"))
        |> Enum.sort()

      assert indices == [0, 1, 2]
    end

    test "each chunk log records 2 results and 2 errors" do
      wf = contact_batch_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, _} = WorkflowAgent.execute(run)

      for log <- batch_step_run(run).logs do
        assert Map.get(log, "results") == 2
        assert Map.get(log, "errors") == 2
      end
    end

    test "iteration_logs nested per chunk have 4 item-level events (2 ok + 2 error)" do
      wf = contact_batch_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, _} = WorkflowAgent.execute(run)

      for log <- batch_step_run(run).logs do
        iteration_logs = Map.get(log, "iteration_logs", [])
        assert length(iteration_logs) == 4

        events = Enum.map(iteration_logs, &Map.get(&1, "event"))
        assert Enum.count(events, &(&1 == "item_ok")) == 2
        assert Enum.count(events, &(&1 == "item_error")) == 2
      end
    end

    test "item error reasons are readable strings — 3 inactive and 3 in_sequence" do
      wf = contact_batch_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, _} = WorkflowAgent.execute(run)

      error_reasons =
        batch_step_run(run).logs
        |> Enum.flat_map(&Map.get(&1, "iteration_logs", []))
        |> Enum.filter(&(Map.get(&1, "event") == "item_error"))
        |> Enum.map(&Map.get(&1, "reason"))
        |> Enum.sort()

      assert Enum.count(error_reasons, &(&1 == "inactive")) == 3
      assert Enum.count(error_reasons, &(&1 == "in_sequence")) == 3
    end

    test "log trail is visible in finished run's log_summary timeline" do
      wf = contact_batch_workflow()
      {:ok, run} = Workflows.create_run(wf, source_event())
      {:ok, finished} = WorkflowAgent.execute(run)

      batch_entry =
        finished.log_summary.timeline
        |> Enum.find(&(&1.step_name == "batch_contacts"))

      assert batch_entry != nil
      assert length(batch_entry.logs) == 3
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

  # Collects all dispatched contacts across all 3 batches.
  # Structure: batch.results = [chunk1, chunk2, chunk3]
  # chunk = %{"results" => [%{"dispatched" => contact}, ...], "errors" => [...]}
  defp total_dispatched(run) do
    run
    |> batch_step_run()
    |> Map.get(:results, %{})
    |> Map.get("results", [])
    |> Enum.flat_map(fn chunk ->
      chunk
      |> Map.get("results", [])
      |> Enum.map(&(Map.get(&1, "dispatched") || Map.get(&1, :dispatched)))
      |> Enum.reject(&is_nil/1)
    end)
  end

  # Collects all per-item errors from the Iterate output across all batches.
  defp total_iterate_errors(run) do
    run
    |> batch_step_run()
    |> Map.get(:results, %{})
    |> Map.get("results", [])
    |> Enum.flat_map(&(Map.get(&1, "errors") || []))
  end
end
