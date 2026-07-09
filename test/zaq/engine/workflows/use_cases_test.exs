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
               "check_last_message_date",
               "build_agent_context",
               "draft_email",
               "review_email",
               "send_email",
               "update_history",
               "increment_email_state",
               "build_range",
               "build_values",
               "update_sheet_row"
             ]

      draft_email = Enum.find(attrs.nodes, &(&1.name == "draft_email"))
      assert draft_email.params["agent_id"] == 7
      assert draft_email.params["input"] =~ "outreach email"

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
               {"build_history", "check_last_message_date"},
               {"check_last_message_date", "build_agent_context"},
               {"build_agent_context", "draft_email"},
               {"draft_email", "review_email"},
               {"review_email", "send_email"},
               {"send_email", "update_history"},
               {"update_history", "increment_email_state"},
               {"increment_email_state", "build_range"},
               {"build_range", "build_values"},
               {"build_values", "update_sheet_row"}
             ]
    end
  end

  describe "SendLeadsEmail.create/1" do
    test "creates the workflow and assigns the craft_email trigger" do
      assert {:ok, workflow} =
               SendLeadsEmail.create(
                 sheet_id: "sheet-456",
                 provider: "custom_drive",
                 email_state_column: "K",
                 agent_id: 7
               )

      trigger = workflow_trigger(workflow)

      assert workflow.name == "Send Leads Email"
      # SendLeadsEmail is now the consumer of the `craft_email` hand-off dispatched
      # by GenerateCompanyContext (which converges both entry branches on it).
      assert trigger.event_name == "engine:craft_email"
    end
  end

  describe "GenerateCompanyContext.build/1" do
    test "forks at entry on two `from: \"start\"` edges, not a Condition node" do
      attrs = GenerateCompanyContext.build()

      # Branching lives on the reserved `start` origin now, so there is no
      # check_context Condition node and no load_existing_context branch.
      refute Enum.any?(attrs.nodes, &(&1.name == "check_context"))
      refute Enum.any?(attrs.nodes, &(&1.name == "load_existing_context"))

      start_edges = Enum.filter(attrs.edges, &(&1.from == "start"))
      assert length(start_edges) == 2

      # Context already present → short-circuit to craft_email_direct (a DispatchEvent).
      # The dispatch is split into two single-parent nodes (craft_email_direct /
      # craft_email) so neither is a nondeterministic convergence node.
      craft_email_direct = Enum.find(attrs.nodes, &(&1.name == "craft_email_direct"))
      assert craft_email_direct.module == "Zaq.Agent.Tools.Workflow.DispatchEvent"

      craft_email_after = Enum.find(attrs.nodes, &(&1.name == "craft_email"))
      assert craft_email_after.module == "Zaq.Agent.Tools.Workflow.DispatchEvent"

      # Each dispatch node has exactly one inbound edge (single-parent, deterministic).
      assert Enum.count(attrs.edges, &(&1.to == "craft_email_direct")) == 1
      assert Enum.count(attrs.edges, &(&1.to == "craft_email")) == 1

      have_context = Enum.find(start_edges, &(&1.to == "craft_email_direct"))

      assert have_context.condition == %{
               "field" => "start.company context content",
               "op" => "not_empty"
             }

      # No mapping on purpose: the full start fact (a map) flows into the
      # dispatch node. A scalar mapping would make the dispatched request a
      # scalar, which cannot carry the `machine: true` flag — see
      # craft_email_trigger_test.exs.
      refute Map.has_key?(have_context, :mapping)

      # No context yet → generate. Spaced sheet columns are renamed to snake_case
      # targets for {{...}} prompt interpolation; sources keep their spaces.
      generate = Enum.find(start_edges, &(&1.to == "extract_company_summary"))
      assert generate.condition == %{"field" => "start.company context content", "op" => "empty"}

      assert generate.mapping == %{
               "company_official_name" => "start.company official name",
               "company_website" => "start.company website"
             }
    end

    test "the persisted (JSONB) shape builds a valid DAG" do
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

  defp workflow_trigger(workflow) do
    assert [trigger] = Workflows.list_triggers_for_workflow(workflow.id)
    trigger
  end
end
