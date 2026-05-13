defmodule ZaqWeb.Live.BO.AI.WorkflowRunLiveTest do
  use ZaqWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.StepRun
  alias Zaq.Repo

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = user_fixture(%{username: "wf-run-test-#{System.unique_integer([:positive])}"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    stub(Zaq.NodeRouterMock, :find_node, fn _supervisor -> :services@localhost end)
    conn = init_test_session(conn, %{user_id: user.id})
    %{conn: conn}
  end

  @valid_node %{
    name: "fetch",
    type: "action",
    module: "Zaq.Agent.Tools.Email.FetchEmails",
    params: %{},
    index: 0
  }
  @valid_source_event %{
    "request" => nil,
    "assigns" => %{"trigger_type" => "manual"},
    "trace_id" => Ecto.UUID.generate()
  }

  defp workflow_fixture(attrs \\ %{}) do
    {:ok, w} =
      Workflows.create_workflow(
        Map.merge(%{name: "Run Workflow", status: "draft", nodes: [@valid_node]}, attrs)
      )

    w
  end

  defp run_fixture(workflow) do
    {:ok, run} = Workflows.create_run(workflow, @valid_source_event)
    run
  end

  defp step_run_fixture(run, attrs \\ %{}) do
    StepRun
    |> struct()
    |> StepRun.changeset(
      Map.merge(
        %{
          workflow_run_id: run.id,
          step_name: "fetch",
          step_index: 0,
          status: "completed",
          logs: [],
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now()
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  describe "mount" do
    test "renders run status badge and short run ID in page", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)

      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      short_id = String.slice(run.id, 0, 8)
      assert html =~ short_id
      assert html =~ run.status
    end

    test "renders breadcrumb with workflow name", %{conn: conn} do
      workflow = workflow_fixture(%{name: "Breadcrumb Workflow", nodes: [@valid_node]})
      run = run_fixture(workflow)

      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      assert html =~ "Breadcrumb Workflow"
      assert html =~ "Workflows"
    end

    test "renders 'Execution Path' section heading", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)

      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      assert html =~ "Execution Path"
    end

    test "renders SVG dag in Execution Path when workflow has nodes", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)

      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      assert html =~ "<svg"
    end

    test "renders step cards for each step_run", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)
      step_run_fixture(run, %{step_name: "fetch", step_index: 0, status: "completed"})

      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      assert html =~ "fetch"
    end

    test "shows step name and status badge per step", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)
      step_run_fixture(run, %{step_name: "fetch", step_index: 0, status: "completed"})

      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      assert html =~ "fetch"
      assert html =~ "completed"
    end

    test "shows log entries for a step with logs", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)

      step_run_fixture(run, %{
        step_name: "fetch",
        step_index: 0,
        status: "completed",
        logs: [%{"level" => "info", "message" => "Processing item", "timestamp" => "10:00:00"}]
      })

      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      assert html =~ "Processing item"
      assert html =~ "info"
    end

    test "shows error panel for a failed step", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)

      step_run_fixture(run, %{
        step_name: "fetch",
        step_index: 0,
        status: "failed",
        errors: %{"reason" => "timeout"}
      })

      {:ok, _view, html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      assert html =~ "Error"
      assert html =~ "timeout"
    end

    test "redirects to workflow detail if run_id is invalid", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      fake_run_id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: path}}} =
               live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{fake_run_id}")

      assert path == "/bo/workflows/#{workflow.id}"
    end
  end

  describe "live PubSub updates" do
    test "broadcasting {:run_updated, run} updates run status on page", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      updated_run = %{run | status: "completed"}
      Phoenix.PubSub.broadcast(Zaq.PubSub, "workflow_run:#{run.id}", {:run_updated, updated_run})

      html = render(view)
      assert html =~ "completed"
    end

    test "broadcasting {:step_updated, step_run} adds the step to the page", %{conn: conn} do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      step_run = step_run_fixture(run, %{step_name: "fetch", step_index: 0, status: "running"})

      Phoenix.PubSub.broadcast(Zaq.PubSub, "workflow_run:#{run.id}", {:step_updated, step_run})

      html = render(view)
      assert html =~ "fetch"
    end

    test "broadcasting {:step_updated, step_run} updates an existing step on the page", %{
      conn: conn
    } do
      workflow = workflow_fixture(%{nodes: [@valid_node]})
      run = run_fixture(workflow)
      step_run = step_run_fixture(run, %{step_name: "fetch", step_index: 0, status: "running"})

      {:ok, view, _html} = live(conn, ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}")

      updated_step = %{step_run | status: "completed"}

      Phoenix.PubSub.broadcast(
        Zaq.PubSub,
        "workflow_run:#{run.id}",
        {:step_updated, updated_step}
      )

      html = render(view)
      assert html =~ "completed"
    end
  end
end
