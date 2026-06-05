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

  describe "complete_bootstrap_onboarding/3 — unavailable (portal unreachable)" do
    test "records consent declined and scaffolds the keyless ZAQ Router credential" do
      # No ClientMock expectation: the portal must not be called when unreachable.
      user = user_fixture(%{email: "offline@zaq.local"})

      assert {:ok, updated} =
               Onboarding.complete_bootstrap_onboarding(
                 user,
                 %{password: "StrongPass1!"},
                 :unavailable
               )

      assert updated.portal_consent == "declined"
      refute updated.must_change_password

      credential = System.get_ai_provider_credential_by_name("ZAQ Router")
      assert credential.provider == "zaq_router"
      assert is_nil(credential.api_key)

      # Provider is listed, but not wired as the active model configuration.
      assert is_nil(System.get_llm_config().credential_id)
      assert is_nil(System.get_embedding_config().credential_id)
      assert is_nil(System.get_image_to_text_config().credential_id)
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

  describe "activate_portal/2" do
    test "provisions, marks consent accepted, and creates the credential" do
      expect(ClientMock, :onboard_user, fn "portal@zaq.local" ->
        {:ok, %{litellm_api_key: "sk-test-key"}}
      end)

      user = declined_user(%{email: "portal@zaq.local"})

      assert {:ok, updated} = Onboarding.activate_portal(user, nil)

      assert updated.portal_consent == "accepted"
      assert Accounts.get_user!(user.id).portal_consent == "accepted"

      assert %System.AIProviderCredential{name: "ZAQ Router"} =
               System.get_ai_provider_credential_by_name("ZAQ Router")
    end

    test "persists the entered email for an account with none on file" do
      expect(ClientMock, :onboard_user, fn "captured@zaq.local" ->
        {:ok, %{litellm_api_key: "sk-test-key"}}
      end)

      user = declined_user_without_email()

      assert {:ok, updated} = Onboarding.activate_portal(user, "  captured@zaq.local  ")

      assert updated.email == "captured@zaq.local"
      reloaded = Accounts.get_user!(user.id)
      assert reloaded.email == "captured@zaq.local"
      assert reloaded.portal_consent == "accepted"
    end

    test "does not persist the email or consent when provisioning fails" do
      expect(ClientMock, :onboard_user, fn _email -> {:error, :econnrefused} end)

      user = declined_user_without_email()

      assert {:error, :econnrefused} = Onboarding.activate_portal(user, "typo@zaq.local")

      reloaded = Accounts.get_user!(user.id)
      assert is_nil(reloaded.email)
      assert reloaded.portal_consent == "declined"
    end

    test "rejects an invalid email without calling the portal" do
      # No ClientMock expectation: reaching the portal would raise.
      user = declined_user_without_email()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Onboarding.activate_portal(user, "not-an-email")

      assert %{email: _} = errors_on(changeset)
      assert is_nil(Accounts.get_user!(user.id).email)
    end

    test "rejects a blank email when none is on file" do
      user = declined_user_without_email()

      assert {:error, %Ecto.Changeset{}} = Onboarding.activate_portal(user, "   ")
      assert Accounts.get_user!(user.id).portal_consent == "declined"
    end
  end

  defp declined_user(attrs) do
    user = user_fixture(attrs)

    {:ok, user} =
      user
      |> Accounts.User.portal_consent_changeset("declined")
      |> Repo.update()

    user
  end

  # Simulates a legacy user created before the email column existed: the row has
  # a NULL email (the column was added nullable in a later migration). These are
  # the only users the portal-activation email-capture path is built for.
  defp declined_user_without_email do
    user = declined_user(%{})
    Repo.update_all(from(u in Accounts.User, where: u.id == ^user.id), set: [email: nil])
    Accounts.get_user!(user.id)
  end
end
