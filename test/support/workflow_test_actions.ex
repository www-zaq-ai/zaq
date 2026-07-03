defmodule Zaq.Engine.Workflows.Test.OkAction do
  @moduledoc false
  use Jido.Action,
    name: "test_ok_action",
    schema: [input: [type: :any]],
    output_schema: [value: [type: :any, required: true]]

  @behaviour Zaq.Engine.Workflows.Action

  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _context), do: {:ok, result}

  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _context), do: :ok

  @impl true
  def run(_params, _context), do: {:ok, %{value: "done"}}
end

defmodule Zaq.Engine.Workflows.Test.ErrorAction do
  @moduledoc false
  use Jido.Action,
    name: "test_error_action",
    schema: [input: [type: :any]],
    output_schema: [value: [type: :any, required: true]]

  @behaviour Zaq.Engine.Workflows.Action

  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _context), do: {:ok, result}

  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _context), do: :ok

  @impl true
  def run(_params, _context), do: {:error, :test_failure}
end

defmodule Zaq.Engine.Workflows.Test.NonConformingAction do
  @moduledoc false
  # A loadable Jido.Action that does NOT satisfy the workflow action contract:
  # empty schema, no output_schema, no on_success/2 or on_failure/2.
  use Jido.Action, name: "test_non_conforming_action", schema: []

  @impl true
  def run(_params, _context), do: {:ok, %{value: "done"}}
end

defmodule Zaq.Engine.Workflows.Test.ParamCapture do
  @moduledoc false
  use Agent

  def start_link(_), do: Agent.start_link(fn -> nil end, name: __MODULE__)

  def put_params(params), do: Agent.update(__MODULE__, fn _ -> params end)

  def get_params, do: Agent.get(__MODULE__, & &1)

  def reset, do: Agent.update(__MODULE__, fn _ -> nil end)
end

defmodule Zaq.Engine.Workflows.Test.OkWithLogsAction do
  @moduledoc false
  use Jido.Action,
    name: "test_ok_with_logs_action",
    schema: [input: [type: :any]],
    output_schema: [value: [type: :any, required: true]]

  @behaviour Zaq.Engine.Workflows.Action

  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _context), do: {:ok, result}

  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _context), do: :ok

  @impl true
  def run(_params, _context),
    do: {:ok, %{value: "with_logs"}, logs: [%{level: "info", message: "step log"}]}
end

defmodule Zaq.Engine.Workflows.Test.ParamProbe do
  @moduledoc false
  use Jido.Action,
    name: "test_param_probe",
    schema: [input: [type: :any]],
    output_schema: [params_captured: [type: :boolean, required: true]]

  @behaviour Zaq.Engine.Workflows.Action

  alias Zaq.Engine.Workflows.Test.ParamCapture

  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _context), do: {:ok, result}

  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _context), do: :ok

  @impl true
  def run(params, _context) do
    ParamCapture.put_params(params)
    {:ok, %{params_captured: true}}
  end
end

# ---------------------------------------------------------------------------
# Pause / Resume test support
# ---------------------------------------------------------------------------

defmodule Zaq.Engine.Workflows.Test.PauseSignal do
  @moduledoc false
  use Agent

  def start_link(_), do: Agent.start_link(fn -> nil end, name: __MODULE__)
  def put_run_id(run_id), do: Agent.update(__MODULE__, fn _ -> run_id end)
  def get_run_id, do: Agent.get(__MODULE__, & &1)
  def reset, do: Agent.update(__MODULE__, fn _ -> nil end)
end

defmodule Zaq.Engine.Workflows.Test.PauseAction do
  @moduledoc false
  use Jido.Action,
    name: "test_pause_action",
    schema: [input: [type: :any]],
    output_schema: [signaled: [type: :boolean, required: true]]

  @behaviour Zaq.Engine.Workflows.Action

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Test.PauseSignal

  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _context), do: {:ok, result}

  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _context), do: :ok

  @impl true
  def run(_params, _context) do
    run_id = PauseSignal.get_run_id()
    run = Workflows.get_run!(run_id)
    {:ok, _} = Workflows.update_run(run, %{status: "paused"})
    {:ok, %{signaled: true}}
  end
end

# ---------------------------------------------------------------------------
# Actions for Step 6 edge-routing E2E test
# ---------------------------------------------------------------------------

defmodule Zaq.Engine.Workflows.Test.Noop do
  @moduledoc false
  use Jido.Action,
    name: "test_noop",
    schema: [input: [type: :any]],
    output_schema: [noop: [type: :boolean, required: true]]

  @behaviour Zaq.Engine.Workflows.Action

  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _context), do: {:ok, result}

  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _context), do: :ok

  @impl true
  def run(_params, _context), do: {:ok, %{noop: true}}
end

defmodule Zaq.Engine.Workflows.Test.EmitPerson do
  @moduledoc false

  use Jido.Action,
    name: "test_emit_person",
    schema: [gender: [type: :string, required: true]],
    output_schema: [
      name: [type: :string, required: true],
      age: [type: :integer, required: true],
      gender: [type: :string, required: true]
    ]

  @behaviour Zaq.Engine.Workflows.Action

  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _context), do: {:ok, result}

  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _context), do: :ok

  @impl true
  def run(params, _context) do
    gender = Map.get(params, :gender) || Map.get(params, "gender")
    {:ok, %{name: "Sam", age: 30, gender: gender}}
  end
end

defmodule Zaq.Engine.Workflows.Test.RequirePersonName do
  @moduledoc false

  use Jido.Action,
    name: "test_require_person_name",
    schema: [person_name: [type: :any]],
    output_schema: [
      c_ran: [type: :boolean, required: true],
      person_name: [type: :string, required: true]
    ]

  @behaviour Zaq.Engine.Workflows.Action

  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _context), do: {:ok, result}

  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _context), do: :ok

  @impl true
  def run(params, _context) do
    # Asserts mapping correctness: person_name present, raw name must NOT be present.
    person_name = Map.fetch!(params, :person_name)

    if Map.has_key?(params, :name),
      do: raise("C received raw :name key — mapping isolation failed")

    {:ok, %{c_ran: true, person_name: person_name}}
  end
end

defmodule Zaq.Engine.Workflows.Test.EmitGender do
  @moduledoc false
  use Jido.Action,
    name: "test_emit_gender",
    schema: [gender: [type: :string, required: true]],
    output_schema: [gender: [type: :string, required: true]]

  @behaviour Zaq.Engine.Workflows.Action

  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _context), do: {:ok, result}

  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _context), do: :ok

  @impl true
  def run(params, _context) do
    gender = Map.get(params, :gender) || Map.get(params, "gender")
    {:ok, %{gender: gender}}
  end
end

# ---------------------------------------------------------------------------
# Human-in-the-loop test support
# ---------------------------------------------------------------------------

defmodule Zaq.Engine.Workflows.Test.ContextProbe do
  @moduledoc false
  use Agent

  def start_link(_), do: Agent.start_link(fn -> nil end, name: __MODULE__)
  def put_context(ctx), do: Agent.update(__MODULE__, fn _ -> ctx end)
  def get_context, do: Agent.get(__MODULE__, & &1)
  def reset, do: Agent.update(__MODULE__, fn _ -> nil end)
end

defmodule Zaq.Engine.Workflows.Test.ContextCaptureAction do
  @moduledoc false
  use Jido.Action,
    name: "test_context_capture_action",
    schema: [input: [type: :any]],
    output_schema: [captured: [type: :boolean, required: true]]

  @behaviour Zaq.Engine.Workflows.Action

  alias Zaq.Engine.Workflows.Test.ContextProbe

  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _context), do: {:ok, result}

  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _context), do: :ok

  @impl true
  def run(_params, context) do
    ContextProbe.put_context(context)
    {:ok, %{captured: true}}
  end
end

defmodule Zaq.Engine.Workflows.Test.WaitingAction do
  @moduledoc false
  use Jido.Action,
    name: "test_waiting_action",
    schema: [input: [type: :any]],
    output_schema: [approved: [type: :boolean, required: true]]

  @behaviour Zaq.Engine.Workflows.Action

  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _context), do: {:ok, result}

  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _context), do: :ok

  @impl true
  def run(_params, _context) do
    {:error, {:waiting_for_human, "test-token-#{System.unique_integer()}"}}
  end
end

defmodule Zaq.Engine.Workflows.Test.TimedAction do
  @moduledoc false
  use Jido.Action,
    name: "test_timed_action",
    schema: [
      emails: [type: :any, default: []],
      delay_ms: [type: :integer, default: 0]
    ]

  @impl true
  def run(%{delay_ms: delay_ms} = params, _context) do
    if delay_ms > 0, do: Process.sleep(delay_ms)

    emails = Map.get(params, :emails, [])

    drafts =
      Enum.map(emails, fn email ->
        from = email["from"] || %{}

        %{
          to_address: from["address"] || "unknown@example.com",
          subject: "Re: #{email["subject"] || "(no subject)"}",
          draft: "Thank you for your email."
        }
      end)

    {:ok, %{drafts: drafts}}
  end
end

# ---------------------------------------------------------------------------
# Email reply workflow test doubles
# ---------------------------------------------------------------------------

defmodule Zaq.Engine.Workflows.Test.InboxWithResults do
  @moduledoc false
  use Jido.Action,
    name: "test_inbox_with_results",
    schema: [mailbox: [type: :string, default: "INBOX"]],
    output_schema: [
      emails: [type: {:list, :map}, required: true],
      count: [type: :integer, required: true]
    ]

  @behaviour Zaq.Engine.Workflows.Action
  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _), do: {:ok, result}
  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _), do: :ok

  @impl true
  def run(_params, _context) do
    email = %{
      "message_id" => "test-001@example.com",
      "from" => %{"name" => "Alice", "address" => "alice@example.com"},
      "subject" => "Question about your service",
      "body_text" => "Hello, I have a question about your pricing."
    }

    {:ok, %{emails: [email], count: 1}}
  end
end

defmodule Zaq.Engine.Workflows.Test.InboxEmpty do
  @moduledoc false
  use Jido.Action,
    name: "test_inbox_empty",
    schema: [mailbox: [type: :string, default: "INBOX"]],
    output_schema: [
      emails: [type: {:list, :map}, required: true],
      count: [type: :integer, required: true]
    ]

  @behaviour Zaq.Engine.Workflows.Action
  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _), do: {:ok, result}
  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _), do: :ok

  @impl true
  def run(_params, _context), do: {:ok, %{emails: [], count: 0}}
end

defmodule Zaq.Engine.Workflows.Test.DraftReplyStub do
  @moduledoc false
  use Jido.Action,
    name: "test_draft_reply_stub",
    schema: [
      emails: [type: :any, default: []],
      delay_ms: [type: :integer, default: 0]
    ],
    output_schema: [drafts: [type: {:list, :map}, required: true]]

  @behaviour Zaq.Engine.Workflows.Action
  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _), do: {:ok, result}
  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _), do: :ok

  @impl true
  def run(%{emails: emails, delay_ms: delay_ms}, _context) do
    if delay_ms > 0, do: Process.sleep(delay_ms)

    drafts =
      Enum.map(emails, fn email ->
        from = email["from"] || %{}

        %{
          to_address: from["address"] || "unknown@example.com",
          to_name: from["name"],
          subject: "Re: #{email["subject"] || "(no subject)"}",
          draft: "Thank you for your email. We will get back to you shortly.",
          message_id: email["message_id"]
        }
      end)

    {:ok, %{drafts: drafts}}
  end
end

defmodule Zaq.Engine.Workflows.Test.DraftReplyErrorStub do
  @moduledoc false
  use Jido.Action,
    name: "test_draft_reply_error_stub",
    schema: [emails: [type: :any, default: []]],
    output_schema: [drafts: [type: {:list, :map}, required: true]]

  @behaviour Zaq.Engine.Workflows.Action
  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _), do: {:ok, result}
  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _), do: :ok

  @impl true
  def run(_params, _context), do: {:error, :internal_server_error}
end

defmodule Zaq.Engine.Workflows.Test.EmptyInboxNotificationStub do
  @moduledoc false
  use Jido.Action,
    name: "test_empty_inbox_notification_stub",
    schema: [notify_address: [type: :string, required: true]],
    output_schema: [
      status: [type: :atom, required: true],
      notified: [type: :boolean, required: true]
    ]

  @behaviour Zaq.Engine.Workflows.Action
  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _), do: {:ok, result}
  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _), do: :ok

  @impl true
  def run(_params, _context), do: {:ok, %{status: :skipped, notified: true}}
end

defmodule Zaq.Engine.Workflows.Test.EnsurePersonStub do
  @moduledoc false
  use Jido.Action,
    name: "test_ensure_person_stub",
    schema: [drafts: [type: :any, required: true]],
    output_schema: [drafts: [type: {:list, :map}, required: true]]

  @behaviour Zaq.Engine.Workflows.Action
  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _), do: {:ok, result}
  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _), do: :ok

  @impl true
  def run(%{drafts: drafts}, _context) do
    enriched =
      Enum.map(drafts, fn draft ->
        # Strict atom access — StepRunner must normalize keys before this runs
        _verified = draft.to_address
        Map.put(draft, :person_id, "test-person-id")
      end)

    {:ok, %{drafts: enriched}}
  end
end

defmodule Zaq.Engine.Workflows.Test.SendReplyStub do
  @moduledoc false
  use Jido.Action,
    name: "test_send_reply_stub",
    schema: [drafts: [type: :any, required: true]],
    output_schema: [
      sent: [type: :integer, required: true],
      failed: [type: :integer, required: true],
      results: [type: {:list, :map}, required: true]
    ]

  @behaviour Zaq.Engine.Workflows.Action
  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _), do: {:ok, result}
  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _), do: :ok

  @impl true
  def run(%{drafts: drafts}, _context) do
    results =
      Enum.map(drafts, fn d ->
        # Strict atom access — StepRunner must normalize keys before this runs
        %{to: d.to_address, status: :sent}
      end)

    {:ok, %{sent: length(drafts), failed: 0, results: results}}
  end
end

defmodule Zaq.Engine.Workflows.Test.StrictAtomAccessAction do
  @moduledoc """
  Test action that accesses draft fields with strict atom key syntax (`draft.to_address`).
  Mirrors the access pattern used in EnsurePerson and SendReply.
  Fails with KeyError when the draft maps are string-keyed (JSONB round-trip).
  """
  use Jido.Action,
    name: "test_strict_atom_access_action",
    schema: [drafts: [type: :any, required: true]],
    output_schema: [addresses: [type: {:list, :string}, required: true]]

  @behaviour Zaq.Engine.Workflows.Action
  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _), do: {:ok, result}
  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _), do: :ok

  @impl true
  def run(%{drafts: drafts}, _context) do
    # Strict atom access — raises KeyError when maps are string-keyed
    addresses = Enum.map(drafts, fn draft -> draft.to_address end)
    {:ok, %{addresses: addresses}}
  end
end

defmodule Zaq.Engine.Workflows.Test.RequireFirstName do
  @moduledoc false

  use Jido.Action,
    name: "test_require_first_name",
    schema: [first_name: [type: :any]],
    output_schema: [
      f_ran: [type: :boolean, required: true],
      first_name: [type: :string, required: true]
    ]

  @behaviour Zaq.Engine.Workflows.Action

  @impl Zaq.Engine.Workflows.Action
  def on_success(result, _context), do: {:ok, result}

  @impl Zaq.Engine.Workflows.Action
  def on_failure(_error, _context), do: :ok

  @impl true
  def run(params, _context) do
    first_name = Map.fetch!(params, :first_name)

    if Map.has_key?(params, :name),
      do: raise("F received raw :name key — mapping isolation failed")

    {:ok, %{f_ran: true, first_name: first_name}}
  end
end

defmodule Zaq.Engine.Workflows.Test.ListClients do
  @moduledoc false
  use Jido.Action,
    name: "test_list_clients",
    schema: [source: [type: :string, required: false]],
    output_schema: [clients: [type: :list, required: true]]

  use Zaq.Engine.Workflows.Action

  @clients [
    %{name: "Alice Smith", email: "alice@acme.com", company: "Acme Corp", size: 1200},
    %{name: "Bob Jones", email: "bob@startup.io", company: "Startup IO", size: 12},
    %{name: "Carol White", email: "carol@midco.com", company: "MidCo", size: 250},
    %{name: "Dan Brown", email: "dan@bigcorp.com", company: "BigCorp", size: 5000},
    %{name: "Eve Davis", email: "eve@smallbiz.net", company: "SmallBiz", size: 35},
    %{name: "Frank Miller", email: "frank@medtech.com", company: "MedTech", size: 180},
    %{name: "Grace Wilson", email: "grace@mega.com", company: "Mega Inc", size: 8500},
    %{name: "Hank Taylor", email: "hank@boutique.co", company: "Boutique Co", size: 8},
    %{name: "Iris Moore", email: "iris@regional.com", company: "Regional Ltd", size: 420},
    %{name: "Jake Lee", email: "jake@global.com", company: "Global Corp", size: 3200}
  ]

  @impl Jido.Action
  def run(_params, _context), do: {:ok, %{clients: @clients}}
end

defmodule Zaq.Engine.Workflows.Test.CategorizeBySize do
  @moduledoc false
  use Jido.Action,
    name: "test_categorize_by_size",
    schema: [items: [type: :list, required: true]],
    output_schema: [results: [type: :list, required: true]]

  use Zaq.Engine.Workflows.Action

  @impl Jido.Action
  def run(%{items: clients}, _context) do
    {:ok, %{results: Enum.map(clients, &categorize/1)}}
  end

  # Handles both atom and string keys (the latter can appear after JSONB round-trip on resume).
  defp categorize(client) do
    size = Map.get(client, :size) || Map.get(client, "size") || 0

    category =
      cond do
        size < 50 -> "small_business"
        size <= 500 -> "medium"
        true -> "enterprise"
      end

    Map.put(client, :category, category)
  end
end

defmodule Zaq.Engine.Workflows.Test.Sleep do
  @moduledoc false
  use Jido.Action,
    name: "test_sleep",
    schema: [
      results: [type: :list, required: true],
      duration_ms: [type: :integer, required: false, default: 200]
    ],
    output_schema: [results: [type: :list, required: true]]

  use Zaq.Engine.Workflows.Action

  @impl Jido.Action
  def run(params, _context) do
    duration = Map.get(params, :duration_ms, 200)
    Process.sleep(duration)
    {:ok, %{results: params.results}}
  end
end

# ---------------------------------------------------------------------------
# Iterate / Batch test doubles
# ---------------------------------------------------------------------------

defmodule Zaq.Engine.Workflows.Test.ProcessContact do
  @moduledoc false
  use Jido.Action,
    name: "test_process_contact",
    schema: [contact: [type: :map, required: true]],
    output_schema: [processed: [type: :map, required: true]]

  use Zaq.Engine.Workflows.Action

  @impl Jido.Action
  def run(%{contact: contact}, _context) do
    {:ok, %{processed: Map.put(contact, :done, true)}}
  end
end

defmodule Zaq.Engine.Workflows.Test.FilterContact do
  @moduledoc false
  use Jido.Action,
    name: "test_filter_contact",
    schema: [contact: [type: :map, required: true]],
    output_schema: [contact: [type: :map, required: true]]

  use Zaq.Engine.Workflows.Action

  @impl Jido.Action
  def run(%{contact: %{active: false}}, _context), do: {:error, :inactive}
  def run(%{contact: contact}, _context), do: {:ok, %{contact: contact}}
end

defmodule Zaq.Engine.Workflows.Test.SleepMs do
  @moduledoc false
  use Jido.Action,
    name: "test_sleep_ms",
    schema: [duration_ms: [type: :integer, required: false, default: 0]],
    output_schema: [slept_ms: [type: :integer, required: true]]

  use Zaq.Engine.Workflows.Action

  @impl Jido.Action
  def run(params, _context) do
    ms = Map.get(params, :duration_ms, 0)
    if ms > 0, do: Process.sleep(ms)
    {:ok, %{slept_ms: ms}}
  end
end

defmodule Zaq.Engine.Workflows.Test.FlattenClients do
  @moduledoc false
  use Jido.Action,
    name: "test_flatten_clients",
    schema: [results: [type: :list, required: true]],
    output_schema: [clients: [type: :list, required: true]]

  use Zaq.Engine.Workflows.Action

  @impl Jido.Action
  def run(%{results: chunk_results}, _context) do
    clients =
      Enum.flat_map(chunk_results, fn entry ->
        # A `map` node summarizes each fork as %{"index","status","result" => <output>};
        # the chunk's categorized list lives under that result. Fall back to the raw
        # shape for non-map callers.
        inner = Map.get(entry, "result") || Map.get(entry, :result) || entry
        Map.get(inner, :results) || Map.get(inner, "results") || []
      end)

    {:ok, %{clients: clients}}
  end
end

defmodule Zaq.Engine.Workflows.Test.EmitItems do
  @moduledoc "Emits a fixed `items` list — a source for `map` node tests."

  use Jido.Action,
    name: "test_emit_items",
    schema: [input: [type: :any]],
    output_schema: [items: [type: :list, required: true]]

  use Zaq.Engine.Workflows.Action

  @impl Jido.Action
  def run(_params, _context) do
    {:ok, %{items: [%{n: 1}, %{n: 2}, %{n: 3}]}}
  end
end

defmodule Zaq.Engine.Workflows.Test.SignalListener do
  @moduledoc """
  Named mailbox so an action running in a driver process can signal a test without
  touching the DB. Register the test pid via `listen/1`; actions call `notify/1`.
  """
  use Agent

  def start_link(_), do: Agent.start_link(fn -> nil end, name: __MODULE__)
  def listen(pid), do: Agent.update(__MODULE__, fn _ -> pid end)

  def notify(msg) do
    case Agent.get(__MODULE__, & &1) do
      pid when is_pid(pid) -> send(pid, msg)
      _ -> :ok
    end
  end
end

defmodule Zaq.Engine.Workflows.Test.NotifyThenBlock do
  @moduledoc """
  Signals `{:fork_running, self()}` (self = the driver process) then blocks until the
  driver receives `:release`. Lets a test catch a batch mid-fork, then unblock it.
  """

  use Jido.Action,
    name: "test_notify_then_block",
    schema: [input: [type: :any]],
    output_schema: [ok: [type: :boolean, required: true]]

  use Zaq.Engine.Workflows.Action

  alias Zaq.Engine.Workflows.Test.SignalListener

  @impl Jido.Action
  def run(_params, _context) do
    SignalListener.notify({:fork_running, self()})

    receive do
      :release -> {:ok, %{ok: true}}
    after
      30_000 -> {:ok, %{ok: true}}
    end
  end
end

defmodule Zaq.Engine.Workflows.Test.FailEvenN do
  @moduledoc "Map body step: succeeds on odd `n`, fails on even `n` — for strategy tests."

  use Jido.Action,
    name: "test_fail_even_n",
    schema: [n: [type: :any, required: true]],
    output_schema: [doubled: [type: :integer, required: true]]

  use Zaq.Engine.Workflows.Action

  @impl Jido.Action
  def run(%{n: n}, _context) do
    if rem(n, 2) == 0 do
      {:error, "even_n:#{n}"}
    else
      {:ok, %{doubled: n * 2}}
    end
  end
end

defmodule Zaq.Engine.Workflows.Test.FlakyTwice do
  @moduledoc """
  Map body step that fails its first two attempts per item, then succeeds — proves
  the `:retry` strategy actually re-runs a fork. Attempts are counted per-`n` in the
  process dictionary; map forks run sequentially in one process, so the counter is
  stable across a fork's retries while staying isolated between items.
  """

  use Jido.Action,
    name: "test_flaky_twice",
    schema: [n: [type: :any, required: true]],
    output_schema: [doubled: [type: :integer, required: true]]

  use Zaq.Engine.Workflows.Action

  @impl Jido.Action
  def run(%{n: n}, _context) do
    attempts = Process.get({:flaky, n}, 0) + 1
    Process.put({:flaky, n}, attempts)

    if attempts < 3 do
      {:error, "flaky:#{n}:attempt#{attempts}"}
    else
      {:ok, %{doubled: n * 2}}
    end
  end
end

defmodule Zaq.Engine.Workflows.Test.EmitNumbers do
  @moduledoc "Emits a fixed list of plain integers — a source for delivery/chunking map tests."

  use Jido.Action,
    name: "test_emit_numbers",
    schema: [input: [type: :any]],
    output_schema: [nums: [type: :list, required: true]]

  use Zaq.Engine.Workflows.Action

  @impl Jido.Action
  def run(_params, _context), do: {:ok, %{nums: [1, 2, 3, 4, 5]}}
end

defmodule Zaq.Engine.Workflows.Test.CaptureValue do
  @moduledoc "Map body that echoes whatever was delivered under `value` — for delivery/chunking tests."

  use Jido.Action,
    name: "test_capture_value",
    schema: [value: [type: :any, required: true]],
    output_schema: [captured: [type: :any, required: true]]

  use Zaq.Engine.Workflows.Action

  @impl Jido.Action
  def run(%{value: v}, _context), do: {:ok, %{captured: v}}
end

defmodule Zaq.Engine.Workflows.Test.MarkDone do
  @moduledoc "Map post_process tail that accepts any cascade input and marks the fork done."

  use Jido.Action,
    name: "test_mark_done",
    schema: [input: [type: :any]],
    output_schema: [done: [type: :boolean, required: true]]

  use Zaq.Engine.Workflows.Action

  @impl Jido.Action
  def run(_params, _context), do: {:ok, %{done: true}}
end

# ---------------------------------------------------------------------------
# Sequential-timing test support (Batch chunk_size: 1 + per-fork post_process)
# ---------------------------------------------------------------------------

defmodule Zaq.Engine.Workflows.Test.TimeRecorder do
  @moduledoc """
  Collects `{chunk, monotonic_ms}` marks in the order map forks execute them — one
  mark per Batch iteration. Lets a test see which chunks ran and when.
  """
  use Agent

  def start_link(_), do: Agent.start_link(fn -> [] end, name: __MODULE__)

  def record(chunk),
    do: Agent.update(__MODULE__, &[{chunk, System.monotonic_time(:millisecond)} | &1])

  # Marks in execution order (oldest first).
  def marks, do: Agent.get(__MODULE__, &Enum.reverse/1)

  # The recorded chunks (each a sorted list of item indices) in execution order.
  def chunks, do: Enum.map(marks(), fn {chunk, _ms} -> chunk end)

  def reset, do: Agent.update(__MODULE__, fn _ -> [] end)
end

defmodule Zaq.Engine.Workflows.Test.EmitIndexedItems do
  @moduledoc "Emits `[%{index: 1}, %{index: 2}, ...]` — source for sequential-timing Batch tests."
  use Jido.Action,
    name: "test_emit_indexed_items",
    schema: [count: [type: :integer, required: false, default: 3]],
    output_schema: [items: [type: :list, required: true]]

  use Zaq.Engine.Workflows.Action

  @impl Jido.Action
  def run(params, _context) do
    count = Map.get(params, :count, 3)
    {:ok, %{items: Enum.map(1..count, &%{index: &1})}}
  end
end

defmodule Zaq.Engine.Workflows.Test.RecordItemTime do
  @moduledoc """
  Map body step (delivery `"list"`): runs **once per delivered chunk** (i.e. once
  per Batch iteration). It logs the execution time and records one `TimeRecorder`
  mark keyed by the chunk's item indices, then passes the chunk through as `items`.
  It does **not** sleep — the wait is a separate `Zaq.Agent.Tools.Workflow.Sleep`
  node in the Batch's `post_process`.
  """
  use Jido.Action,
    name: "test_record_item_time",
    schema: [items: [type: :list, required: true]],
    output_schema: [items: [type: :list, required: true]]

  use Zaq.Engine.Workflows.Action

  alias Zaq.Engine.Workflows.Test.TimeRecorder

  @impl Jido.Action
  def run(%{items: items}, _context) do
    indices = Enum.map(items, fn item -> Map.get(item, :index) || Map.get(item, "index") end)

    # IO.puts (not Logger) so it prints regardless of the test logger level (:warning).
    IO.puts(
      "[RecordItemTime] executing chunk #{inspect(indices)} at #{DateTime.utc_now() |> DateTime.to_iso8601()}"
    )

    # One mark per chunk — NOT per item — so the recorded count reflects Batch
    # iterations, faithfully honoring `batch_size`.
    TimeRecorder.record(Enum.sort(indices))

    {:ok, %{items: items}}
  end
end

# ---------------------------------------------------------------------------
# Numeric routing / arithmetic test doubles
# ---------------------------------------------------------------------------

defmodule Zaq.Engine.Workflows.Test.RouteByRange do
  @moduledoc false
  # Start node for numeric routing. Passes `number` through unchanged and
  # classifies it into a `bucket` via three range conditions:
  #   number < 10        -> "a"
  #   10 <= number < 20  -> "b"
  #   20 <= number < 30  -> "c"
  # Edge conditions are single-op, so the range logic lives here and the outgoing
  # edges route with `eq` on the emitted bucket.
  use Jido.Action,
    name: "test_route_by_range",
    schema: [number: [type: :integer, required: true]],
    output_schema: [
      number: [type: :integer, required: true],
      bucket: [type: :string, required: true]
    ]

  use Zaq.Engine.Workflows.Action

  @impl Jido.Action
  def run(params, _context) do
    number = Map.get(params, :number) || Map.get(params, "number")

    bucket =
      cond do
        number < 10 -> "a"
        number < 20 -> "b"
        number < 30 -> "c"
        true -> "out_of_range"
      end

    {:ok, %{number: number, bucket: bucket}}
  end
end

defmodule Zaq.Engine.Workflows.Test.Decrement do
  @moduledoc false
  # Decrements the running `number` by 1 and passes it on, so a chain of N
  # Decrement nodes lowers the number by exactly N.
  use Jido.Action,
    name: "test_decrement",
    schema: [number: [type: :integer, required: true]],
    output_schema: [number: [type: :integer, required: true]]

  use Zaq.Engine.Workflows.Action

  @impl Jido.Action
  def run(params, _context) do
    number = Map.get(params, :number) || Map.get(params, "number")
    {:ok, %{number: number - 1}}
  end
end

defmodule Zaq.Engine.Workflows.Test.SelfDestruct do
  @moduledoc """
  Kills its own process with an untrappable `:kill` signal instead of
  returning or raising — simulates a hard crash (OOM kill, unrelated
  supervisor action) mid-step, which bypasses `StepRunner`'s `rescue` entirely
  (unlike a normal `raise`, which Runic's `Invokable.execute/2` catches and
  turns into a failed runnable). Used to prove `RunWatcher` recovers a run
  even when nothing in the call stack ever gets a chance to run cleanup code.
  """

  use Jido.Action,
    name: "test_self_destruct",
    schema: [input: [type: :any]],
    output_schema: [never: [type: :boolean, required: true]]

  use Zaq.Engine.Workflows.Action

  @impl Jido.Action
  def run(_params, _context) do
    Process.exit(self(), :kill)
    {:ok, %{never: true}}
  end
end

defmodule Zaq.Engine.Workflows.Test.RaiseOnEven do
  @moduledoc """
  Map/Batch body step: raises (not `{:error, _}`) on even `n`, succeeds on odd —
  reproduces a body action that crashes instead of returning a controlled error.
  """

  use Jido.Action,
    name: "test_raise_on_even",
    schema: [n: [type: :any, required: true]],
    output_schema: [doubled: [type: :integer, required: true]]

  use Zaq.Engine.Workflows.Action

  @impl Jido.Action
  def run(%{n: n}, _context) do
    if rem(n, 2) == 0 do
      raise "boom_even_n:#{n}"
    else
      {:ok, %{doubled: n * 2}}
    end
  end
end

defmodule Zaq.Engine.Workflows.Test.AlwaysRaise do
  @moduledoc """
  Map/Batch step that always raises — used as a `post_process` tail step that
  crashes instead of returning a controlled `{:error, _}`.
  """

  use Jido.Action,
    name: "test_always_raise",
    schema: [doubled: [type: :any]],
    output_schema: [noop: [type: :boolean, required: true]]

  use Zaq.Engine.Workflows.Action

  @impl Jido.Action
  def run(_params, _context) do
    raise "boom_post_process"
  end
end
