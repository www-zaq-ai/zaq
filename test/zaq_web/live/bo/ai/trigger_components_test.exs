defmodule ZaqWeb.Live.BO.AI.TriggerComponentsTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Zaq.Engine.Workflows.Trigger
  alias ZaqWeb.Live.BO.AI.TriggerComponents

  describe "trigger_explainer/1" do
    test "renders heading text" do
      html = render_component(&TriggerComponents.trigger_explainer/1, open: true)
      assert html =~ "How triggers work"
    end

    test "renders explanation copy" do
      html = render_component(&TriggerComponents.trigger_explainer/1, open: true)
      assert html =~ "automatically starts one or more workflows"
    end
  end

  describe "event_badge/1" do
    test "renders event name" do
      html =
        render_component(&TriggerComponents.event_badge/1,
          event_name: "email.received",
          enabled: true
        )

      assert html =~ "email.received"
    end

    test "enabled badge uses accent color class" do
      html =
        render_component(&TriggerComponents.event_badge/1,
          event_name: "email.received",
          enabled: true
        )

      assert html =~ "zaq-color-accent"
    end

    test "disabled badge uses muted style" do
      html =
        render_component(&TriggerComponents.event_badge/1,
          event_name: "email.received",
          enabled: false
        )

      assert html =~ "bg-black/5"
    end
  end

  describe "workflow_row/1" do
    defp workflow_row_html(attrs) do
      defaults = [
        trigger_id: "trig-1",
        workflow: %{id: "wf-1", name: "My Workflow", status: "active"}
      ]

      render_component(&TriggerComponents.workflow_row/1, Keyword.merge(defaults, attrs))
    end

    test "renders workflow name and link" do
      html = workflow_row_html([])
      assert html =~ "My Workflow"
      assert html =~ "/bo/workflows/wf-1"
    end

    test "renders remove control wired to trigger and workflow" do
      html = workflow_row_html([])
      assert html =~ ~s(phx-click="remove_workflow")
      assert html =~ ~s(phx-value-trigger_id="trig-1")
      assert html =~ ~s(phx-value-workflow_id="wf-1")
    end

    test "renders status dot for active, draft, and unknown workflow status" do
      assert workflow_row_html(workflow: %{id: "wf", name: "A", status: "active"}) =~
               "bg-emerald-400"

      assert workflow_row_html(workflow: %{id: "wf", name: "D", status: "draft"}) =~
               "bg-amber-400"

      assert workflow_row_html(workflow: %{id: "wf", name: "U", status: "custom"}) =~
               "bg-black/20"
    end

    test "shows 'no runs yet' when there is no run" do
      html = workflow_row_html(run: nil)
      assert html =~ "no runs yet"
    end

    test "displays run status badge and relative time when a run is present" do
      run = %{id: "run-2", status: "failed", inserted_at: DateTime.add(DateTime.utc_now(), -120)}
      html = workflow_row_html(run: run)
      assert html =~ "failed"
      assert html =~ "min ago"
      refute html =~ "no runs yet"
    end

    test "renders relative time in minutes, hours, and days" do
      base = fn secs ->
        %{id: "r", status: "completed", inserted_at: DateTime.add(DateTime.utc_now(), secs)}
      end

      assert workflow_row_html(run: base.(-120)) =~ "min ago"
      assert workflow_row_html(run: base.(-7_200)) =~ "hr ago"
      assert workflow_row_html(run: base.(-172_800)) =~ "days ago"
    end
  end

  describe "trigger_form/1" do
    test "renders event_name input" do
      form =
        %Trigger{}
        |> Trigger.changeset(%{})
        |> Phoenix.Component.to_form()

      html =
        render_component(&TriggerComponents.trigger_form/1,
          form: form,
          known_events: ["email.received", "webhook.posted"]
        )

      assert html =~ "event_name"
      assert html =~ "email.received"
      assert html =~ "webhook.posted"
    end

    test "renders enabled checkbox" do
      form =
        %Trigger{}
        |> Trigger.changeset(%{})
        |> Phoenix.Component.to_form()

      html = render_component(&TriggerComponents.trigger_form/1, form: form, known_events: [])
      assert html =~ "trigger_enabled"
      assert html =~ "Enabled"
    end

    test "renders translated event_name error when present" do
      cs =
        %Trigger{}
        |> Trigger.changeset(%{})
        |> Ecto.Changeset.add_error(:event_name, "should be at least %{count} chars", count: 3)

      form = Phoenix.Component.to_form(%{cs | action: :validate})

      html = render_component(&TriggerComponents.trigger_form/1, form: form, known_events: [])
      assert html =~ "should be at least 3 chars"
    end
  end
end
