defmodule Zaq.Accounts.UserNotificationChannelTest do
  use Zaq.DataCase, async: true

  @moduletag capture_log: true

  alias Zaq.Accounts.UserNotificationChannel
  alias Zaq.Repo

  defp insert_channel(user, attrs \\ %{}) do
    defaults = %{platform: "email", identifier: "u@example.com", is_preferred: false}

    %UserNotificationChannel{user_id: user.id}
    |> UserNotificationChannel.changeset(Map.merge(defaults, attrs))
    |> Repo.insert()
  end

  describe "unique constraint on [user_id, platform]" do
    test "allows one entry per platform per user" do
      user = user_fixture()
      assert {:ok, _} = insert_channel(user, %{platform: "email", identifier: "a@b.com"})
    end

    test "rejects duplicate [user_id, platform]" do
      user = user_fixture()
      assert {:ok, _} = insert_channel(user, %{platform: "email", identifier: "a@b.com"})

      assert {:error, changeset} =
               insert_channel(user, %{platform: "email", identifier: "c@d.com"})

      assert "has already been taken" in errors_on(changeset).user_id
    end

    test "allows same platform for different users" do
      user1 = user_fixture(%{username: "user1", email: "u1@test.com"})
      user2 = user_fixture(%{username: "user2", email: "u2@test.com"})

      assert {:ok, _} = insert_channel(user1, %{platform: "email"})
      assert {:ok, _} = insert_channel(user2, %{platform: "email"})
    end

    test "allows different platforms for the same user" do
      user = user_fixture()
      assert {:ok, _} = insert_channel(user, %{platform: "email"})
      assert {:ok, _} = insert_channel(user, %{platform: "mattermost", identifier: "U123"})
    end
  end
end
