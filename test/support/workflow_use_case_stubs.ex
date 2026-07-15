defmodule Zaq.Engine.Workflows.Test.UseCaseStubs do
  @moduledoc """
  Shared external-boundary stubs for the full use-case workflow e2e tests.

  The use-case workflows imported via `UseCaseFixtures.import_fixture/2` run every
  node for real EXCEPT the true external boundaries — LLM agent calls, Google Sheet
  read/write, and the SMTP hop — which cannot execute in a test. Each stub honors
  the real tool's output contract so the production edges, conditions, and mappings
  still validate the wiring around it.

  Pass them per node via the fixture's `:swap` option, e.g.

      UseCaseFixtures.import_fixture("send_leads_email.json",
        swap: %{
          "draft_email" => UseCaseStubs.AgentStub,
          "update_sheet_row" => UseCaseStubs.UpdateSheetStub
        })

  `send_email` / `update_history` are deliberately NOT stubbed here by default: the
  threading tests keep them real. Use `NotifyEchoStub` / `HistoryEchoStub` only when
  a test needs to read back the resolved subject/topic without a real channel.
  """

  # LLM agent call (`RunAgent`). Returns a deterministic non-empty `output` so any
  # `output not_empty` guard passes and the drafted text flows downstream.
  defmodule AgentStub do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "use_case_agent_stub",
      schema: [
        agent_id: [type: :integer, required: false],
        input: [type: :string, required: false],
        name: [type: :any, required: false],
        company: [type: :any, required: false],
        language: [type: :any, required: false],
        summary: [type: :any, required: false],
        mapping: [type: :any, required: false],
        document: [type: :any, required: false],
        context: [type: :any, required: false]
      ],
      output_schema: [output: [type: :string, required: true]]

    @impl Jido.Action
    def run(params, _ctx) do
      name = params[:name] || params["name"] || "there"
      {:ok, %{output: "Hi #{name}, ZAQ can help. Julien, ZAQ"}}
    end
  end

  # Google Sheet read (`GetSheet`). Returns a fixture `%Record{}` whose content is
  # configured per-test under `:e2e_lead_sheet_content`, so the real `ExtractRows`
  # parses it exactly as it would a live sheet.
  defmodule GetSheetStub do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "use_case_get_sheet_stub",
      schema: [
        provider: [type: :string, required: true],
        spreadsheet_id: [type: :string, required: true],
        range: [type: :string, required: false],
        config_id: [type: :string, required: false]
      ],
      output_schema: [record: [type: :any, required: true]]

    @impl Jido.Action
    def run(_params, _ctx) do
      content = Application.get_env(:zaq, :e2e_lead_sheet_content, [])
      {:ok, %{record: %Zaq.Contracts.Record{id: "stub", kind: :sheet, content: content}}}
    end
  end

  # Google Sheet write (`UpdateSheetValues`). Mirrors the status contract.
  defmodule UpdateSheetStub do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "use_case_update_sheet_stub",
      schema: [
        provider: [type: :string, required: false],
        spreadsheet_id: [type: :string, required: false],
        range: [type: :any, required: false],
        values: [type: :any, required: false],
        row: [type: :any, required: false],
        column: [type: :string, required: false],
        value: [type: :any, required: false],
        value_input_option: [type: :string, required: false]
      ],
      output_schema: [status: [type: :string, required: true]]

    @impl Jido.Action
    def run(_params, _ctx), do: {:ok, %{status: "updated"}}
  end

  # Notification dispatch (`NotifyPerson`). Echoes the resolved subject/message so a
  # test can assert what the engine handed to the send seam. Use only when the real
  # NotifyPerson is not the seam under test (threading tests keep it real).
  defmodule NotifyEchoStub do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "use_case_notify_echo_stub",
      schema: [
        person: [type: :any, required: false],
        subject: [type: :string, required: true],
        message: [type: :any, required: false]
      ],
      output_schema: [
        notified: [type: :boolean, required: true],
        status: [type: :any, required: false],
        subject: [type: :string, required: false],
        sent_message: [type: :string, required: false]
      ]

    @impl Jido.Action
    def run(params, _ctx) do
      {:ok,
       %{
         notified: true,
         status: :dispatched,
         subject: params[:subject] || params["subject"],
         sent_message: to_string(params[:message] || params["message"] || "")
       }}
    end
  end

  # History persistence (`PersistMessageHistory`). Echoes the resolved topic. Use
  # only when the real persistence round trip is not the seam under test.
  defmodule HistoryEchoStub do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "use_case_history_echo_stub",
      schema: [
        person: [type: :any, required: false],
        topic: [type: :any, required: false],
        message: [type: :any, required: false],
        message_id: [type: :any, required: false],
        thread_id: [type: :any, required: false],
        metadata: [type: :any, required: false]
      ],
      output_schema: [
        persisted: [type: :boolean, required: true],
        conversation_id: [type: :string, required: true],
        message_id: [type: :string, required: true],
        topic: [type: :any, required: false]
      ]

    @impl Jido.Action
    def run(params, _ctx) do
      {:ok,
       %{
         persisted: true,
         conversation_id: "stub-conv",
         message_id: "stub-msg",
         topic: params[:topic] || params["topic"]
       }}
    end
  end

  # Wraps the real `DispatchEvent` so it routes through the Mox `NodeRouterMock`
  # (whose per-test stub fires `TriggerNode`), while delegating ALL machine-flag and
  # request-building logic to the real tool. `StepRunner` does not inject a
  # `node_router`, so without this the real DispatchEvent would hit the live router.
  defmodule BridgeDispatchEvent do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "use_case_bridge_dispatch_event",
      schema: [
        input: [type: :any, required: false],
        event_name: [type: :string, required: true],
        machine: [type: :boolean, required: false, default: false]
      ],
      output_schema: [dispatched: [type: :map, required: true]]

    alias Zaq.Agent.Tools.Workflow.DispatchEvent

    @impl Jido.Action
    def run(params, ctx) do
      DispatchEvent.run(params, Map.put(ctx, :node_router, Zaq.NodeRouterMock))
    end
  end

  @doc """
  A `:patch` fun (for `import_fixture/2`) that shortens a `Sleep` node's
  `duration_ms` to 0 so a run with a `sleep_between` step is instant.
  """
  def zero_sleep(node) do
    params = Map.put(node["params"] || %{}, "duration_ms", 0)
    Map.put(node, "params", params)
  end
end
