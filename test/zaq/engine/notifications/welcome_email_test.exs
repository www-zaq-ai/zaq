defmodule Zaq.Engine.Notifications.WelcomeEmailTest do
  use Zaq.DataCase, async: true

  @moduletag capture_log: true

  alias Zaq.Engine.Notifications.WelcomeEmail

  describe "deliver/1" do
    test "returns {:ok, _} for a user with an email address" do
      user = user_fixture(%{email: "welcome@example.com"})
      assert {:ok, _} = WelcomeEmail.deliver(user)
    end

    test "returns {:ok, :skipped} when user email is nil" do
      user = %Zaq.Accounts.User{username: "noemail", email: nil}
      assert {:ok, :skipped} = WelcomeEmail.deliver(user)
    end

    test "returns {:ok, :skipped} when user email is empty string" do
      user = %Zaq.Accounts.User{username: "noemail", email: ""}
      assert {:ok, :skipped} = WelcomeEmail.deliver(user)
    end
  end
end
