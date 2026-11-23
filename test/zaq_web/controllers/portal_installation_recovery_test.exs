defmodule ZaqWeb.PortalInstallationRecoveryTest do
  use ZaqWeb.ConnCase, async: false
  use Oban.Testing, repo: Zaq.Repo

  import Mox

  alias Zaq.Accounts.User
  alias Zaq.Repo
  alias Zaq.UserPortal.{ClientMock, InstallationWorker}

  setup :verify_on_exit!

  test "a failed enqueue leaves bootstrap open for a fresh Portal link", %{conn: conn} do
    Repo.delete_all(User)
    role = Repo.get_by!(Zaq.Accounts.Role, name: "super_admin")
    admin = Repo.insert!(%User{username: "admin", role_id: role.id, password_hash: "bootstrap"})

    expect(ClientMock, :connect, fn "first-link" -> connection("first-ack") end)

    worker = Oban.Worker.to_string(InstallationWorker)

    Repo.query!("""
    ALTER TABLE oban_jobs ADD CONSTRAINT reject_portal_installation
    CHECK (worker <> '#{worker}') NOT VALID
    """)

    failed = submit_link(conn, "first-link")

    assert html_response(failed, 422) =~ "Return to Portal and request a new connection link"
    assert get_session(failed, :user_id) == nil
    assert get_session(failed, :portal_setup) == nil
    refute_enqueued(worker: InstallationWorker)
    assert Repo.reload!(admin) == admin
    refute Zaq.System.get_ai_provider_credential_by_name("ZAQ Router")

    Repo.query!("ALTER TABLE oban_jobs DROP CONSTRAINT reject_portal_installation")

    expect(ClientMock, :connect, fn "fresh-link" -> connection("fresh-ack") end)

    expect(ClientMock, :confirm_connection, fn "fresh-ack" ->
      assert Repo.reload!(admin).portal_consent == "accepted"
      assert Zaq.System.get_ai_provider_credential_by_name("ZAQ Router")
      assert [_job] = all_enqueued(worker: InstallationWorker)
      :ok
    end)

    result = submit_link(recycle(failed), "fresh-link")

    [job] = all_enqueued(worker: InstallationWorker)
    assert redirected_to(result) == ~p"/bo/connect/status/#{job.id}"
    assert get_session(result, :user_id) == admin.id

    assert job.args == %{
             "installation_url" => "https://instance.example.com",
             "deploy_on_own_cluster" => false
           }

    assert job.meta == %{"admin_id" => admin.id}

    assert {:ok, %{email: "admin@example.com", must_change_password: false}} =
             Zaq.Accounts.authenticate_user("admin", "StrongPass1!")

    assert redirected_to(get(build_conn(), ~p"/bo/connect?#{[portal_token: "another-link"]}")) ==
             ~p"/bo/login"
  end

  defp submit_link(conn, token) do
    conn
    |> get(~p"/bo/connect?#{[portal_token: token]}")
    |> recycle()
    |> post(~p"/bo/connect", %{password: "StrongPass1!", password_confirmation: "StrongPass1!"})
  end

  defp connection(confirmation_token) do
    {:ok,
     %{
       email: "admin@example.com",
       litellm_api_key: "router-key",
       confirmation_token: confirmation_token,
       installation_url: "https://instance.example.com",
       deploy_on_own_cluster: false
     }}
  end
end
