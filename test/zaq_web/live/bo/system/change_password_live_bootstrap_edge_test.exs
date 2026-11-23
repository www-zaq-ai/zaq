defmodule ZaqWeb.Live.BO.System.ChangePasswordLiveBootstrapEdgeTest do
  use ZaqWeb.ConnCase, async: true

  import Ecto.Query
  import Mox
  import Phoenix.LiveViewTest

  alias Zaq.Accounts
  alias Zaq.Accounts.User
  alias Zaq.Repo
  alias Zaq.UserPortal.ClientMock

  @portal_async_timeout 5_000

  setup :verify_on_exit!

  setup do
    Repo.delete_all(User)
    role = Repo.get_by!(Accounts.Role, name: "super_admin")

    user =
      Repo.insert!(%User{
        username: "admin",
        role_id: role.id,
        password_hash: "bootstrap",
        must_change_password: true
      })

    %{user: user}
  end

  test "registration persists but cannot renew a malformed bootstrap session", %{user: user} do
    nonce = Ecto.UUID.generate()
    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [bo_session_nonce: nonce])

    conn =
      build_conn()
      |> init_test_session(%{
        user_id: user.id,
        bo_session_nonce: nonce,
        bootstrap_browser: false
      })

    stub_metadata()

    {:ok, view, _html} = live(conn, ~p"/bo/change-password")
    submit_password(view)
    render_async(view, @portal_async_timeout)
    assert has_element?(view, "[phx-click='accept_portal_consent']")
    render_click(view, "decline_portal_consent")

    assert_redirect(view, ~p"/bo/login")
    registered = Accounts.get_user!(user.id)
    refute registered.must_change_password
    assert is_binary(registered.password_hash)
    assert registered.bo_session_nonce != nonce

    assert redirected_to(
             get(
               build_conn() |> init_test_session(%{user_id: user.id, bo_session_nonce: nonce}),
               ~p"/bo/dashboard"
             )
           ) == ~p"/bo/login"
  end

  test "malformed Portal welcome copy falls back after a successful handoff", %{user: user} do
    {browser, view} = setup_browser()

    expect(ClientMock, :fetch_onboarding, fn "free" ->
      {:ok,
       %{
         "plan_status" => "enabled",
         "available" => true,
         "metadata" => %{"post_accept" => "invalid copy"}
       }}
    end)

    expect(ClientMock, :onboard_user, fn _attrs -> {:ok, %{litellm_api_key: "test-key"}} end)
    submit_password(view)
    render_async(view, @portal_async_timeout)
    assert has_element?(view, "[phx-click='accept_portal_consent']")
    render_click(view, "accept_portal_consent")

    form = form(view, "#bootstrap-session-form")
    assert has_element?(view, "#bootstrap-session-form[phx-trigger-action]")
    renewed = follow_trigger_action(form, recycle(browser))
    nonce = Accounts.get_user!(user.id).bo_session_nonce
    assert is_binary(nonce)
    assert get_session(renewed, :bo_session_nonce) == nonce
    assert redirected_to(renewed) == ~p"/bo/change-password"

    {:ok, welcome_view, html} = live(recycle(renewed), ~p"/bo/change-password")
    assert html =~ "Activation email has been sent"
    refute html =~ "invalid copy"
    render_click(welcome_view, "close_post_accept_modal")
    assert_redirect(welcome_view, ~p"/bo/ingestion")
  end

  defp setup_browser do
    conn = get(build_conn(), ~p"/bo/bootstrap-login")
    conn = get(recycle(conn), redirected_to(conn))
    {:ok, view, _html} = live(conn)
    {conn, view}
  end

  defp submit_password(view) do
    render_submit(view, "change_password", %{
      "email" => "admin@example.com",
      "password" => "StrongPass1!",
      "password_confirmation" => "StrongPass1!"
    })
  end

  defp stub_metadata do
    expect(ClientMock, :fetch_onboarding, fn "free" ->
      {:ok,
       %{
         "plan_status" => "enabled",
         "available" => true,
         "metadata" => %{}
       }}
    end)
  end
end
