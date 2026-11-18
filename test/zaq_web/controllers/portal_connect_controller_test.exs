defmodule ZaqWeb.PortalConnectControllerTestFixtures do
  def success_response(attrs \\ %{}) do
    Map.merge(
      %{
        email: "admin@example.com",
        litellm_api_key: "router-key",
        confirmation_token: "ack-token",
        installation_url: "https://instance.example.com",
        deploy_on_own_cluster: false
      },
      attrs
    )
  end
end

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
    assert is_nil(Accounts.get_user!(user.id).bo_session_nonce)
    refute_enqueued(worker: InstallationWorker)
  end

  test "password feedback reports the maximum length without echoing the password", %{conn: conn} do
    password = "StrongPass1!" <> String.duplicate("a", 61)

    result =
      conn
      |> open_form()
      |> recycle()
      |> post(~p"/bo/connect", %{password: password, password_confirmation: password})

    html = html_response(result, 422)
    assert html =~ "No more than 72 characters"
    refute html =~ password
    refute_enqueued(worker: InstallationWorker)
  end

  test "empty and oversized setup tokens clear the setup session", %{conn: conn} do
    forbid_portal_calls()

    for token <- ["", String.duplicate("a", 2049)] do
      conn = conn |> open_form() |> recycle()
      result = get(conn, ~p"/bo/connect?#{[portal_token: token]}")
      assert redirected_to(result) == ~p"/bo/login"
      refute get_session(result, :portal_setup)
    end
  end

  test "missing and stale setup state redirects to login without redeeming", %{conn: conn} do
    forbid_portal_calls()

    missing_form = get(conn, ~p"/bo/connect")
    assert redirected_to(missing_form) == ~p"/bo/login"

    missing_submit =
      post(recycle(conn), ~p"/bo/connect", %{
        password: "StrongPass1!",
        password_confirmation: "StrongPass1!"
      })

    assert redirected_to(missing_submit) == ~p"/bo/login"
    refute get_session(missing_submit, :portal_setup)

    stale = open_form(conn)
    role = Repo.get_by!(Accounts.Role, name: "super_admin")
    Repo.insert!(%User{username: "second-admin", role_id: role.id, password_hash: "bootstrap"})
    stale = submit(stale)

    assert redirected_to(stale) == ~p"/bo/login"
    refute get_session(stale, :portal_setup)
    assert Repo.get_by!(User, username: "admin").must_change_password
    refute_enqueued(worker: InstallationWorker)
  end

  test "invalid installation URLs are rejected before registration", %{conn: conn, user: user} do
    forbid_portal_calls()

    expect(ClientMock, :connect, fn "one-use-test-token" ->
      {:ok,
       ZaqWeb.PortalConnectControllerTestFixtures.success_response(%{
         installation_url: "https://instance.example.com/?invalid=yes"
       })}
    end)

    result = conn |> open_form() |> submit()
    assert html_response(result, 422) =~ "incomplete or invalid setup details"
    assert Accounts.get_user!(user.id).must_change_password
    refute_enqueued(worker: InstallationWorker)
  end

  test "malformed email is rejected during registration", %{conn: conn, user: user} do
    forbid_portal_calls()

    expect(ClientMock, :connect, fn "one-use-test-token" ->
      {:ok, ZaqWeb.PortalConnectControllerTestFixtures.success_response(%{email: "not-an-email"})}
    end)

    result = conn |> open_form() |> submit()
    assert html_response(result, 422) =~ "could not complete registration"
    assert Accounts.get_user!(user.id).must_change_password
    refute_enqueued(worker: InstallationWorker)
  end

  test "Portal unavailability preserves the setup session for retry", %{conn: conn, user: user} do
    forbid_portal_calls()

    expect(ClientMock, :connect, fn "one-use-test-token" -> {:error, :portal_unavailable} end)
    result = conn |> open_form() |> submit()
    assert html_response(result, 422) =~ "Could not connect to the Portal. Try again."
    assert get_session(result, :portal_setup)
    assert Accounts.get_user!(user.id).must_change_password
    refute_enqueued(worker: InstallationWorker)
  end

  test "a failed Portal acknowledgement warns without removing the queued job", %{conn: conn} do
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
      {:error, :invalid_portal_response}
    end)

    result = conn |> open_form() |> submit()
    [job] = all_enqueued(worker: InstallationWorker)
    assert redirected_to(result) == ~p"/bo/connect/status/#{job.id}"

    assert {:ok, _view, html} = live(recycle(result), redirected_to(result))
    assert html =~ "the Portal did not acknowledge the connection"
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

  defp forbid_portal_calls do
    stub(ClientMock, :connect, fn _ -> flunk("unexpected Portal redemption") end)
    stub(ClientMock, :confirm_connection, fn _ -> flunk("unexpected Portal confirmation") end)
  end

  defp submit(conn) do
    post(recycle(conn), ~p"/bo/connect", %{
      password: "StrongPass1!",
      password_confirmation: "StrongPass1!"
    })
  end
end

defmodule ZaqWeb.PortalConnectControllerLocalSetupFailureTest do
  use ZaqWeb.ConnCase, async: false
  use Oban.Testing, repo: Zaq.Repo

  import Mox
  alias Zaq.Accounts
  alias Zaq.Accounts.User
  alias Zaq.Agent
  alias Zaq.Agent.ZAQRouter
  alias Zaq.Repo
  alias Zaq.UserPortal.{ClientMock, InstallationWorker}

  setup :verify_on_exit!

  setup do
    stub(ClientMock, :connect, fn _ -> flunk("unexpected Portal redemption") end)
    stub(ClientMock, :confirm_connection, fn _ -> flunk("unexpected Portal confirmation") end)

    Repo.delete_all(User)
    role = Repo.get_by!(Accounts.Role, name: "super_admin")
    user = Repo.insert!(%User{username: "admin", role_id: role.id, password_hash: "bootstrap"})
    %{user: user}
  end

  test "local setup failure rolls back registration, consent, and installation job", %{
    conn: conn,
    user: user
  } do
    snapshot = LLMDB.Store.snapshot()
    previous_opts = LLMDB.Store.last_opts()
    on_exit(fn -> LLMDB.Store.put!(snapshot, previous_opts) end)

    opts = ZAQRouter.llmdb_opts()
    custom = opts[:custom]
    model_id = ZAQRouter.default_chat_model()
    custom = update_in(custom, [:zaq_router, :models], &Map.delete(&1, model_id))
    assert {:ok, _} = LLMDB.load(Keyword.put(opts, :custom, custom))
    assert {:error, _} = LLMDB.model(:zaq_router, model_id)

    expect(ClientMock, :connect, fn "one-use-test-token" ->
      {:ok, ZaqWeb.PortalConnectControllerTestFixtures.success_response()}
    end)

    form = open_form(conn)
    result = submit(form)

    assert html_response(result, 422) =~
             "ZAQ couldn’t finish local setup. Check your configuration and request a new connection link."

    assert is_nil(get_session(result, :portal_setup))
    assert Accounts.get_user!(user.id).must_change_password
    assert is_nil(Accounts.get_user!(user.id).email)
    assert is_nil(Accounts.get_user!(user.id).portal_consent)
    assert {:error, :agent_not_found} = Agent.get_agent_by_name("ZAQ Assistant")
    refute_enqueued(worker: InstallationWorker)
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
