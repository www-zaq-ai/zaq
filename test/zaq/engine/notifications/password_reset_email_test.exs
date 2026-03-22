defmodule Zaq.Engine.Notifications.PasswordResetEmailTest do
  use Zaq.DataCase, async: true

  @moduletag capture_log: true

  alias Zaq.Engine.Notifications.PasswordResetEmail

  describe "deliver/2" do
    test "returns {:ok, _} when user has an email" do
      user = user_fixture(%{email: "reset@example.com"})
      assert {:ok, _} = PasswordResetEmail.deliver(user, "some-reset-token")
    end

    test "returns {:ok, :skipped} when user email is nil" do
      user = %Zaq.Accounts.User{username: "noemail", email: nil}
      assert {:ok, :skipped} = PasswordResetEmail.deliver(user, "token")
    end

    test "returns {:ok, :skipped} when user email is empty string" do
      user = %Zaq.Accounts.User{username: "noemail", email: ""}
      assert {:ok, :skipped} = PasswordResetEmail.deliver(user, "token")
    end
  end
end
