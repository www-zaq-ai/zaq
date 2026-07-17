defmodule Zaq.Engine.Conversations.EmailThreadAnchorTest do
  @moduledoc """
  The conversation-store anchor fallback that lets an outbound send chain onto
  a thread ZAQ did not start.

  The anchor keys on the conversation's *grouping key*, derived by the same
  `Zaq.Channels.Bridge` dispatch persistence uses (`topic` before `subject`),
  and is returned verbatim from `metadata["threading"]["anchor"]`, written at
  persist time by the delivering channel.
  """
  use Zaq.DataCase, async: false

  @moduletag capture_log: true

  alias Zaq.Accounts.People
  alias Zaq.Channels.CommunicationBridge
  alias Zaq.Engine.Conversations

  defp person_fixture(name \\ "Anchor Person") do
    {:ok, person} = People.create_person(%{full_name: "#{name} #{System.unique_integer()}"})
    person
  end

  defp email_conversation(person, channel_user_id) do
    {:ok, conv} =
      Conversations.create_conversation(%{
        channel_type: "email:imap",
        channel_user_id: channel_user_id,
        person_id: person.id
      })

    conv
  end

  defp add_message(conv, metadata, opts \\ []) do
    {:ok, message} =
      Conversations.add_message(conv, %{
        role: "assistant",
        content: Keyword.get(opts, :content, "body"),
        metadata: metadata
      })

    message
  end

  defp anchor_metadata(message_id, references \\ []) do
    %{
      "topic" => "Topic A",
      "threading" => %{
        "anchor" => %{
          "message_id" => message_id,
          "thread_id" => List.first(references) || message_id,
          "references" => references
        }
      }
    }
  end

  # The exact resolution Notifications runs for the conversation fallback:
  # grouping key + channel type from the Bridge dispatch, then the generic
  # opaque lookup.
  defp resolve_anchor(person_id, platform, topic, subject) do
    case CommunicationBridge.outbound_conversation_key(platform, topic, subject) do
      key when is_binary(key) ->
        Conversations.latest_thread_anchor(
          person_id,
          CommunicationBridge.conversation_channel_type(platform),
          key
        )

      _ ->
        nil
    end
  end

  describe "no anchor" do
    test "returns nil when the person has no email conversation" do
      person = person_fixture()

      assert resolve_anchor(person.id, "email:smtp", "Topic A", "Topic A") == nil
    end

    test "returns nil when the conversation has no anchor-bearing message" do
      person = person_fixture()
      conv = email_conversation(person, "Topic A")
      # A pre-fix message: subject/topic metadata only, no threading anchor.
      add_message(conv, %{"topic" => "Topic A", "subject" => "Topic A"})

      assert resolve_anchor(person.id, "email:smtp", "Topic A", "Topic A") == nil
    end

    # Bug #8: a blank grouping key falls through to author_id and can collide
    # across leads — start a fresh chain rather than risk a cross-lead match.
    test "returns nil when the resolved grouping key is blank" do
      person = person_fixture()

      assert resolve_anchor(person.id, "email:smtp", nil, nil) == nil
      assert resolve_anchor(person.id, "email:smtp", "  ", "") == nil
      assert Conversations.latest_thread_anchor(person.id, "email:imap", "  ") == nil
    end

    test "returns nil when person_id is nil" do
      assert resolve_anchor(nil, "email:smtp", "Topic A", "Topic A") == nil
      assert Conversations.latest_thread_anchor(nil, "email:imap", "Topic A") == nil
    end

    test "returns nil for non-binary key or channel type" do
      person = person_fixture()

      assert Conversations.latest_thread_anchor(person.id, "email:imap", nil) == nil
      assert Conversations.latest_thread_anchor(person.id, nil, "Topic A") == nil
    end

    test "returns nil for a non-email platform even when an email anchor exists" do
      person = person_fixture()
      conv = email_conversation(person, "Topic A")
      add_message(conv, anchor_metadata("m1@zaq.local"))

      assert resolve_anchor(person.id, "mattermost", "Topic A", "Topic A") == nil
    end

    test "does not anchor onto another person's conversation with the same key" do
      lead_a = person_fixture("Lead A")
      lead_b = person_fixture("Lead B")

      conv_a = email_conversation(lead_a, "Topic A")
      add_message(conv_a, anchor_metadata("a1@zaq.local"))

      assert resolve_anchor(lead_b.id, "email:smtp", "Topic A", "Topic A") == nil
    end
  end

  describe "resolving the anchor" do
    test "returns the stored anchor verbatim — parent id, thread root, references" do
      person = person_fixture()
      conv = email_conversation(person, "Topic A")
      add_message(conv, anchor_metadata("m2@zaq.local", ["m1@zaq.local"]))

      anchor = resolve_anchor(person.id, "email:smtp", "Topic A", "Topic A")

      assert anchor["message_id"] == "m2@zaq.local"
      assert anchor["references"] == ["m1@zaq.local"]
      # Root = references head.
      assert anchor["thread_id"] == "m1@zaq.local"
    end

    test "root falls back to the message's own id for a one-message thread" do
      person = person_fixture()
      conv = email_conversation(person, "Topic A")
      add_message(conv, anchor_metadata("m1@zaq.local", []))

      anchor = resolve_anchor(person.id, "email:smtp", "Topic A", "Topic A")

      assert anchor["message_id"] == "m1@zaq.local"
      assert anchor["references"] == []
      assert anchor["thread_id"] == "m1@zaq.local"
    end

    test "keys on topic, which takes precedence over subject" do
      person = person_fixture()
      conv = email_conversation(person, "The Topic")
      add_message(conv, anchor_metadata("m1@zaq.local"))

      # Grouping resolved topic-first, so a differing subject must not matter.
      assert %{"message_id" => "m1@zaq.local"} =
               resolve_anchor(person.id, "email:smtp", "The Topic", "A Different Subject")

      # And keying by the subject alone must NOT find it.
      assert resolve_anchor(person.id, "email:smtp", nil, "A Different Subject") == nil
    end

    test "falls back to subject when topic is absent" do
      person = person_fixture()
      conv = email_conversation(person, "The Subject")
      add_message(conv, anchor_metadata("m1@zaq.local"))

      assert %{"message_id" => "m1@zaq.local"} =
               resolve_anchor(person.id, "email:smtp", nil, "The Subject")
    end
  end

  describe "picking the right message" do
    # Bug #2: a newer non-email / pre-fix row must not shadow the last real email.
    test "picks the latest anchored message, skipping anchor-less rows" do
      person = person_fixture()
      conv = email_conversation(person, "Topic A")

      add_message(conv, anchor_metadata("m1@zaq.local"))
      Process.sleep(2)
      add_message(conv, anchor_metadata("m2@zaq.local", ["m1@zaq.local"]))
      Process.sleep(2)
      # A later row with no anchor (e.g. a chat message or a pre-fix send).
      add_message(conv, %{"topic" => "Topic A"})

      anchor = resolve_anchor(person.id, "email:smtp", "Topic A", "Topic A")

      assert anchor["message_id"] == "m2@zaq.local"
      assert anchor["references"] == ["m1@zaq.local"]
    end
  end

  describe "legacy rows (email residue only, pre-anchor)" do
    # Rows written before write-time anchors carry only `email.threading`.
    # The lookup deliberately does not interpret them — the read path stays
    # email-blind.
    test "do not resolve" do
      person = person_fixture()
      conv = email_conversation(person, "Topic A")

      add_message(conv, %{
        "email" => %{
          "threading" => %{
            "message_id" => "<m2@zaq.local>",
            "references" => "<m0@zaq.local> <m1@zaq.local>"
          }
        }
      })

      assert resolve_anchor(person.id, "email:smtp", "Topic A", "Topic A") == nil
    end
  end
end
