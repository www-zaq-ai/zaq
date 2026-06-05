defmodule Zaq.UserPortal.OnboardingTest do
  use Zaq.DataCase, async: true

  import Mox
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.System
  alias Zaq.UserPortal.ClientMock
  alias Zaq.UserPortal.Onboarding

  setup :verify_on_exit!

  describe "complete_bootstrap_onboarding/3 — accepted" do
    test "provisions the portal, records consent, and creates the credential" do
      expect(ClientMock, :onboard_user, fn "admin@zaq.local" ->
        {:ok, %{litellm_api_key: "sk-test-key"}}
      end)

      user = user_fixture(%{email: "admin@zaq.local"})

      assert {:ok, updated} =
               Onboarding.complete_bootstrap_onboarding(
                 user,
                 %{password: "StrongPass1!"},
                 :accepted
               )

      assert updated.portal_consent == "accepted"
      refute updated.must_change_password

      assert %System.AIProviderCredential{name: "ZAQ Router"} =
               System.get_ai_provider_credential_by_name("ZAQ Router")
    end

    test "reverts consent to declined and returns an error when the portal fails" do
      expect(ClientMock, :onboard_user, fn _email -> {:error, :econnrefused} end)

      user = user_fixture(%{email: "offline@zaq.local"})

      assert {:error, {:provisioning_failed, :econnrefused}} =
               Onboarding.complete_bootstrap_onboarding(
                 user,
                 %{password: "StrongPass1!"},
                 :accepted
               )

      reloaded = Accounts.get_user!(user.id)
      # Registration still persisted, consent reverted so the dashboard retry is valid.
      assert reloaded.portal_consent == "declined"
      refute reloaded.must_change_password
      refute System.get_ai_provider_credential_by_name("ZAQ Router")
    end

    test "reverts consent when credential creation fails after portal onboarding" do
      prev_secret = Application.get_env(:zaq, Zaq.System.SecretConfig, [])
      Application.put_env(:zaq, Zaq.System.SecretConfig, encryption_key: nil, key_id: "v1")
      on_exit(fn -> Application.put_env(:zaq, Zaq.System.SecretConfig, prev_secret) end)

      expect(ClientMock, :onboard_user, fn _email ->
        {:ok, %{litellm_api_key: "sk-test-key"}}
      end)

      user = user_fixture(%{email: "admin@zaq.local"})

      assert {:error, {:provisioning_failed, %Ecto.Changeset{}}} =
               Onboarding.complete_bootstrap_onboarding(
                 user,
                 %{password: "StrongPass1!"},
                 :accepted
               )

      assert Accounts.get_user!(user.id).portal_consent == "declined"
    end
  end

  describe "complete_bootstrap_onboarding/3 — declined" do
    test "records consent without calling the portal or creating a credential" do
      # No ClientMock expectation: a portal call would raise.
      user = user_fixture(%{email: "person@example.com"})

      assert {:ok, updated} =
               Onboarding.complete_bootstrap_onboarding(
                 user,
                 %{password: "StrongPass1!"},
                 :declined
               )

      assert updated.portal_consent == "declined"
      refute updated.must_change_password
      refute System.get_ai_provider_credential_by_name("ZAQ Router")
    end
  end

  describe "complete_bootstrap_onboarding/3 — invalid registration" do
    test "returns the changeset error without touching the portal" do
      user = user_fixture()
      Repo.update_all(from(u in Accounts.User, where: u.id == ^user.id), set: [email: nil])
      user = Accounts.get_user!(user.id)

      assert {:error, %Ecto.Changeset{}} =
               Onboarding.complete_bootstrap_onboarding(
                 user,
                 %{password: "StrongPass1!"},
                 :accepted
               )
    end
  end
end
