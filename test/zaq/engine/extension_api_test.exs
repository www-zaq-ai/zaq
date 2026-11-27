defmodule Zaq.Engine.ExtensionApiTest do
  use Zaq.DataCase, async: true

  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Engine.Extension.Health
  alias Zaq.Event
  alias Zaq.NodeRouter

  test "authenticated confidential Engine Event returns only a connectivity snapshot" do
    user = user_fixture()
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    event =
      Event.new(%{}, :engine,
        actor: %{user_id: user.id},
        opts: [action: :extension_health, confidential: true]
      )

    assert %{response: {:ok, %Health{status: :unconfigured}}} = NodeRouter.dispatch(event)
  end

  test "missing actor, deleted actor and non-confidential reads cannot inspect health" do
    for actor <- [nil, %{}, %{person_id: nil}, %{user_id: -1}] do
      event =
        Event.new(%{}, :engine,
          actor: actor,
          opts: [action: :extension_health, confidential: true]
        )

      assert %{response: {:error, :unauthorized}} = NodeRouter.dispatch(event)
    end

    user = user_fixture()
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    event = Event.new(%{}, :engine, actor: %{user_id: user.id}, opts: [action: :extension_health])
    assert %{response: {:error, :unauthorized}} = NodeRouter.dispatch(event)
  end
end
