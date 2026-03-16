defmodule Zaq.Accounts.PasswordResetTest do
  use Zaq.DataCase

  alias Zaq.Accounts

  import Zaq.AccountsFixtures

  describe "get_user_by_email/1" do
    test "returns user when email matches" do
      user = user_fixture()
      {:ok, user} = Accounts.update_user(user, %{email: "test@example.com"})

      found = Accounts.get_user_by_email("test@example.com")
      assert found.id == user.id
      assert found.email == "test@example.com"
    end

    test "returns nil when no user has that email" do
      assert Accounts.get_user_by_email("nobody@example.com") == nil
    end

    test "returns nil for nil input" do
      assert Accounts.get_user_by_email(nil) == nil
    end
  end

  describe "generate_password_reset_token/1" do
    test "returns a non-empty binary token" do
      user = user_with_password()
      token = Accounts.generate_password_reset_token(user)
      assert is_binary(token) and token != ""
    end

    test "different users produce different tokens" do
      u1 = user_with_password()
      u2 = user_with_password()

      assert Accounts.generate_password_reset_token(u1) !=
               Accounts.generate_password_reset_token(u2)
    end
  end

  describe "verify_password_reset_token/1" do
    test "returns {:ok, user} for a valid token" do
      user = user_with_password()
      token = Accounts.generate_password_reset_token(user)

      assert {:ok, verified_user} = Accounts.verify_password_reset_token(token)
      assert verified_user.id == user.id
    end

    test "returns {:error, :invalid} for a tampered token" do
      assert {:error, _} = Accounts.verify_password_reset_token("not.a.real.token")
    end

    test "returns {:error, :invalid_token} after password has been changed" do
      user = user_with_password()
      token = Accounts.generate_password_reset_token(user)

      # Change password — invalidates the token
      {:ok, _} = Accounts.change_password(user, %{password: "NewerPass99!"})

      assert {:error, :invalid_token} = Accounts.verify_password_reset_token(token)
    end
  end

  # Helper: create a user that already has a password (needed for token secret derivation)
  defp user_with_password do
    user = user_fixture()
    {:ok, user} = Accounts.change_password(user, %{password: "InitialPass1!"})
    user
  end
end
