defmodule Zaq.UserPortal.ConnectBootstrapTest do
  use Zaq.DataCase, async: false
  use Oban.Testing, repo: Zaq.Repo

  import Mox
  alias Zaq.Accounts
  alias Zaq.Accounts.User
  alias Zaq.Repo
  alias Zaq.System
  alias Zaq.UserPortal.{ClientMock, InstallationWorker, Onboarding}

  setup :verify_on_exit!

  setup do
    Repo.delete_all(User)
    role = Repo.get_by!(Accounts.Role, name: "super_admin")
    admin = Repo.insert!(%User{username: "admin", role_id: role.id, password_hash: "bootstrap"})
    %{admin: admin}
  end

  test "rejects invalid registration without changing the bootstrap admin", %{admin: admin} do
    expect(ClientMock, :connect, fn "portal-token" -> {:ok, connection()} end)

    assert {:error, :registration_failed} =
             Onboarding.connect_bootstrap(admin, "portal-token", "weak")

    assert_admin_unchanged(admin)
    refute_enqueued(worker: InstallationWorker)
  end

  test "rejects installation URLs with query strings before registering", %{admin: admin} do
    expect(ClientMock, :connect, fn "portal-token" ->
      {:ok, connection(%{installation_url: "https://instance.example.com/path?query=value"})}
    end)

    assert {:error, :invalid_portal_response} =
             Onboarding.connect_bootstrap(admin, "portal-token", "StrongPass1!")

    assert_admin_unchanged(admin)
    refute_enqueued(worker: InstallationWorker)
  end

  test "does not connect when the caller is not the pending bootstrap admin", %{admin: admin} do
    other_user = %User{id: admin.id + 1}

    assert {:error, :bootstrap_unavailable} =
             Onboarding.connect_bootstrap(other_user, "portal-token", "StrongPass1!")

    assert_admin_unchanged(admin)
    refute_enqueued(worker: InstallationWorker)
  end

  test "does not connect when the bootstrap admin is no longer pristine", %{admin: admin} do
    Repo.update_all(from(user in User, where: user.id == ^admin.id),
      set: [must_change_password: false]
    )

    admin = Accounts.get_user!(admin.id)

    assert {:error, :bootstrap_unavailable} =
             Onboarding.connect_bootstrap(admin, "portal-token", "StrongPass1!")

    assert_admin_unchanged(admin)
    refute_enqueued(worker: InstallationWorker)
  end

  test "rolls registration back when Oban rejects the installation job", %{admin: admin} do
    Repo.query!(
      "ALTER TABLE oban_jobs ADD CONSTRAINT priority_range CHECK (worker <> 'Zaq.UserPortal.InstallationWorker' OR priority < 0) NOT VALID"
    )

    expect(ClientMock, :connect, fn "portal-token" -> {:ok, connection()} end)

    assert {:error, :installation_enqueue_failed} =
             Onboarding.connect_bootstrap(admin, "portal-token", "StrongPass1!")

    assert_admin_unchanged(admin)
    refute_enqueued(worker: InstallationWorker)
  end

  test "rolls registration back when local credential provisioning fails", %{admin: admin} do
    previous_config = Application.get_env(:zaq, Zaq.System.SecretConfig, [])
    Application.put_env(:zaq, Zaq.System.SecretConfig, encryption_key: nil, key_id: "v1")
    on_exit(fn -> Application.put_env(:zaq, Zaq.System.SecretConfig, previous_config) end)

    expect(ClientMock, :connect, fn "portal-token" -> {:ok, connection()} end)

    assert {:error, :local_setup_failed} =
             Onboarding.connect_bootstrap(admin, "portal-token", "StrongPass1!")

    assert_admin_unchanged(admin)
    assert is_nil(System.get_ai_provider_credential_by_name("ZAQ Router"))
    refute_enqueued(worker: InstallationWorker)
  end

  defp assert_admin_unchanged(admin) do
    persisted_admin = Accounts.get_user!(admin.id)

    assert persisted_admin.email == admin.email
    assert persisted_admin.bo_session_nonce == admin.bo_session_nonce
    assert persisted_admin.portal_consent == admin.portal_consent
    assert persisted_admin.password_hash == admin.password_hash
    assert persisted_admin.must_change_password == admin.must_change_password
  end

  defp connection(overrides \\ %{}) do
    Map.merge(
      %{
        email: "admin@example.com",
        litellm_api_key: "router-key",
        confirmation_token: "ack-token",
        installation_url: "https://instance.example.com",
        deploy_on_own_cluster: false
      },
      overrides
    )
  end
end
