defmodule ZaqWeb.Live.DeviceCredentialsLiveTest do
  use ZaqWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  alias Zaq.Accounts.{People, PeopleAuth, PeoplePermissions}
  alias Zaq.Engine.Connect.{DeviceAttempt, DeviceAttempts}
  alias Zaq.Repo
  alias Zaq.System
  alias Zaq.TestSupport.ConnectOAuthAttemptHTTP

  setup {Req.Test, :verify_on_exit!}

  setup do
    original = Application.fetch_env(:zaq, :connect_oauth_http_client)
    Application.put_env(:zaq, :connect_oauth_http_client, ConnectOAuthAttemptHTTP)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:zaq, :connect_oauth_http_client, value)
        :error -> Application.delete_env(:zaq, :connect_oauth_http_client)
      end
    end)

    :ok
  end

  defp credential do
    {:ok, credential} =
      System.create_ai_provider_credential(%{
        name: "Device Codex",
        provider: "openai_codex",
        endpoint: "https://chatgpt.com/backend-api",
        auth_kind: "oauth2",
        personal_credential_policy: "required",
        metadata: %{
          "auth_profile" => "openai_chatgpt_codex",
          "authorize_url" => "https://auth.openai.com/oauth/authorize",
          "token_url" => "https://auth.openai.com/oauth/token",
          "client_id" => "codex-client"
        }
      })

    credential
  end

  defp expect_code(view) do
    Req.Test.allow(ConnectOAuthAttemptHTTP, self(), view.pid)

    Req.Test.expect(ConnectOAuthAttemptHTTP, fn conn ->
      Req.Test.json(conn, %{
        "device_auth_id" => "PRIVATE_DEVICE",
        "user_code" => "ABCD-EFGH",
        "interval" => 900
      })
    end)
  end

  defp worker(credential_id) do
    attempt = Repo.get_by!(DeviceAttempt, credential_id: credential_id)
    pid = :erlang.binary_to_term(attempt.worker_pid, [:safe])
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    {attempt, pid}
  end

  test "People adding modal starts device sign-in, retains observation on reopen and cancels", %{
    conn: conn
  } do
    {:ok, _} = PeoplePermissions.grant(:everyone, :access_profile)
    {:ok, _} = PeoplePermissions.grant(:everyone, :manage_credentials)

    {:ok, person} =
      People.create_person(%{full_name: "Device Person", email: "device-person@example.test"})

    {:ok, challenge} = PeopleAuth.issue_challenge(person, {127, 45, 1, 1})
    {:ok, %{token: token}} = PeopleAuth.verify_challenge(challenge.challenge_id, challenge.code)
    credential = credential()
    id = credential.connect_credential_id

    {:ok, view, _} =
      live(init_test_session(conn, %{person_session_token: token}), "/people/credentials")

    view |> element("#credential-edit-#{id}") |> render_click()
    expect_code(view)
    html = view |> element("#credential-device-#{id}") |> render_click()
    assert html =~ "ABCD-EFGH"
    refute html =~ "PRIVATE_DEVICE"

    assert has_element?(
             view,
             "#people-device-sign-in-open[target='_blank'][rel='noopener noreferrer']"
           )

    {attempt, _pid} = worker(id)
    timer = :sys.get_state(view.pid).socket.private.device_sign_in_polling
    view |> element("button[phx-click=close_credential_modal]", "Cancel") |> render_click()
    view |> element("#credential-edit-#{id}") |> render_click()
    assert :sys.get_state(view.pid).socket.private.device_sign_in_polling == timer
    assert has_element?(view, "#people-device-sign-in-code", "ABCD-EFGH")
    view |> element("button[phx-click=cancel_device]") |> render_click()
    assert has_element?(view, "#people-device-sign-in", "Device sign-in cancelled")
    assert Repo.get!(DeviceAttempt, attempt.id).device_material == nil
    assert :sys.get_state(view.pid).socket.private.device_sign_in_polling == nil
  end

  test "BO AI modal shows device code and explicit restart after worker interruption", %{
    conn: conn
  } do
    user = user_fixture(%{email: "device-admin@example.test", username: "device_admin"})
    {:ok, user} = Zaq.Accounts.change_password(user, %{password: "StrongPass1!"})
    credential = credential()

    {:ok, view, _} =
      live(init_test_session(conn, %{user_id: user.id}), "/bo/system-config?tab=ai_credentials")

    render_click(view, "edit_ai_credential", %{"id" => to_string(credential.id)})
    expect_code(view)
    view |> element("#ai-device-connect") |> render_click()
    assert has_element?(view, "#ai-device-sign-in-code", "ABCD-EFGH")

    assert has_element?(
             view,
             "#ai-device-sign-in-open[target='_blank'][rel='noopener noreferrer']"
           )

    {attempt, pid} = worker(credential.connect_credential_id)
    timer = :sys.get_state(view.pid).socket.private.device_sign_in_polling

    for _ <- 1..3 do
      render_click(view, "close_ai_credential_modal", %{})
      render_click(view, "edit_ai_credential", %{"id" => to_string(credential.id)})
      assert :sys.get_state(view.pid).socket.private.device_sign_in_polling == timer
    end

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    send(view.pid, {:ai_device_status, attempt.id, timer.generation})
    assert render(view) =~ "previous flow cannot resume"
    assert has_element?(view, "#ai-device-connect", "Sign in with device code")
    refute has_element?(view, "#ai-device-sign-in-code")
    assert :sys.get_state(view.pid).socket.private.device_sign_in_polling == nil
  end

  test "BO new credential form can initiate device sign-in before a global grant exists", %{
    conn: conn
  } do
    user = user_fixture(%{email: "device-new-admin@example.test", username: "device_new_admin"})
    {:ok, user} = Zaq.Accounts.change_password(user, %{password: "StrongPass1!"})

    {:ok, view, _} =
      live(init_test_session(conn, %{user_id: user.id}), "/bo/system-config?tab=ai_credentials")

    render_click(view, "new_ai_credential", %{})

    params = %{
      "name" => "New device Codex",
      "provider" => "openai_codex",
      "endpoint" => "https://chatgpt.com/backend-api",
      "auth_mode" => "oauth2",
      "oauth_behaviour" => "openai_chatgpt_codex",
      "metadata" => "{}",
      "personal_credential_policy" => "optional"
    }

    expect_code(view)

    render_submit(view, "save_ai_credential", %{
      "ai_credential" => params,
      "oauth_flow" => "device_code"
    })

    assert has_element?(view, "#ai-device-sign-in-code", "ABCD-EFGH")
    credential = System.get_ai_provider_credential_by_name("New device Codex")
    {attempt, _pid} = worker(credential.connect_credential_id)
    assert {:ok, %{status: "cancelled"}} = DeviceAttempts.cancel(attempt.id, :org)
  end

  test "BO cleanup before status refresh clears instructions, stops observation and permits restart",
       %{conn: conn} do
    user = user_fixture(%{email: "device-cleanup-admin@example.test", username: "device_cleanup"})
    {:ok, user} = Zaq.Accounts.change_password(user, %{password: "StrongPass1!"})
    credential = credential()

    {:ok, view, _} =
      live(init_test_session(conn, %{user_id: user.id}), "/bo/system-config?tab=ai_credentials")

    render_click(view, "edit_ai_credential", %{"id" => to_string(credential.id)})
    expect_code(view)
    view |> element("#ai-device-connect") |> render_click()
    {attempt, _pid} = worker(credential.connect_credential_id)
    timer = :sys.get_state(view.pid).socket.private.device_sign_in_polling
    assert {:ok, 1} = DeviceAttempts.reconcile(now: attempt.expires_at)

    send(view.pid, {:ai_device_status, attempt.id, timer.generation})

    assert has_element?(
             view,
             "#ai-device-sign-in",
             "This sign-in is no longer available. Start again."
           )

    refute has_element?(view, "#ai-device-sign-in-code")
    assert :sys.get_state(view.pid).socket.private.device_sign_in_polling == nil
    send(view.pid, {:ai_device_status, attempt.id, timer.generation})
    refute render(view) =~ "ABCD-EFGH"
    assert :sys.get_state(view.pid).socket.private.device_sign_in_polling == nil

    expect_code(view)
    view |> element("#ai-device-connect") |> render_click()
    {restarted, _pid} = worker(credential.connect_credential_id)
    refute restarted.id == attempt.id
    assert has_element?(view, "#ai-device-sign-in-code", "ABCD-EFGH")
  end
end
