defmodule Zaq.Engine.Workflows.UseCasesTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows
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

      process_rows = Enum.find(attrs.nodes, &(&1.name == "process_rows"))
      assert process_rows.type == "map"
      assert process_rows.params["over"] == "items"
      assert process_rows.params["field"] == "input"
      assert process_rows.params["delivery"] == "item"
      assert process_rows.params["chunk_size"] == 50
      assert process_rows.params["strategy"] == "skip_and_continue"

      assert Enum.map(process_rows.params["body"], & &1["name"]) == [
               "check_active",
               "check_email_state",
               "dispatch_lead"
             ]

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
          agent_name: "CustomDraftAgent"
        )

      assert attrs.name == "Send Leads Email"
      assert attrs.status == "active"

      assert Enum.map(attrs.nodes, & &1.name) == [
               "ensure_person",
               "build_history",
               "draft_email",
               "review_email",
               "send_email",
               "build_sheet_update",
               "update_sheet_row"
             ]

      draft_email = Enum.find(attrs.nodes, &(&1.name == "draft_email"))
      assert draft_email.params["agent_name"] == "CustomDraftAgent"
      assert draft_email.params["input"] =~ "Draft outreach email"

      build_sheet_update = Enum.find(attrs.nodes, &(&1.name == "build_sheet_update"))
      assert build_sheet_update.params == %{"column" => "K", "increment_by" => 1}

      update_sheet_row = Enum.find(attrs.nodes, &(&1.name == "update_sheet_row"))
      assert update_sheet_row.params["spreadsheet_id"] == "sheet-456"
      assert update_sheet_row.params["provider"] == "custom_drive"

      assert Enum.map(attrs.edges, &{&1.from, &1.to}) == [
               {"ensure_person", "build_history"},
               {"build_history", "draft_email"},
               {"draft_email", "review_email"},
               {"review_email", "send_email"},
               {"send_email", "build_sheet_update"},
               {"build_sheet_update", "update_sheet_row"}
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
                 agent_name: "CustomDraftAgent"
               )

      trigger = workflow_trigger(workflow)

      assert workflow.name == "Send Leads Email"
      assert trigger.event_name == "engine:lead_identified"
    end
  end

  defp workflow_trigger(workflow) do
    assert [trigger] = Workflows.list_triggers_for_workflow(workflow.id)
    trigger
  end
end
