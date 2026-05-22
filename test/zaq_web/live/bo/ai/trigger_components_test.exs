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

    test "disabled badge shows disabled text and muted style" do
      html =
        render_component(&TriggerComponents.event_badge/1,
          event_name: "email.received",
          enabled: false
        )

      assert html =~ "disabled"
      assert html =~ "bg-black/5"
    end
  end

  describe "workflow_chip/1" do
    test "renders workflow name and link" do
      workflow = %{id: "wf-1", name: "My Workflow", status: "active"}
      html = render_component(&TriggerComponents.workflow_chip/1, workflow: workflow)
      assert html =~ "My Workflow"
      assert html =~ "/bo/workflows/wf-1"
    end

    test "renders status dot for active workflow" do
      workflow = %{id: "wf-1", name: "Active WF", status: "active"}
      html = render_component(&TriggerComponents.workflow_chip/1, workflow: workflow)
      assert html =~ "bg-emerald-400"
    end

    test "renders status dot for draft workflow" do
      workflow = %{id: "wf-2", name: "Draft WF", status: "draft"}
      html = render_component(&TriggerComponents.workflow_chip/1, workflow: workflow)
      assert html =~ "bg-amber-400"
    end
  end

  describe "run_row/1" do
    test "links to correct run path" do
      run = %{
        id: "run-1",
        status: "completed",
        inserted_at: DateTime.utc_now()
      }

      html =
        render_component(&TriggerComponents.run_row/1, run: run, workflow_id: "wf-abc")

      assert html =~ "/bo/workflows/wf-abc/runs/run-1"
    end

    test "displays run status badge" do
      run = %{id: "run-2", status: "failed", inserted_at: DateTime.utc_now()}
      html = render_component(&TriggerComponents.run_row/1, run: run, workflow_id: "wf-1")
      assert html =~ "failed"
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
  end
end
