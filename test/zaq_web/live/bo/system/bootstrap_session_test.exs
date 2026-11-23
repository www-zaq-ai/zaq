defmodule ZaqWeb.Live.BO.System.BootstrapSessionTest do
  use ZaqWeb.ConnCase, async: true

  import Mox
  import Phoenix.LiveViewTest

  alias Zaq.Accounts
  alias Zaq.Repo
  alias Zaq.UserPortal.ClientMock

  @portal_async_timeout 5_000

  setup :verify_on_exit!

  setup do
    Repo.delete_all(Accounts.User)
    role = Repo.get_by!(Accounts.Role, name: "super_admin")

    user =
      Repo.insert!(%Accounts.User{
        username: "admin",
        role_id: role.id,
        password_hash: "bootstrap"
      })

    %{user: user}
  end

  for outcome <- [:accepted, :declined, :unavailable, :provisioning_failed] do
    @outcome outcome

    test "only the completing browser keeps its session (#{outcome})", %{user: user} do
      {winner, view} = setup_browser()
      {earlier, earlier_view} = setup_browser()
      stub_portal(@outcome)

      submit_password(view)
      render_async(view, @portal_async_timeout)
      choose_consent(view, @outcome)

      form = form(view, "#bootstrap-session-form")
      assert has_element?(view, "#bootstrap-session-form[phx-trigger-action]")

      rejected = follow_trigger_action(form, recycle(earlier))
      assert redirected_to(rejected) == ~p"/bo/login"

      renewed = follow_trigger_action(form, recycle(winner))
      nonce = Accounts.get_user!(user.id).bo_session_nonce
      assert is_binary(nonce)
      assert get_session(renewed, :bo_session_nonce) == nonce

      finish_onboarding(renewed, @outcome)
      assert html_response(get(recycle(renewed), ~p"/bo/dashboard"), 200)
      assert redirected_to(get(recycle(earlier), ~p"/bo/dashboard")) == ~p"/bo/login"
      assert {:error, {:redirect, %{to: "/bo/login"}}} = live(recycle(earlier), ~p"/bo/dashboard")

      # The earlier socket was already connected before registration completed.
      submit_password(earlier_view)
      render_async(earlier_view, @portal_async_timeout)
      refute has_element?(earlier_view, "#bootstrap-session-form")
      assert Accounts.get_user!(user.id).bo_session_nonce == nonce
    end
  end

  test "an invalid registration leaves the bootstrap session unchanged", %{user: user} do
    {_conn, view} = setup_browser()
    stub_portal(:unavailable)

    submit_password(view, "weak1!")
    render_async(view, @portal_async_timeout)

    assert Accounts.get_user!(user.id).must_change_password
    assert is_nil(Accounts.get_user!(user.id).bo_session_nonce)
    refute has_element?(view, "#bootstrap-session-form")
  end

  test "registration revokes earlier bootstrap sessions after another user is provisioned", %{
    user: user
  } do
    {winner, view} = setup_browser()
    {earlier, _earlier_view} = setup_browser()
    stub_portal(:unavailable)

    Repo.insert!(%Accounts.User{
      username: "operator",
      role_id: user.role_id,
      password_hash: "unused"
    })

    submit_password(view)
    render_async(view, @portal_async_timeout)

    assert has_element?(view, "#bootstrap-session-form[phx-trigger-action]")
    renewed = follow_trigger_action(form(view, "#bootstrap-session-form"), recycle(winner))
    assert html_response(get(recycle(renewed), ~p"/bo/dashboard"), 200)
    assert redirected_to(get(recycle(earlier), ~p"/bo/dashboard")) == ~p"/bo/login"
  end

  defp setup_browser do
    conn = get(build_conn(), ~p"/bo/bootstrap-login")
    conn = get(recycle(conn), redirected_to(conn))
    {:ok, view, _html} = live(conn)
    {conn, view}
  end

  defp submit_password(view, password \\ "StrongPass1!") do
    render_submit(view, "change_password", %{
      "email" => "admin@example.com",
      "password" => password,
      "password_confirmation" => password
    })
  end

  defp stub_portal(:unavailable),
    do: expect(ClientMock, :fetch_onboarding, fn "free" -> :unavailable end)

  defp stub_portal(outcome) do
    expect(ClientMock, :fetch_onboarding, fn "free" ->
      {:ok,
       %{
         "plan_status" => "enabled",
         "available" => true,
         "metadata" => %{"post_accept" => %{"title" => "Welcome to ZAQ"}}
       }}
    end)

    case outcome do
      :accepted ->
        expect(ClientMock, :onboard_user, fn _ -> {:ok, %{litellm_api_key: "test-key"}} end)

      :provisioning_failed ->
        expect(ClientMock, :onboard_user, fn _ -> {:error, :econnrefused} end)

      :declined ->
        :ok
    end
  end

  defp choose_consent(_view, :unavailable), do: :ok
  defp choose_consent(view, :declined), do: render_click(view, "decline_portal_consent")
  defp choose_consent(view, _outcome), do: render_click(view, "accept_portal_consent")

  defp finish_onboarding(conn, :accepted) do
    assert redirected_to(conn) == ~p"/bo/change-password"
    {:ok, view, html} = live(recycle(conn), ~p"/bo/change-password")
    assert html =~ "Welcome to ZAQ"
    render_click(view, "close_post_accept_modal")
    assert_redirect(view, ~p"/bo/ingestion")
  end

  defp finish_onboarding(conn, _outcome), do: assert(redirected_to(conn) == ~p"/bo/dashboard")
end
