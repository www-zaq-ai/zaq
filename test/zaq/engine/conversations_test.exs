defmodule Zaq.Engine.ConversationsTest do
  use Zaq.DataCase, async: true

  @moduletag capture_log: true

  alias Zaq.Engine.Conversations

  # ── Helpers ────────────────────────────────────────────────────────

  defp conv_attrs(overrides \\ %{}) do
    Map.merge(
      %{channel_type: "bo", channel_user_id: "u_#{System.unique_integer([:positive])}"},
      overrides
    )
  end

  # ── create_conversation/1 ───────────────────────────────────────────

  describe "create_conversation/1" do
    test "creates with valid attrs for BO user" do
      user = user_fixture()
      assert {:ok, conv} = Conversations.create_conversation(conv_attrs(%{user_id: user.id}))
      assert conv.channel_type == "bo"
      assert conv.status == "active"
      assert conv.user_id == user.id
    end

    test "creates with nil user_id for anonymous channel user" do
      attrs = %{channel_type: "mattermost", channel_user_id: "mm_user_abc"}
      assert {:ok, conv} = Conversations.create_conversation(attrs)
      assert is_nil(conv.user_id)
      assert conv.channel_user_id == "mm_user_abc"
    end

    test "returns error changeset for invalid channel_type" do
      assert {:error, changeset} = Conversations.create_conversation(%{channel_type: "fax"})
      assert %{channel_type: _} = errors_on(changeset)
    end
  end

  # ── get_conversation!/1 ─────────────────────────────────────────────

  describe "get_conversation!/1" do
    test "returns conversation by id" do
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      assert Conversations.get_conversation!(conv.id).id == conv.id
    end

    test "raises Ecto.NoResultsError for unknown id" do
      assert_raise Ecto.NoResultsError, fn ->
        Conversations.get_conversation!(Ecto.UUID.generate())
      end
    end
  end

  # ── get_or_create_conversation_for_channel/3 ───────────────────────

  describe "get_or_create_conversation_for_channel/3" do
    test "creates new conversation on first call" do
      assert {:ok, conv} =
               Conversations.get_or_create_conversation_for_channel("chan_1", "mattermost", nil)

      assert conv.channel_user_id == "chan_1"
      assert conv.channel_type == "mattermost"
    end

    test "returns same conversation on second call with same channel_user_id + channel_type" do
      {:ok, first} =
        Conversations.get_or_create_conversation_for_channel("chan_2", "mattermost", nil)

      {:ok, second} =
        Conversations.get_or_create_conversation_for_channel("chan_2", "mattermost", nil)

      assert first.id == second.id
    end
  end

  # ── list_conversations/1 ────────────────────────────────────────────

  describe "list_conversations/1" do
    test "filters by user_id" do
      user = user_fixture()
      {:ok, conv} = Conversations.create_conversation(conv_attrs(%{user_id: user.id}))
      {:ok, _other} = Conversations.create_conversation(conv_attrs())

      results = Conversations.list_conversations(user_id: user.id)
      assert Enum.any?(results, &(&1.id == conv.id))
      assert Enum.all?(results, &(&1.user_id == user.id))
    end

    test "filters by status" do
      {:ok, active} = Conversations.create_conversation(conv_attrs(%{status: "active"}))
      {:ok, archived} = Conversations.create_conversation(conv_attrs(%{status: "archived"}))

      active_results = Conversations.list_conversations(status: "active")
      assert Enum.any?(active_results, &(&1.id == active.id))
      refute Enum.any?(active_results, &(&1.id == archived.id))
    end

    test "filters by channel_user_id" do
      {:ok, conv} =
        Conversations.create_conversation(%{
          channel_type: "mattermost",
          channel_user_id: "mm_filter_user"
        })

      results = Conversations.list_conversations(channel_user_id: "mm_filter_user")
      assert Enum.any?(results, &(&1.id == conv.id))
    end
  end

  # ── update_conversation/2 ───────────────────────────────────────────

  describe "update_conversation/2" do
    test "updates title" do
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      assert {:ok, updated} = Conversations.update_conversation(conv, %{title: "New Title"})
      assert updated.title == "New Title"
    end

    test "returns error on invalid status" do
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      assert {:error, changeset} = Conversations.update_conversation(conv, %{status: "deleted"})
      assert %{status: _} = errors_on(changeset)
    end
  end

  # ── archive_conversation/1 ──────────────────────────────────────────

  describe "archive_conversation/1" do
    test "sets status to archived" do
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      assert {:ok, archived} = Conversations.archive_conversation(conv)
      assert archived.status == "archived"
    end
  end

  # ── delete_conversation/1 ───────────────────────────────────────────

  describe "delete_conversation/1" do
    test "deletes conversation and cascades messages" do
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      {:ok, _msg} = Conversations.add_message(conv, %{role: "user", content: "hello"})
      assert {:ok, _} = Conversations.delete_conversation(conv)
      assert_raise Ecto.NoResultsError, fn -> Conversations.get_conversation!(conv.id) end
    end
  end

  describe "persist_from_incoming/2" do
    test "normalizes legacy email provider and groups by email thread key" do
      result = %{
        answer: "Sure, here is the answer.",
        confidence_score: 0.95,
        latency_ms: 120,
        prompt_tokens: 20,
        completion_tokens: 30,
        total_tokens: 50
      }

      thread_key = "root-thread@example.com"

      first = %Zaq.Engine.Messages.Incoming{
        content: "First email",
        channel_id: "sender@example.com",
        author_id: "sender@example.com",
        provider: :email,
        thread_id: "parent-a@example.com",
        message_id: "<msg-a@example.com>",
        metadata: %{"email" => %{"thread_key" => thread_key}}
      }

      second = %Zaq.Engine.Messages.Incoming{
        content: "Second email in same thread",
        channel_id: "sender@example.com",
        author_id: "sender@example.com",
        provider: :"email:imap",
        thread_id: "parent-b@example.com",
        message_id: "<msg-b@example.com>",
        metadata: %{"email" => %{"thread_key" => thread_key}}
      }

      assert :ok = Conversations.persist_from_incoming(first, result)
      assert :ok = Conversations.persist_from_incoming(second, result)

      [conv] = Conversations.list_conversations(channel_type: "email:imap")
      assert conv.channel_user_id == thread_key

      messages = Conversations.list_messages(conv)
      assert Enum.count(messages, &(&1.role == "user")) == 2
      assert Enum.count(messages, &(&1.role == "assistant")) == 2
    end
  end

  # ── add_message/2 ──────────────────────────────────────────────────

  describe "add_message/2" do
    test "adds user message to conversation" do
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      assert {:ok, msg} = Conversations.add_message(conv, %{role: "user", content: "Hello ZAQ"})
      assert msg.role == "user"
      assert msg.content == "Hello ZAQ"
      assert msg.conversation_id == conv.id
    end

    test "adds assistant message with full metadata" do
      {:ok, conv} = Conversations.create_conversation(conv_attrs())

      attrs = %{
        role: "assistant",
        content: "Here is the answer.",
        model: "gpt-4",
        prompt_tokens: 100,
        completion_tokens: 50,
        confidence_score: 0.9,
        sources: [%{"id" => "doc1", "title" => "Doc 1", "score" => 0.95}],
        latency_ms: 1200
      }

      assert {:ok, msg} = Conversations.add_message(conv, attrs)
      assert msg.model == "gpt-4"
      assert msg.prompt_tokens == 100
      assert msg.confidence_score == 0.9
    end

    test "rejects invalid role" do
      {:ok, conv} = Conversations.create_conversation(conv_attrs())

      assert {:error, changeset} =
               Conversations.add_message(conv, %{role: "system", content: "x"})

      assert %{role: _} = errors_on(changeset)
    end
  end

  # ── list_messages/1 ─────────────────────────────────────────────────

  describe "list_messages/1" do
    test "returns messages in insertion order" do
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      {:ok, _m1} = Conversations.add_message(conv, %{role: "user", content: "first"})
      {:ok, _m2} = Conversations.add_message(conv, %{role: "assistant", content: "second"})

      messages = Conversations.list_messages(conv)
      assert length(messages) == 2
      assert hd(messages).content == "first"
      assert List.last(messages).content == "second"
    end
  end

  # ── rate_message/2 ──────────────────────────────────────────────────

  describe "rate_message/2" do
    test "creates rating for authenticated user" do
      user = user_fixture()
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      {:ok, msg} = Conversations.add_message(conv, %{role: "assistant", content: "answer"})

      assert {:ok, rating} = Conversations.rate_message(msg, %{user_id: user.id, rating: 5})
      assert rating.rating == 5
      assert rating.user_id == user.id
    end

    test "creates rating for channel user" do
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      {:ok, msg} = Conversations.add_message(conv, %{role: "assistant", content: "answer"})

      assert {:ok, rating} =
               Conversations.rate_message(msg, %{channel_user_id: "mm_xyz", rating: 3})

      assert rating.channel_user_id == "mm_xyz"
    end

    test "rejects rating outside 1-5" do
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      {:ok, msg} = Conversations.add_message(conv, %{role: "assistant", content: "answer"})

      assert {:error, changeset} = Conversations.rate_message(msg, %{rating: 6})
      assert %{rating: _} = errors_on(changeset)

      assert {:error, changeset2} = Conversations.rate_message(msg, %{rating: 0})
      assert %{rating: _} = errors_on(changeset2)
    end
  end

  # ── rate_message_by_id/2 ────────────────────────────────────────────

  describe "rate_message_by_id/2" do
    test "creates a new rating by message UUID" do
      user = user_fixture()
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      {:ok, msg} = Conversations.add_message(conv, %{role: "assistant", content: "answer"})

      assert {:ok, rating} =
               Conversations.rate_message_by_id(msg.id, %{user_id: user.id, rating: 5})

      assert rating.rating == 5
      assert rating.message_id == msg.id
    end

    test "updates existing rating (upsert) for the same user" do
      user = user_fixture()
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      {:ok, msg} = Conversations.add_message(conv, %{role: "assistant", content: "answer"})

      {:ok, _} = Conversations.rate_message_by_id(msg.id, %{user_id: user.id, rating: 5})

      assert {:ok, updated} =
               Conversations.rate_message_by_id(msg.id, %{user_id: user.id, rating: 1})

      assert updated.rating == 1
    end

    test "stores comment on negative feedback" do
      user = user_fixture()
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      {:ok, msg} = Conversations.add_message(conv, %{role: "assistant", content: "answer"})

      assert {:ok, rating} =
               Conversations.rate_message_by_id(msg.id, %{
                 user_id: user.id,
                 rating: 1,
                 comment: "Not factually correct\nmore details here"
               })

      assert rating.comment == "Not factually correct\nmore details here"
    end

    test "returns error for unknown message id" do
      user = user_fixture()

      assert {:error, :not_found} =
               Conversations.rate_message_by_id(Ecto.UUID.generate(), %{
                 user_id: user.id,
                 rating: 3
               })
    end
  end

  # ── list_messages/1 ratings preload ─────────────────────────────────

  describe "list_messages/1 ratings preload" do
    test "preloads ratings on returned messages" do
      user = user_fixture()
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      {:ok, msg} = Conversations.add_message(conv, %{role: "assistant", content: "answer"})
      {:ok, _} = Conversations.rate_message(msg, %{user_id: user.id, rating: 4})

      [loaded_msg] =
        Conversations.list_messages(conv)
        |> Enum.filter(&(&1.role == "assistant"))

      assert [rating] = loaded_msg.ratings
      assert rating.rating == 4
    end

    test "preloads empty ratings list when no ratings exist" do
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      {:ok, _} = Conversations.add_message(conv, %{role: "assistant", content: "answer"})

      [msg] = Conversations.list_messages(conv)
      assert msg.ratings == []
    end
  end

  # ── share_conversation/2 ────────────────────────────────────────────

  describe "share_conversation/2" do
    test "creates share with auto-generated token" do
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      assert {:ok, share} = Conversations.share_conversation(conv, %{permission: "read"})
      assert is_binary(share.share_token)
      assert String.length(share.share_token) > 0
    end

    test "creates share for specific user" do
      user = user_fixture()
      {:ok, conv} = Conversations.create_conversation(conv_attrs())

      assert {:ok, share} =
               Conversations.share_conversation(conv, %{
                 shared_with_user_id: user.id,
                 permission: "read"
               })

      assert share.shared_with_user_id == user.id
      assert share.permission == "read"
    end

    test "token is unique across shares" do
      {:ok, conv1} = Conversations.create_conversation(conv_attrs())
      {:ok, conv2} = Conversations.create_conversation(conv_attrs())

      {:ok, share1} = Conversations.share_conversation(conv1, %{permission: "read"})
      {:ok, share2} = Conversations.share_conversation(conv2, %{permission: "read"})

      assert share1.share_token != share2.share_token
    end
  end

  # ── get_conversation_by_token/1 ─────────────────────────────────────

  describe "get_conversation_by_token/1" do
    test "returns conversation for valid token" do
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      {:ok, share} = Conversations.share_conversation(conv, %{permission: "read"})

      result = Conversations.get_conversation_by_token(share.share_token)
      assert result.id == conv.id
    end

    test "returns nil for unknown token" do
      assert is_nil(Conversations.get_conversation_by_token("nonexistent_token_xyz"))
    end
  end

  # ── revoke_share/1 ──────────────────────────────────────────────────

  describe "revoke_share/1" do
    test "deletes the share" do
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      {:ok, share} = Conversations.share_conversation(conv, %{permission: "read"})

      assert {:ok, _} = Conversations.revoke_share(share)
      assert is_nil(Conversations.get_conversation_by_token(share.share_token))
    end
  end

  # ── get_conversation/1 ──────────────────────────────────────────────

  describe "get_conversation/1" do
    test "returns conversation by id" do
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      assert %{id: id} = Conversations.get_conversation(conv.id)
      assert id == conv.id
    end

    test "returns nil for unknown id" do
      assert is_nil(Conversations.get_conversation(Ecto.UUID.generate()))
    end
  end

  # ── list_conversations/1 edge cases ─────────────────────────────────

  describe "list_conversations/1 additional filters" do
    test "returns all conversations when called with no opts" do
      {:ok, c1} = Conversations.create_conversation(conv_attrs())
      {:ok, c2} = Conversations.create_conversation(conv_attrs())

      ids = Conversations.list_conversations() |> Enum.map(& &1.id)
      assert c1.id in ids
      assert c2.id in ids
    end

    test "filters by channel_type" do
      {:ok, mm_conv} =
        Conversations.create_conversation(%{
          channel_type: "mattermost",
          channel_user_id: "filter_ct_#{System.unique_integer([:positive])}"
        })

      {:ok, _bo_conv} = Conversations.create_conversation(conv_attrs())

      results = Conversations.list_conversations(channel_type: "mattermost")
      assert Enum.any?(results, &(&1.id == mm_conv.id))
      assert Enum.all?(results, &(&1.channel_type == "mattermost"))
    end

    test "respects limit opt" do
      for _ <- 1..3 do
        Conversations.create_conversation(conv_attrs())
      end

      results = Conversations.list_conversations(limit: 2)
      assert length(results) <= 2
    end
  end

  # ── get_or_create_conversation_for_channel/3 edge cases ─────────────

  describe "get_or_create_conversation_for_channel/3 edge cases" do
    test "always creates a new conversation when channel_user_id is nil" do
      {:ok, first} =
        Conversations.get_or_create_conversation_for_channel(nil, "bo", nil)

      {:ok, second} =
        Conversations.get_or_create_conversation_for_channel(nil, "bo", nil)

      assert first.id != second.id
    end

    test "returns different conversations when channel_config_id differs (nil vs nil is same)" do
      # Two calls with the same channel_user_id, channel_type, and both nil channel_config_id
      # should return the same existing conversation
      channel_user_id = "scoped_user_#{System.unique_integer([:positive])}"

      {:ok, conv_a} =
        Conversations.get_or_create_conversation_for_channel(channel_user_id, "mattermost", nil)

      {:ok, conv_a2} =
        Conversations.get_or_create_conversation_for_channel(channel_user_id, "mattermost", nil)

      assert conv_a.id == conv_a2.id
    end

    test "does not return archived conversation for existing channel user" do
      channel_user_id = "archived_user_#{System.unique_integer([:positive])}"

      {:ok, conv} =
        Conversations.get_or_create_conversation_for_channel(channel_user_id, "mattermost", nil)

      {:ok, _archived} = Conversations.archive_conversation(conv)

      {:ok, new_conv} =
        Conversations.get_or_create_conversation_for_channel(channel_user_id, "mattermost", nil)

      assert new_conv.id != conv.id
      assert new_conv.status == "active"
    end
  end

  # ── get_rating/2 ────────────────────────────────────────────────────

  describe "get_rating/2" do
    test "returns rating for authenticated user" do
      user = user_fixture()
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      {:ok, msg} = Conversations.add_message(conv, %{role: "assistant", content: "reply"})
      {:ok, _rating} = Conversations.rate_message(msg, %{user_id: user.id, rating: 4})

      found = Conversations.get_rating(msg, %{user_id: user.id})
      assert found.rating == 4
      assert found.user_id == user.id
    end

    test "returns rating for channel user" do
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      {:ok, msg} = Conversations.add_message(conv, %{role: "assistant", content: "reply"})

      {:ok, _rating} =
        Conversations.rate_message(msg, %{channel_user_id: "mm_get_rating_test", rating: 2})

      found = Conversations.get_rating(msg, %{channel_user_id: "mm_get_rating_test"})
      assert found.rating == 2
    end

    test "returns nil when no rating exists for user" do
      user = user_fixture()
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      {:ok, msg} = Conversations.add_message(conv, %{role: "assistant", content: "reply"})

      assert is_nil(Conversations.get_rating(msg, %{user_id: user.id}))
    end
  end

  # ── update_rating/2 ─────────────────────────────────────────────────

  describe "update_rating/2" do
    test "updates the rating value" do
      user = user_fixture()
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      {:ok, msg} = Conversations.add_message(conv, %{role: "assistant", content: "answer"})
      {:ok, rating} = Conversations.rate_message(msg, %{user_id: user.id, rating: 3})

      assert {:ok, updated} = Conversations.update_rating(rating, %{rating: 5})
      assert updated.rating == 5
    end

    test "rejects out-of-range update" do
      user = user_fixture()
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      {:ok, msg} = Conversations.add_message(conv, %{role: "assistant", content: "answer"})
      {:ok, rating} = Conversations.rate_message(msg, %{user_id: user.id, rating: 3})

      assert {:error, changeset} = Conversations.update_rating(rating, %{rating: 0})
      assert %{rating: _} = errors_on(changeset)
    end
  end

  # ── delete_rating/1 ─────────────────────────────────────────────────

  describe "delete_rating/1" do
    test "removes the rating" do
      user = user_fixture()
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      {:ok, msg} = Conversations.add_message(conv, %{role: "assistant", content: "answer"})
      {:ok, rating} = Conversations.rate_message(msg, %{user_id: user.id, rating: 5})

      assert {:ok, _} = Conversations.delete_rating(rating)
      assert is_nil(Conversations.get_rating(msg, %{user_id: user.id}))
    end
  end

  # ── list_shares/1 ───────────────────────────────────────────────────

  describe "list_shares/1" do
    test "returns all shares for a conversation" do
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      {:ok, _s1} = Conversations.share_conversation(conv, %{permission: "read"})
      {:ok, _s2} = Conversations.share_conversation(conv, %{permission: "read"})

      shares = Conversations.list_shares(conv)
      assert length(shares) == 2
    end

    test "returns empty list when no shares exist" do
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      assert Conversations.list_shares(conv) == []
    end

    test "does not return shares from other conversations" do
      {:ok, conv1} = Conversations.create_conversation(conv_attrs())
      {:ok, conv2} = Conversations.create_conversation(conv_attrs())
      {:ok, _share} = Conversations.share_conversation(conv1, %{permission: "read"})

      assert Conversations.list_shares(conv2) == []
    end
  end

  # ── share_conversation/2 edge cases ─────────────────────────────────

  describe "share_conversation/2 edge cases" do
    test "rejects invalid permission" do
      {:ok, conv} = Conversations.create_conversation(conv_attrs())

      assert {:error, changeset} =
               Conversations.share_conversation(conv, %{permission: "write"})

      assert %{permission: _} = errors_on(changeset)
    end
  end
end
