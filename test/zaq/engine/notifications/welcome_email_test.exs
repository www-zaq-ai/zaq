defmodule Zaq.Engine.Notifications.WelcomeEmailTest do
  use Zaq.DataCase, async: true

  @moduletag capture_log: true

  alias Zaq.Engine.Notifications.WelcomeEmail

  describe "deliver/1" do
    test "delivers successfully to a user with an email address" do
      user = user_fixture(%{email: "welcome@example.com"})
      assert :ok = WelcomeEmail.deliver(user)
    end

    test "delivers successfully when email delivery is not configured (falls back to test adapter)" do
      # In test env the Swoosh test adapter is used — always succeeds regardless of delivery_opts
      user = user_fixture(%{email: "another@example.com"})
      assert :ok = WelcomeEmail.deliver(user)
    end
  end
end
