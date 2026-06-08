defmodule Zaq.UserPortal.AccountSyncTest do
  use Zaq.DataCase, async: true

  import Mox
  import Zaq.AccountsFixtures

  alias Zaq.Accounts.User
  alias Zaq.Repo
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
    test "calls update_email with the user's email" do
      user = user_fixture(%{username: "sync_accepted", email: "sync@example.com"})
      {:ok, user} = Repo.update(User.portal_consent_changeset(user, "accepted"))

      expect(Zaq.UserPortal.ClientMock, :update_email, fn email ->
        assert email == "sync@example.com"
        :ok
      end)

      assert :ok = AccountSync.sync_email(user)
    end

    test "returns {:error, :email_taken} when the portal rejects with email_taken" do
      user = user_fixture(%{username: "sync_taken", email: "taken@example.com"})
      {:ok, user} = Repo.update(User.portal_consent_changeset(user, "accepted"))

      expect(Zaq.UserPortal.ClientMock, :update_email, fn _email ->
        {:error, :email_taken}
      end)

      assert {:error, :email_taken} = AccountSync.sync_email(user)
    end
  end
end
