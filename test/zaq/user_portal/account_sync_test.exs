defmodule Zaq.UserPortal.AccountSyncTest do
  use Zaq.DataCase, async: true

  import Mox
  import Zaq.AccountsFixtures

  alias Zaq.Accounts.User
  alias Zaq.Repo
  alias Zaq.System
  alias Zaq.UserPortal.AccountSync

  setup :verify_on_exit!

  describe "sync_email/1 — consent not accepted" do
    test "returns :ok without calling the portal when consent is nil" do
      user = user_fixture(%{username: "sync_no_consent"})
      assert user.portal_consent != "accepted"

      assert :ok = AccountSync.sync_email(user)
    end

    test "returns :ok without calling the portal when consent is declined" do
      user = user_fixture(%{username: "sync_declined"})
      {:ok, user} = Repo.update(User.portal_consent_changeset(user, "declined"))

      assert :ok = AccountSync.sync_email(user)
    end
  end

  describe "sync_email/1 — consent accepted" do
    test "calls update_email with the user's email and ZAQ Router api_key" do
      {:ok, _credential} =
        System.create_ai_provider_credential(%{
          name: "ZAQ Router",
          provider: "zaq_router",
          endpoint: "http://localhost:4020",
          api_key: "sk-router-key",
          sovereign: false
        })

      user = user_fixture(%{username: "sync_accepted", email: "sync@example.com"})
      {:ok, user} = Repo.update(User.portal_consent_changeset(user, "accepted"))

      expect(Zaq.UserPortal.ClientMock, :update_email, fn email, api_key ->
        assert email == "sync@example.com"
        assert api_key == "sk-router-key"
        :ok
      end)

      assert :ok = AccountSync.sync_email(user)
    end

    test "calls update_email with nil api_key when ZAQ Router credential is absent" do
      user = user_fixture(%{username: "sync_no_key", email: "nokey@example.com"})
      {:ok, user} = Repo.update(User.portal_consent_changeset(user, "accepted"))

      expect(Zaq.UserPortal.ClientMock, :update_email, fn _email, api_key ->
        assert api_key == nil
        {:error, :portal_sync_failed}
      end)

      assert {:error, :portal_sync_failed} = AccountSync.sync_email(user)
    end

    test "returns {:error, :email_taken} when the portal rejects with email_taken" do
      user = user_fixture(%{username: "sync_taken", email: "taken@example.com"})
      {:ok, user} = Repo.update(User.portal_consent_changeset(user, "accepted"))

      expect(Zaq.UserPortal.ClientMock, :update_email, fn _email, _api_key ->
        {:error, :email_taken}
      end)

      assert {:error, :email_taken} = AccountSync.sync_email(user)
    end
  end
end
