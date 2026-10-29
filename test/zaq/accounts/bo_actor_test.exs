defmodule Zaq.Accounts.BOActorTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts.BOActor

  test "current-user lookup preserves the password-change exception" do
    user = user_fixture()
    actor = %{"user_id" => to_string(user.id)}
    assert BOActor.current_user(actor) == {:error, :unauthorized}
    assert {:ok, current} = BOActor.current_user(actor, allow_password_change: true)
    assert current.id == user.id
  end

  test "missing and deleted authenticated identities are denied" do
    user = user_fixture()
    assert {:ok, _} = Zaq.Accounts.delete_user(user)

    for actor <- [
          nil,
          %{},
          %{person_id: 1},
          %{user_id: nil},
          %{user_id: 0},
          %{user_id: -1},
          %{user_id: user.id}
        ] do
      assert BOActor.current_user(actor) == {:error, :unauthorized}
    end
  end
end
