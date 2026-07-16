defmodule Zaq.Engine.Conversations.ThreadingPersistenceTest do
  @moduledoc """
  The send's threading rides the *existing* generic persistence params —
  `PersistMessageHistory` gains no email-specific code: the delivery receipt's
  `thread_metadata` is merged verbatim into the message row's metadata.

  Driven through the real action and the real engine (no hand-assembled structs),
  because the mapping from params → `%Incoming{}` → message row is exactly the
  part that must be right: `topic`/`subject` are folded into the incoming's
  metadata (they are not `Incoming` fields), while the message row's metadata
  comes from the `metadata`/`thread_metadata` params.

  Two invariants are pinned:

    1. The stored metadata carries the receipt verbatim — the channel-agnostic
       anchor (`metadata.threading.anchor`) the next lookup reads.
    2. The generic `thread_id` must NOT re-key the conversation — grouping stays
       topic/subject-based, or the next anchor lookup would miss and the chain
       would break.
  """
  use Zaq.DataCase, async: false

  @moduletag capture_log: true

  alias Zaq.Accounts.People
  alias Zaq.Agent.Tools.Conversations.PersistMessageHistory
  alias Zaq.Channels.Bridge
  alias Zaq.Engine.Conversations

  # Routes the action's event into the real engine.
  defmodule EngineRouter do
    alias Zaq.Engine.Api

    def dispatch(event), do: Api.handle_event(event, event.opts[:action], nil)
  end

  defp person_fixture do
    {:ok, person} = People.create_person(%{full_name: "Lead #{System.unique_integer()}"})
    person
  end

  # The exact shape `EmailBridge.send_reply/2` returns in its receipt.
  defp receipt_thread_metadata(message_id, in_reply_to, references) do
    %{
      "threading" => %{
        "anchor" => %{
          "message_id" => message_id,
          "in_reply_to" => in_reply_to,
          "references" => references,
          "thread_id" => List.first(references) || message_id
        }
      }
    }
  end

  # Mirrors exactly what the `send_email → update_history` edge maps:
  # the generic `message_id`/`thread_id` plus the opaque `thread_metadata`.
  defp persist(person, opts) do
    PersistMessageHistory.run(
      %{
        content: "sent body",
        provider: "email:imap",
        channel_id: "lead@example.test",
        person: %{id: person.id},
        topic: Keyword.get(opts, :topic, "Topic A"),
        message_id: Keyword.get(opts, :message_id),
        thread_id: Keyword.get(opts, :thread_id),
        thread_metadata: Keyword.get(opts, :thread_metadata, %{})
      },
      %{node_router: EngineRouter}
    )
  end

  # The conversation-fallback resolution Notifications runs for the next send.
  defp resolve_anchor(person_id, platform, topic, subject) do
    case Bridge.outbound_conversation_key(platform, topic, subject) do
      key when is_binary(key) ->
        Conversations.latest_thread_anchor(
          person_id,
          Bridge.conversation_channel_type(platform),
          key
        )

      _ ->
        nil
    end
  end

  describe "storing the threading anchor" do
    test "persists the receipt verbatim — the channel-agnostic anchor" do
      person = person_fixture()

      assert {:ok, %{conversation_id: _conv_id, message_id: row_id}} =
               persist(person,
                 message_id: "new@zaq.local",
                 thread_id: "m0@zaq.local",
                 thread_metadata:
                   receipt_thread_metadata("new@zaq.local", "m1@zaq.local", [
                     "m0@zaq.local",
                     "m1@zaq.local"
                   ])
               )

      message = Repo.get!(Conversations.Message, row_id)

      anchor = message.metadata["threading"]["anchor"]
      assert anchor["message_id"] == "new@zaq.local"
      assert anchor["thread_id"] == "m0@zaq.local"
      assert anchor["references"] == ["m0@zaq.local", "m1@zaq.local"]
      assert anchor["in_reply_to"] == "m1@zaq.local"

      # No email-shaped duplicate of the anchor is stored.
      refute Map.has_key?(message.metadata, "email")

      # The topic the action already stored survives alongside it.
      assert message.metadata["topic"] == "Topic A"

      # The row id is the DB uuid — distinct from the RFC header id.
      refute row_id == "new@zaq.local"
    end

    test "the stored message is immediately resolvable as the next send's anchor" do
      person = person_fixture()

      assert {:ok, _} =
               persist(person,
                 message_id: "new@zaq.local",
                 thread_id: "new@zaq.local",
                 thread_metadata: receipt_thread_metadata("new@zaq.local", nil, [])
               )

      # The round trip the whole feature rests on: what send N persists,
      # send N+1 must find.
      anchor = resolve_anchor(person.id, "email:smtp", "Topic A", "Topic A")

      assert anchor["message_id"] == "new@zaq.local"
      assert anchor["thread_id"] == "new@zaq.local"
      assert anchor["references"] == []
    end
  end

  describe "grouping guard (thread_id must not re-key the conversation)" do
    test "the conversation stays keyed on topic even when thread_id is set" do
      person = person_fixture()

      assert {:ok, %{conversation_id: conv_id}} =
               persist(person,
                 message_id: "new@zaq.local",
                 thread_id: "m0@zaq.local",
                 thread_metadata: receipt_thread_metadata("new@zaq.local", nil, [])
               )

      conv = Conversations.get_conversation(conv_id)

      # Keyed on the topic — NOT on the minted id, NOT on the thread root.
      assert conv.channel_user_id == "Topic A"
      refute conv.channel_user_id == "m0@zaq.local"
      refute conv.channel_user_id == "new@zaq.local"
    end

    test "two consecutive sends land in the SAME conversation row and chain" do
      person = person_fixture()

      assert {:ok, %{conversation_id: conv_a}} =
               persist(person,
                 message_id: "m1@zaq.local",
                 thread_id: "m1@zaq.local",
                 thread_metadata: receipt_thread_metadata("m1@zaq.local", nil, [])
               )

      assert {:ok, %{conversation_id: conv_b}} =
               persist(person,
                 message_id: "m2@zaq.local",
                 thread_id: "m1@zaq.local",
                 thread_metadata:
                   receipt_thread_metadata("m2@zaq.local", "m1@zaq.local", ["m1@zaq.local"])
               )

      assert conv_a == conv_b

      # The anchor now points at the latest send.
      anchor = resolve_anchor(person.id, "email:smtp", "Topic A", "Topic A")
      assert anchor["message_id"] == "m2@zaq.local"
      assert anchor["references"] == ["m1@zaq.local"]
    end
  end
end
