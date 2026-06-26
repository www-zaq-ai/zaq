defmodule Zaq.Engine.Workflows.UseCasesTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.DagBuilder
  alias Zaq.Engine.Workflows.UseCases.GenerateCompanyContext
  alias Zaq.Engine.Workflows.UseCases.IdentifyLeadsFromGoogleSheet
  alias Zaq.Engine.Workflows.UseCases.SendLeadsEmail

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  describe "IdentifyLeadsFromGoogleSheet.build/2" do
    test "builds the scheduled lead producer workflow with overridable sheet settings" do
      attrs = IdentifyLeadsFromGoogleSheet.build("sheet-123", "custom_drive")

      assert attrs.name == "Identify Leads from Google Sheet"
      assert attrs.status == "active"
      assert Enum.map(attrs.nodes, & &1.name) == ["get_sheet", "extract_rows", "process_rows"]

      get_sheet = Enum.find(attrs.nodes, &(&1.name == "get_sheet"))
      assert get_sheet.params == %{"provider" => "custom_drive", "spreadsheet_id" => "sheet-123"}

      # Iteration is authored as a `Batch` action (type "action"), not a public
      # `map` node — `Batch` lowers itself onto the internal `map` at build time.
      # Per-row delivery is the explicit `delivery: "item"` param (no Iterate wrapper).
      process_rows = Enum.find(attrs.nodes, &(&1.name == "process_rows"))
      assert process_rows.type == "action"
      assert process_rows.module == "Zaq.Agent.Tools.Workflow.Batch"
      assert process_rows.params["delivery"] == "item"
      assert process_rows.params["strategy"] == "skip_and_continue"

      assert Enum.map(process_rows.params["process"], & &1["name"]) == [
               "check_active",
               "check_email_state",
               "dispatch_lead"
             ]

      assert Enum.map(process_rows.params["post_process"], & &1["name"]) == ["sleep_between"]

      assert [%{from: "get_sheet", to: "extract_rows"}, extract_to_process] = attrs.edges
      assert extract_to_process.condition == %{"field" => "rows", "op" => "not_empty"}
      assert extract_to_process.mapping == %{"items" => "rows"}
    end
  end

  describe "IdentifyLeadsFromGoogleSheet.create/1" do
    test "creates the workflow and assigns the cron trigger" do
      assert {:ok, workflow} =
               IdentifyLeadsFromGoogleSheet.create(
                 sheet_id: "sheet-123",
                 provider: "custom_drive",
                 cron_schedule: "15 8 * * *"
               )

      trigger = workflow_trigger(workflow)

      assert workflow.name == "Identify Leads from Google Sheet"
      assert trigger.event_name == "engine:identify_leads_scan"
      assert trigger.trigger_type == "cron"
      assert trigger.cron_schedule == "15 8 * * *"
    end
  end

  describe "SendLeadsEmail.build/1" do
    test "builds the lead email workflow with overridable email and sheet settings" do
      attrs =
        SendLeadsEmail.build(
          sheet_id: "sheet-456",
          provider: "custom_drive",
          email_state_column: "K",
          agent_id: 7
        )

      assert attrs.name == "Send Leads Email"
      assert attrs.status == "active"

      assert Enum.map(attrs.nodes, & &1.name) == [
               "ensure_person",
               "build_history",
               "draft_email",
               "review_email",
               "send_email",
               "increment_email_state",
               "build_range",
               "build_values",
               "update_sheet_row"
             ]

      draft_email = Enum.find(attrs.nodes, &(&1.name == "draft_email"))
      assert draft_email.params["agent_id"] == 7
      assert draft_email.params["input"] =~ "Draft outreach email"

      build_range = Enum.find(attrs.nodes, &(&1.name == "build_range"))
      assert build_range.params["column"] == "K"
      assert build_range.params["parts"] == ["Sheet1!{{column}}{{row}}"]

      build_values = Enum.find(attrs.nodes, &(&1.name == "build_values"))
      assert build_values.params == %{"parts" => ["{{value}}"], "as_matrix" => true}

      update_sheet_row = Enum.find(attrs.nodes, &(&1.name == "update_sheet_row"))
      assert update_sheet_row.params["spreadsheet_id"] == "sheet-456"
      assert update_sheet_row.params["provider"] == "custom_drive"

      assert Enum.map(attrs.edges, &{&1.from, &1.to}) == [
               {"ensure_person", "build_history"},
               {"build_history", "draft_email"},
               {"draft_email", "review_email"},
               {"review_email", "send_email"},
               {"send_email", "increment_email_state"},
               {"increment_email_state", "build_range"},
               {"build_range", "build_values"},
               {"build_values", "update_sheet_row"}
             ]
    end
  end

  describe "SendLeadsEmail.create/1" do
    test "creates the workflow and assigns the lead identified trigger" do
      assert {:ok, workflow} =
               SendLeadsEmail.create(
                 sheet_id: "sheet-456",
                 provider: "custom_drive",
                 email_state_column: "K",
                 agent_id: 7
               )

      trigger = workflow_trigger(workflow)

      assert workflow.name == "Send Leads Email"
      assert trigger.event_name == "engine:lead_identified"
    end
  end

  describe "GenerateCompanyContext.build/1" do
    test "branches via a Condition node, not edge predicates (node = eval, edges = route)" do
      attrs = GenerateCompanyContext.build()

      # The evaluation unit is a Condition node placed before the two branches.
      check_context = Enum.find(attrs.nodes, &(&1.name == "check_context"))
      assert check_context.type == "action"
      assert check_context.module == "Zaq.Agent.Tools.Workflow.Condition"
      assert check_context.params["on_fail"] == "continue"

      assert check_context.params["conditions"] == [
               %{"key" => "company context file", "op" => "not_empty"}
             ]

      # check_context is a root: no incoming edge (the engine feeds it the planted
      # trigger row directly), and there are no `from: "start"` edges — a bare start
      # edge is rejected, and branching now lives in the node, not the edge.
      assert Enum.filter(attrs.edges, &(&1.from == "start")) == []
      refute Enum.any?(attrs.edges, &(&1.to == "check_context"))

      # The two edges out of the node only route on the emitted `passed` boolean.
      load_edge = branch_edge(attrs, "load_existing_context")
      assert load_edge.from == "check_context"
      assert load_edge.condition == %{"field" => "passed", "op" => "eq", "value" => true}
      assert load_edge.mapping == %{"document_id" => "start.company context file"}

      generate_edge = branch_edge(attrs, "extract_company_summary")
      assert generate_edge.from == "check_context"
      assert generate_edge.condition == %{"field" => "passed", "op" => "eq", "value" => false}

      assert generate_edge.mapping == %{
               "company_official_name" => "start.company official name",
               "company_website" => "start.company website"
             }
    end

    test "the persisted (JSONB) shape builds a valid DAG with check_context as the root" do
      snapshot = GenerateCompanyContext.build() |> Jason.encode!() |> Jason.decode!()

      assert {:ok, _dag} = DagBuilder.build(snapshot)
    end

    test "the built workflow persists and assigns the lead_identified trigger" do
      assert {:ok, workflow} = GenerateCompanyContext.create()

      trigger = workflow_trigger(workflow)
      assert workflow.name == "Generate Company Context"
      assert trigger.event_name == "engine:lead_identified"
    end
  end

  defp branch_edge(attrs, to), do: Enum.find(attrs.edges, &(&1.to == to))

  defp workflow_trigger(workflow) do
    assert [trigger] = Workflows.list_triggers_for_workflow(workflow.id)
    trigger
  end
end
