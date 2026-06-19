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
      Enum.flat_map(chunk_results, fn chunk ->
        Map.get(chunk, :results) || Map.get(chunk, "results") || []
      end)

    {:ok, %{clients: clients}}
  end
end
