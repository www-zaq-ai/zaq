defmodule ZaqWeb.Live.BO.System.PortalConnectStatusLiveTest do
  use ZaqWeb.ConnCase, async: true

  import Ecto.Changeset
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Repo
  alias Zaq.UserPortal.InstallationWorker

  test "retrying a discarded Global URL failure makes the job available", %{conn: conn} do
    user = super_admin_fixture(%{must_change_password: false})
    job = installation_job(user, "discarded", ":global_url")

    {:ok, view, _html} = live(authenticated(conn, user), status_path(job))

    assert has_element?(view, "[role=alert]", "Could not save the Global URL.")
    assert has_element?(view, "button", "Retry configuration")

    html = view |> element("button", "Retry configuration") |> render_click()
    retried = Repo.get!(Oban.Job, job.id)

    assert retried.state == "available"
    assert retried.attempt < retried.max_attempts
    assert html =~ "Applying installation settings…"
    refute html =~ "Retry configuration"
    # Oban retains failure history when it retries a job.
    assert has_element?(view, "[role=alert]", "Could not save the Global URL.")
  end

  test "retry does not change a failed job that became scheduled", %{conn: conn} do
    user = super_admin_fixture(%{must_change_password: false})
    job = installation_job(user, "discarded", ":global_url")
    {:ok, view, _html} = live(authenticated(conn, user), status_path(job))

    scheduled_at = DateTime.add(DateTime.utc_now(), 3_600, :second)

    job
    |> change(state: "scheduled", scheduled_at: scheduled_at)
    |> Repo.update!()

    view |> element("button", "Retry configuration") |> render_click()

    persisted = Repo.get!(Oban.Job, job.id)
    assert persisted.state == "scheduled"
    assert DateTime.compare(persisted.scheduled_at, scheduled_at) == :eq
  end

  test "refreshing after the job is deleted redirects to the dashboard", %{conn: conn} do
    user = super_admin_fixture(%{must_change_password: false})
    job = installation_job(user, "discarded", ":global_url")
    {:ok, view, _html} = live(authenticated(conn, user), status_path(job))

    Repo.delete!(job)
    send(view.pid, :refresh_installation)

    assert_redirect(view, ~p"/bo/dashboard")
  end

  test "an already completed job redirects during the initial HTTP request", %{conn: conn} do
    user = super_admin_fixture(%{must_change_password: false})
    job = installation_job(user, "completed")

    response = get(authenticated(conn, user), status_path(job))

    assert redirected_to(response) == ~p"/bo/ingestion"
  end

  test "cancelled jobs show the generic installation error", %{conn: conn} do
    user = super_admin_fixture(%{must_change_password: false})
    job = installation_job(user, "cancelled", ":invalid_installation")

    {:ok, view, _html} = live(authenticated(conn, user), status_path(job))

    assert has_element?(view, "[role=alert]", "ZAQ could not apply the installation settings.")
  end

  defp installation_job(user, state, error \\ nil) do
    args = %{installation_url: "https://instance.example.com", deploy_on_own_cluster: false}
    changeset = InstallationWorker.new(args, meta: %{"admin_id" => user.id})
    job = Oban.insert!(changeset)

    changes = %{state: state}

    changes =
      if state == "discarded", do: Map.put(changes, :attempt, job.max_attempts), else: changes

    changes = if error, do: Map.put(changes, :errors, [%{"error" => error}]), else: changes

    job
    |> change(changes)
    |> Repo.update!()
  end

  defp authenticated(conn, user), do: init_test_session(conn, %{user_id: user.id})
  defp status_path(job), do: ~p"/bo/connect/status/#{job.id}"
end
