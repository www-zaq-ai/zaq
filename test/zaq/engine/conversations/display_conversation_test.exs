defmodule Zaq.Engine.Conversations.DisplayConversationTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Api
  alias Zaq.Engine.Conversations
  alias Zaq.Event

  test "resolution and history share current ownership and unexpired share authorization" do
    owner = user_fixture()
    viewer = user_fixture()

    {:ok, conversation} =
      Conversations.create_conversation(%{user_id: owner.id, channel_type: "bo"})

    assert {:ok, ^conversation} =
             Conversations.resolve_display_conversation(conversation.id, owner)

    assert {:error, :not_found} =
             Conversations.resolve_display_conversation(conversation.id, viewer)

    {:ok, share} =
      Conversations.share_conversation(conversation, %{
        shared_with_user_id: viewer.id,
        permission: "read"
      })

    assert {:ok, ^conversation} =
             Conversations.resolve_display_conversation(conversation.id, viewer)

    assert {:ok, %{conversation: ^conversation}} =
             Conversations.display_history(conversation.id, viewer)

    share
    |> Ecto.Changeset.change(
      expires_at: DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)
    )
    |> Repo.update!()

    assert {:error, :not_found} =
             Conversations.resolve_display_conversation(conversation.id, viewer)

    assert {:error, :not_found} = Conversations.display_history(conversation.id, viewer)
    {:ok, _} = Conversations.revoke_share(share)

    assert {:error, :not_found} =
             Conversations.resolve_display_conversation(conversation.id, viewer)

    for id <- [nil, "invalid", Ecto.UUID.generate()] do
      assert {:error, :not_found} = Conversations.resolve_display_conversation(id, owner)
    end

    assert {:error, :not_found} = Conversations.resolve_display_conversation(conversation.id, nil)
  end

  test "resolution refreshes roles and does not let admin or nil person widen read access" do
    owner = user_fixture()
    super = user_fixture(%{role: role_fixture(%{name: "super_admin"})})

    {:ok, conversation} =
      Conversations.create_conversation(%{user_id: owner.id, channel_type: "bo"})

    assert {:ok, ^conversation} =
             Conversations.resolve_display_conversation(conversation.id, super)

    admin_role = role_fixture(%{name: "admin"})
    {:ok, _} = Zaq.Accounts.update_user(super, %{role_id: admin_role.id})

    assert {:error, :not_found} =
             Conversations.resolve_display_conversation(conversation.id, super)

    assert {:error, :not_found} = Conversations.display_history(conversation.id, super)
  end

  test "routed resolution requires authenticated actor and confidential transport" do
    owner = user_fixture()

    {:ok, conversation} =
      Conversations.create_conversation(%{user_id: owner.id, channel_type: "bo"})

    event =
      Event.new(
        %{action: :resolve_display_conversation, conversation_id: conversation.id},
        :engine,
        actor: %{user_id: owner.id},
        opts: [action: :conversation, confidential: true]
      )

    assert %{response: {:ok, ^conversation}} = Api.handle_event(event, :conversation, %{})

    assert %{response: {:error, :confidential_event_required}} =
             Api.handle_event(%{event | opts: [action: :conversation]}, :conversation, %{})

    for actor <- [
          nil,
          %{person: %{id: nil}},
          %{user_id: 0},
          %{user_id: owner.id + 1_000_000, role: "super_admin"}
        ] do
      assert %{response: {:error, :unauthorized}} =
               Api.handle_event(%{event | actor: actor}, :conversation, %{})
    end
  end
end
