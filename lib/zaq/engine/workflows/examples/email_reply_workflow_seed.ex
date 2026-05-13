defmodule Zaq.Engine.Workflows.Examples.EmailReplyWorkflowSeed do
  @moduledoc """
  Seeds the email reply workflow into the database and fires a manual run.

  > **Temporary** — remove this module once the workflow is validated end-to-end.

  ## Usage

      # Seed workflow + trigger records (idempotent by name)
      {:ok, workflow, trigger} = Zaq.Engine.Workflows.Examples.EmailReplyWorkflowSeed.seed()

      # Fire a manual run
      {:ok, run} = Zaq.Engine.Workflows.Examples.EmailReplyWorkflowSeed.fire(workflow, trigger)

      # Seed and fire in one call
      {:ok, run} = Zaq.Engine.Workflows.Examples.EmailReplyWorkflowSeed.seed_and_fire()

  ## What happens

  1. A `Workflow` row is inserted with `status: "active"` and the full
     nodes/edges DAG as the `steps` JSONB column.
  2. A `Trigger` row of type `"manual"` is attached to the workflow.
  3. `fire/2` delegates to `Triggers.Manual.fire/3`, which builds a
     `%Zaq.Event{}`, snapshots the steps into a `WorkflowRun` row, and
     returns the run with `status: "pending"`.
  4. From there, pass `run.steps_snapshot` to `DagBuilder.build/1` to get
     a `%Runic.Workflow{}` ready for `Jido.Runic.Strategy`.
  """

  import Ecto.Query

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.EmailBridge.ImapConfigHelpers
  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.{DagBuilder, StepRun, Trigger, Workflow, WorkflowRun}
  alias Zaq.Engine.Workflows.Triggers.Manual
  alias Zaq.Repo

  @workflow_name "Email Reply"

  @notify_address "jad.tarabay2@gmail.com"

  @steps %{
    "nodes" => [
      %{
        "name" => "fetch",
        "type" => "action",
        "module" => "Zaq.Agent.Tools.Email.FetchEmails",
        "params" => %{},
        "index" => 0
      },
      %{
        "name" => "emails_found",
        "type" => "condition",
        "params" => %{"field" => "count", "op" => "gt", "value" => 0},
        "index" => 1
      },
      %{
        "name" => "no_emails",
        "type" => "condition",
        "params" => %{"field" => "count", "op" => "eq", "value" => 0},
        "index" => 1
      },
      %{
        "name" => "draft",
        "type" => "action",
        "module" => "Zaq.Agent.Tools.Email.DraftReply",
        "params" => %{},
        "index" => 2
      },
      %{
        "name" => "notify",
        "type" => "action",
        "module" => "Zaq.Agent.Tools.Email.NotifyEmptyMailbox",
        "params" => %{"notify_address" => @notify_address},
        "index" => 2
      },
      %{
        "name" => "ensure_person",
        "type" => "action",
        "module" => "Zaq.Agent.Tools.People.EnsurePerson",
        "params" => %{},
        "index" => 3
      },
      %{
        "name" => "send_reply",
        "type" => "action",
        "module" => "Zaq.Agent.Tools.Email.SendReply",
        "params" => %{},
        "index" => 4
      }
    ],
    "edges" => [
      %{"from" => "fetch", "to" => "emails_found"},
      %{"from" => "fetch", "to" => "no_emails"},
      %{"from" => "emails_found", "to" => "draft"},
      %{"from" => "no_emails", "to" => "notify"},
      %{"from" => "draft", "to" => "ensure_person"},
      %{"from" => "ensure_person", "to" => "send_reply"}
    ]
  }

  @doc """
  Inserts the workflow and a manual trigger. Idempotent — if a workflow with
  the same name already exists, returns the existing records.

  Returns `{:ok, workflow, trigger}`.
  """
  @spec seed() :: {:ok, Workflow.t(), Trigger.t()} | {:error, term()}
  def seed do
    case Repo.get_by(Workflow, name: @workflow_name) do
      %Workflow{} = existing ->
        # Always sync steps in case @steps changed since last seed
        with {:ok, workflow} <- Workflows.update_workflow(existing, %{steps: @steps}) do
          trigger =
            Repo.get_by(Trigger, workflow_id: workflow.id, type: "manual") ||
              elem(Workflows.create_trigger(trigger_attrs(workflow)), 1)

          {:ok, workflow, trigger}
        end

      nil ->
        with {:ok, workflow} <- Workflows.create_workflow(workflow_attrs()),
             {:ok, trigger} <- Workflows.create_trigger(trigger_attrs(workflow)) do
          {:ok, workflow, trigger}
        end
    end
  end

  @doc """
  Fires a manual run for the given workflow + trigger pair.

  Returns `{:ok, run}` where `run.status` is `"pending"` and
  `run.steps_snapshot` holds the snapshotted DAG.
  """
  @spec fire(Workflow.t(), Trigger.t()) :: {:ok, term()} | {:error, term()}
  def fire(%Workflow{} = workflow, %Trigger{} = trigger) do
    Manual.fire(trigger, workflow, %{mailbox: "INBOX"})
  end

  @doc """
  Seeds the workflow and immediately fires one manual run.

  Returns `{:ok, run}`.
  """
  @spec seed_and_fire() :: {:ok, term()} | {:error, term()}
  def seed_and_fire do
    with {:ok, workflow, trigger} <- seed() do
      fire(workflow, trigger)
    end
  end

  @doc """
  Verifies the stored steps can be assembled into a valid `Runic.Workflow`.
  Useful for a smoke-test after seeding.

      {:ok, %Runic.Workflow{}} = Zaq.Engine.Workflows.Examples.EmailReplyWorkflowSeed.validate_dag()
  """
  @spec validate_dag() :: {:ok, Runic.Workflow.t()} | {:error, term()}
  def validate_dag, do: DagBuilder.build(@steps)

  @doc """
  Seeds the workflow, creates a `WorkflowRun` record, and executes it via
  `Workflows.start_run/2`. The run drives the email DAG step-by-step, writing
  one `StepRun` row per action. After return, check `inspect_all/0` to see
  the full DB state.

      iex> Zaq.Engine.Workflows.Examples.EmailReplyWorkflowSeed.run()
      iex> Zaq.Engine.Workflows.Examples.EmailReplyWorkflowSeed.run("runictest")

  The `mailbox` argument is injected into the trigger event so `FetchEmails`
  receives it via the fact flow.
  """
  @spec run(String.t() | nil) :: {:ok, WorkflowRun.t()} | {:error, term()}
  def run(mailbox \\ nil) do
    channel_config = ChannelConfig.get_by_provider("email:imap")
    unless channel_config, do: raise("No enabled email:imap channel config found in the database")

    imap_config = ImapConfigHelpers.normalize_bridge_config(channel_config)

    resolved_mailbox =
      mailbox ||
        channel_config.settings
        |> Map.get("imap", %{})
        |> Map.get("selected_mailboxes", ["INBOX"])
        |> List.first("INBOX")

    with {:ok, workflow, trigger} <- seed(),
         {:ok, run} <-
           Manual.fire(trigger, workflow, %{imap_config: imap_config, mailbox: resolved_mailbox}) do
      Workflows.start_run(run)
    end
  end

  # --- Inspection helpers ---

  @doc """
  Returns the seeded `Workflow` row, or `nil` if not seeded yet.

      iex> Zaq.Engine.Workflows.Examples.EmailReplyWorkflowSeed.workflow()
      %Zaq.Engine.Workflows.Workflow{name: "Email Reply", status: "active", ...}
  """
  @spec workflow() :: Workflow.t() | nil
  def workflow, do: Repo.get_by(Workflow, name: @workflow_name)

  @doc """
  Returns all `Trigger` rows attached to the seeded workflow.

      iex> Zaq.Engine.Workflows.Examples.EmailReplyWorkflowSeed.triggers()
      [%Zaq.Engine.Workflows.Trigger{type: "manual", enabled: true, ...}]
  """
  @spec triggers() :: [Trigger.t()]
  def triggers do
    case workflow() do
      nil -> []
      wf -> Workflows.list_triggers(wf.id)
    end
  end

  @doc """
  Returns all `WorkflowRun` rows for the seeded workflow, newest first.

      iex> Zaq.Engine.Workflows.Examples.EmailReplyWorkflowSeed.runs()
      [%Zaq.Engine.Workflows.WorkflowRun{status: "pending", ...}]
  """
  @spec runs() :: [WorkflowRun.t()]
  def runs do
    case workflow() do
      nil -> []
      wf -> Workflows.list_runs(wf.id)
    end
  end

  @doc """
  Returns the latest `WorkflowRun` for the seeded workflow, or `nil`.

      iex> Zaq.Engine.Workflows.Examples.EmailReplyWorkflowSeed.latest_run()
      %Zaq.Engine.Workflows.WorkflowRun{status: "pending", source_event: %Zaq.Event{...}}
  """
  @spec latest_run() :: WorkflowRun.t() | nil
  def latest_run do
    case workflow() do
      nil ->
        nil

      wf ->
        Repo.one(
          from r in WorkflowRun,
            where: r.workflow_id == ^wf.id,
            order_by: [desc: r.inserted_at],
            limit: 1
        )
    end
  end

  @doc """
  Returns all `StepRun` rows for a given run, ordered by step_index.

      iex> {:ok, run} = Zaq.Engine.Workflows.Examples.EmailReplyWorkflowSeed.seed_and_fire()
      iex> Zaq.Engine.Workflows.Examples.EmailReplyWorkflowSeed.step_runs(run)
      []  # empty until a WorkflowAgent executes steps
  """
  @spec step_runs(WorkflowRun.t()) :: [StepRun.t()]
  def step_runs(%WorkflowRun{id: run_id}), do: Workflows.list_step_runs(run_id)

  @doc """
  Prints a human-readable summary of all seeded DB rows to stdout.
  Useful for a quick `iex` inspection.

      iex> Zaq.Engine.Workflows.Examples.EmailReplyWorkflowSeed.inspect_all()
  """
  @spec inspect_all() :: :ok
  def inspect_all do
    wf = workflow()

    IO.puts("\n=== Workflow ===")

    case wf do
      nil ->
        IO.puts("  (not seeded)")

      _ ->
        IO.puts("  id:     #{wf.id}")
        IO.puts("  name:   #{wf.name}")
        IO.puts("  status: #{wf.status}")
        IO.puts("  nodes:  #{length(wf.steps["nodes"] || [])}")
        IO.puts("  edges:  #{length(wf.steps["edges"] || [])}")
    end

    IO.puts("\n=== Triggers ===")

    Enum.each(triggers(), fn t ->
      IO.puts("  [#{t.id}] type=#{t.type} enabled=#{t.enabled}")
    end)

    IO.puts("\n=== Runs (newest first) ===")

    runs()
    |> Enum.each(&print_run/1)

    :ok
  end

  defp print_run(r) do
    IO.puts("  [#{r.id}] status=#{r.status} inserted_at=#{r.inserted_at}")
    IO.puts("    source_event.trace_id=#{r.source_event && r.source_event.trace_id}")
    IO.puts("    source_event.assigns=#{inspect(r.source_event && r.source_event.assigns)}")

    results = step_runs(r)

    if results == [] do
      IO.puts("    step_runs: (none)")
    else
      Enum.each(results, fn sr ->
        IO.puts("    step[#{sr.step_index}] #{sr.step_name} → #{sr.status}")
      end)
    end
  end

  # --- Private ---

  defp workflow_attrs do
    %{
      name: @workflow_name,
      description: "Fetches unread emails and sends AI-drafted replies",
      status: "active",
      steps: @steps
    }
  end

  defp trigger_attrs(%Workflow{id: workflow_id}) do
    %{workflow_id: workflow_id, type: "manual", enabled: true}
  end
end
