defmodule Zaq.Engine.Conversations.SchemasTest do
  @moduledoc """
  Unit tests for Conversation, Message, MessageRating, and ConversationShare changesets.
  These supplement the context-level tests in conversations_test.exs with exhaustive
  changeset coverage.
  """

  use Zaq.DataCase, async: true

  @moduletag capture_log: true

  alias Zaq.Engine.Conversations.{Conversation, ConversationShare, Message, MessageRating}

  # ── Conversation changeset ───────────────────────────────────────────

  describe "Conversation.changeset/2" do
    test "valid with all required fields" do
      cs = Conversation.changeset(%Conversation{}, %{channel_type: "bo"})
      assert cs.valid?
    end

    test "invalid without channel_type" do
      cs = Conversation.changeset(%Conversation{}, %{})
      refute cs.valid?
      assert %{channel_type: _} = errors_on(cs)
    end

    test "invalid with unknown channel_type" do
      cs = Conversation.changeset(%Conversation{}, %{channel_type: "fax"})
      refute cs.valid?
      assert %{channel_type: _} = errors_on(cs)
    end

    test "accepts all valid channel_types" do
      for ct <- ~w[mattermost slack bo api] do
        cs = Conversation.changeset(%Conversation{}, %{channel_type: ct})
        assert cs.valid?, "expected #{ct} to be valid"
      end
    end

    test "rejects unknown status" do
      cs = Conversation.changeset(%Conversation{}, %{channel_type: "bo", status: "deleted"})
      refute cs.valid?
      assert %{status: _} = errors_on(cs)
    end

    test "accepts valid statuses" do
      for s <- ~w[active archived] do
        cs = Conversation.changeset(%Conversation{}, %{channel_type: "bo", status: s})
        assert cs.valid?, "expected status #{s} to be valid"
      end
    end

    test "allows nil user_id for anonymous channel users" do
      cs =
        Conversation.changeset(%Conversation{}, %{
          channel_type: "mattermost",
          channel_user_id: "mm_anon",
          user_id: nil
        })

      assert cs.valid?
    end

    test "casts metadata map" do
      cs =
        Conversation.changeset(%Conversation{}, %{
          channel_type: "bo",
          metadata: %{"key" => "value"}
        })

      assert cs.valid?
      assert get_change(cs, :metadata) == %{"key" => "value"}
    end
  end

  # ── Message changeset ────────────────────────────────────────────────

  describe "Message.changeset/2" do
    @valid_uuid Ecto.UUID.generate()

    test "valid with all required fields" do
      cs =
        Message.changeset(%Message{}, %{
          conversation_id: @valid_uuid,
          role: "user",
          content: "hello"
        })

      assert cs.valid?
    end

    test "invalid without conversation_id" do
      cs = Message.changeset(%Message{}, %{role: "user", content: "hello"})
      refute cs.valid?
      assert %{conversation_id: _} = errors_on(cs)
    end

    test "invalid without role" do
      cs = Message.changeset(%Message{}, %{conversation_id: @valid_uuid, content: "hello"})
      refute cs.valid?
      assert %{role: _} = errors_on(cs)
    end

    test "invalid without content" do
      cs = Message.changeset(%Message{}, %{conversation_id: @valid_uuid, role: "user"})
      refute cs.valid?
      assert %{content: _} = errors_on(cs)
    end

    test "rejects invalid role" do
      cs =
        Message.changeset(%Message{}, %{
          conversation_id: @valid_uuid,
          role: "system",
          content: "x"
        })

      refute cs.valid?
      assert %{role: _} = errors_on(cs)
    end

    test "accepts both valid roles" do
      for role <- ~w[user assistant] do
        cs =
          Message.changeset(%Message{}, %{
            conversation_id: @valid_uuid,
            role: role,
            content: "text"
          })

        assert cs.valid?, "expected role #{role} to be valid"
      end
    end

    test "casts optional numeric fields" do
      cs =
        Message.changeset(%Message{}, %{
          conversation_id: @valid_uuid,
          role: "assistant",
          content: "ans",
          prompt_tokens: 10,
          completion_tokens: 5,
          total_tokens: 15,
          confidence_score: 0.85,
          latency_ms: 800
        })

      assert cs.valid?
      assert get_change(cs, :prompt_tokens) == 10
      assert get_change(cs, :confidence_score) == 0.85
    end
  end

  # ── MessageRating changeset ──────────────────────────────────────────

  describe "MessageRating.changeset/2" do
    @valid_msg_id Ecto.UUID.generate()

    test "valid with message_id and rating in range" do
      cs = MessageRating.changeset(%MessageRating{}, %{message_id: @valid_msg_id, rating: 3})
      assert cs.valid?
    end

    test "invalid without message_id" do
      cs = MessageRating.changeset(%MessageRating{}, %{rating: 4})
      refute cs.valid?
      assert %{message_id: _} = errors_on(cs)
    end

    test "invalid without rating" do
      cs = MessageRating.changeset(%MessageRating{}, %{message_id: @valid_msg_id})
      refute cs.valid?
      assert %{rating: _} = errors_on(cs)
    end

    test "rejects rating below 1" do
      cs = MessageRating.changeset(%MessageRating{}, %{message_id: @valid_msg_id, rating: 0})
      refute cs.valid?
      assert %{rating: _} = errors_on(cs)
    end

    test "rejects rating above 5" do
      cs = MessageRating.changeset(%MessageRating{}, %{message_id: @valid_msg_id, rating: 6})
      refute cs.valid?
      assert %{rating: _} = errors_on(cs)
    end

    test "accepts boundary values 1 and 5" do
      for r <- [1, 5] do
        cs =
          MessageRating.changeset(%MessageRating{}, %{message_id: @valid_msg_id, rating: r})

        assert cs.valid?, "expected rating #{r} to be valid"
      end
    end

    test "casts comment field" do
      cs =
        MessageRating.changeset(%MessageRating{}, %{
          message_id: @valid_msg_id,
          rating: 4,
          comment: "Great answer"
        })

      assert cs.valid?
      assert get_change(cs, :comment) == "Great answer"
    end
  end

  # ── ConversationShare changeset ──────────────────────────────────────

  describe "ConversationShare.changeset/2" do
    @valid_conv_id Ecto.UUID.generate()

    test "valid with conversation_id and permission" do
      cs =
        ConversationShare.changeset(%ConversationShare{}, %{
          conversation_id: @valid_conv_id,
          permission: "read"
        })

      assert cs.valid?
    end

    test "auto-generates share_token when none present" do
      cs =
        ConversationShare.changeset(%ConversationShare{}, %{
          conversation_id: @valid_conv_id,
          permission: "read"
        })

      assert cs.valid?
      token = get_change(cs, :share_token)
      assert is_binary(token) and byte_size(token) > 0
    end

    test "invalid without conversation_id" do
      cs = ConversationShare.changeset(%ConversationShare{}, %{permission: "read"})
      refute cs.valid?
      assert %{conversation_id: _} = errors_on(cs)
    end

    test "uses default permission read when not provided" do
      cs =
        ConversationShare.changeset(%ConversationShare{}, %{conversation_id: @valid_conv_id})

      # permission has a default of "read" on the schema, so changeset is valid
      assert cs.valid?
    end

    test "rejects invalid permission" do
      cs =
        ConversationShare.changeset(%ConversationShare{}, %{
          conversation_id: @valid_conv_id,
          permission: "write"
        })

      refute cs.valid?
      assert %{permission: _} = errors_on(cs)
    end

    test "accepts both valid permissions" do
      for p <- ~w[read comment] do
        cs =
          ConversationShare.changeset(%ConversationShare{}, %{
            conversation_id: @valid_conv_id,
            permission: p
          })

        assert cs.valid?, "expected permission #{p} to be valid"
      end
    end

    test "does not overwrite existing share_token" do
      existing_token = "existing_token_abc"

      cs =
        ConversationShare.changeset(
          %ConversationShare{share_token: existing_token},
          %{conversation_id: @valid_conv_id, permission: "read"}
        )

      assert cs.valid?
      # When share_token already set on the struct, no change should be put
      refute get_change(cs, :share_token)
    end
  end
end
