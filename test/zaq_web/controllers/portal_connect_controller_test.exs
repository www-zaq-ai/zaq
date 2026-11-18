defmodule ZaqWeb.PortalConnectControllerTest do
  use ZaqWeb.ConnCase, async: true
  use Oban.Testing, repo: Zaq.Repo

  import Mox
  import Phoenix.LiveViewTest
  alias Zaq.Accounts
  alias Zaq.Accounts.User
  alias Zaq.Repo
  alias Zaq.UserPortal.{ClientMock, InstallationWorker}

  setup :verify_on_exit!

  setup do
    Repo.delete_all(User)
    role = Repo.get_by!(Accounts.Role, name: "super_admin")

    user =
      Repo.insert!(%User{username: "admin", role_id: role.id, password_hash: "bootstrap"})

    %{user: user}
  end

  test "a clean URL shows only the password fields and does not redeem on GET", %{conn: conn} do
    conn = open_form(conn)
    html = html_response(conn, 200)
    assert html =~ ~s(name="password")
    assert html =~ ~s(name="password_confirmation")
    refute html =~ ~s(name="email")
    refute html =~ "one-use-test-token"
  end

  test "validation and rejected tokens leave the administrator pending", %{conn: conn, user: user} do
    conn = open_form(conn)

    invalid =
      post(recycle(conn), ~p"/bo/connect", %{password: "weak", password_confirmation: "x"})

    assert html_response(invalid, 422) =~ "Passwords do not match"

    expect(ClientMock, :connect, fn "one-use-test-token" -> {:error, {:portal_status, 410}} end)
    rejected = submit(invalid)
    assert html_response(rejected, 422) =~ "Get a new link"
    assert Accounts.get_user!(user.id).must_change_password
    refute_enqueued(worker: InstallationWorker)
  end

  test "registers locally and confirms only after the additional configuration is enqueued", %{
    conn: conn,
    user: user
  } do
    anonymous_bootstrap = get(build_conn(), ~p"/bo/bootstrap-login")

    expect(ClientMock, :connect, fn "one-use-test-token" ->
      {:ok,
       %{
         email: "admin@example.com",
         litellm_api_key: "router-key",
         confirmation_token: "ack-token",
         installation_url: "https://instance.example.com",
         deploy_on_own_cluster: false
       }}
    end)

    expect(ClientMock, :confirm_connection, fn "ack-token" ->
      assert_enqueued(
        worker: InstallationWorker,
        args: %{installation_url: "https://instance.example.com", deploy_on_own_cluster: false}
      )

      :ok
    end)

    conn = conn |> open_form() |> submit()
    status_path = redirected_to(conn)
    assert status_path =~ "/bo/connect/status/"
    assert get_session(conn, :user_id) == user.id
    assert Accounts.get_user!(user.id).portal_consent == "accepted"

    assert {:ok, %{email: "admin@example.com"}} =
             Accounts.authenticate_user("admin", "StrongPass1!")

    assert redirected_to(get(recycle(anonymous_bootstrap), ~p"/bo/dashboard")) == ~p"/bo/login"

    assert {:ok, view, html} = live(recycle(conn), status_path)
    assert html =~ "Applying installation settings"

    [job] = all_enqueued(worker: InstallationWorker)

    job
    |> Ecto.Changeset.change(
      state: "discarded",
      errors: [%{"error" => "** (Oban.PerformError) {:error, :disk}"}]
    )
    |> Repo.update!()

    send(view.pid, :refresh_installation)
    assert has_element?(view, "[role=alert]", "Could not enable Disk")
    assert has_element?(view, "button", "Retry configuration")

    job |> Ecto.Changeset.change(state: "completed") |> Repo.update!()
    send(view.pid, :refresh_installation)
    assert_redirect(view, ~p"/bo/ingestion")
  end

  defp open_form(conn) do
    conn = get(conn, ~p"/bo/connect?#{[portal_token: "one-use-test-token"]}")
    assert redirected_to(conn) == ~p"/bo/connect"
    get(recycle(conn), ~p"/bo/connect")
  end

  defp submit(conn) do
    post(recycle(conn), ~p"/bo/connect", %{
      password: "StrongPass1!",
      password_confirmation: "StrongPass1!"
    })
  end
end
