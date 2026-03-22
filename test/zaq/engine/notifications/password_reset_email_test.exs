defmodule Zaq.Engine.Notifications.PasswordResetEmailTest do
  use Zaq.DataCase, async: true

  @moduletag capture_log: true

  alias Zaq.Engine.Notifications.PasswordResetEmail

  describe "deliver/2" do
    test "returns {:ok, _} when user has an email" do
      user = user_fixture(%{email: "reset@example.com"})
      assert {:ok, _} = PasswordResetEmail.deliver(user, "some-reset-token")
    end

    test "returns {:error, :no_email} when user email is nil" do
      user = %Zaq.Accounts.User{username: "noemail", email: nil}
      assert {:error, :no_email} = PasswordResetEmail.deliver(user, "token")
    end

    test "returns {:error, :no_email} when user email is empty string" do
      user = %Zaq.Accounts.User{username: "noemail", email: ""}
      assert {:error, :no_email} = PasswordResetEmail.deliver(user, "token")
    end
  end
end
