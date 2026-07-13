defmodule Zaq.Engine.Conversations.EmailThreadAnchorTest do
  @moduledoc """
  Step 2 of the outbound email threading plan: the anchor lookup that lets send N
  chain onto send N-1.

  The anchor keys on the conversation's *grouping key*, resolved exactly the way
  persistence resolves it (`topic` before `subject`) — not on the conversation
  title, and not on an assumed `channel_user_id == subject`.
  """
  use Zaq.DataCase, async: false

  @moduletag capture_log: true

  alias Zaq.Accounts.People
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

  defp threading_metadata(message_id, references \\ []) do
    %{
      "topic" => "Topic A",
      "email" => %{
        "threading" => %{
          "message_id" => message_id,
          "in_reply_to" => List.last(references),
          "references" => references
        }
      }
    }
  end

  describe "email_thread_anchor/3 — no anchor" do
    test "returns nil when the person has no email conversation" do
      person = person_fixture()

      assert Conversations.email_thread_anchor(person.id, "Topic A", "Topic A") == nil
    end

    test "returns nil when the conversation has no threading-bearing message" do
      person = person_fixture()
      conv = email_conversation(person, "Topic A")
      # A pre-fix message: subject/topic metadata only, no email.threading.
      add_message(conv, %{"topic" => "Topic A", "subject" => "Topic A"})

      assert Conversations.email_thread_anchor(person.id, "Topic A", "Topic A") == nil
    end

    # Bug #8: a blank grouping key falls through to author_id and can collide
    # across leads — start a fresh chain rather than risk a cross-lead match.
    test "returns nil when the resolved grouping key is blank" do
      person = person_fixture()

      assert Conversations.email_thread_anchor(person.id, nil, nil) == nil
      assert Conversations.email_thread_anchor(person.id, "  ", "") == nil
    end

    test "returns nil when person_id is nil" do
      assert Conversations.email_thread_anchor(nil, "Topic A", "Topic A") == nil
    end

    test "does not anchor onto another person's conversation with the same key" do
      lead_a = person_fixture("Lead A")
      lead_b = person_fixture("Lead B")

      conv_a = email_conversation(lead_a, "Topic A")
      add_message(conv_a, threading_metadata("a1@zaq.local"))

      assert Conversations.email_thread_anchor(lead_b.id, "Topic A", "Topic A") == nil
    end
  end

  describe "email_thread_anchor/3 — resolving the anchor" do
    test "returns the parent message_id, the thread root, and the references chain" do
      person = person_fixture()
      conv = email_conversation(person, "Topic A")
      add_message(conv, threading_metadata("m2@zaq.local", ["m1@zaq.local"]))

      anchor = Conversations.email_thread_anchor(person.id, "Topic A", "Topic A")

      assert anchor.message_id == "m2@zaq.local"
      assert anchor.references == ["m1@zaq.local"]
      # Root = references head.
      assert anchor.thread_key == "m1@zaq.local"
    end

    test "root falls back to the message's own id for a one-message thread" do
      person = person_fixture()
      conv = email_conversation(person, "Topic A")
      add_message(conv, threading_metadata("m1@zaq.local", []))

      anchor = Conversations.email_thread_anchor(person.id, "Topic A", "Topic A")

      assert anchor.message_id == "m1@zaq.local"
      assert anchor.references == []
      assert anchor.thread_key == "m1@zaq.local"
    end

    test "keys on topic, which takes precedence over subject" do
      person = person_fixture()
      conv = email_conversation(person, "The Topic")
      add_message(conv, threading_metadata("m1@zaq.local"))

      # Grouping resolved topic-first, so a differing subject must not matter.
      assert %{message_id: "m1@zaq.local"} =
               Conversations.email_thread_anchor(person.id, "The Topic", "A Different Subject")

      # And keying by the subject alone must NOT find it.
      assert Conversations.email_thread_anchor(person.id, nil, "A Different Subject") == nil
    end

    test "falls back to subject when topic is absent" do
      person = person_fixture()
      conv = email_conversation(person, "The Subject")
      add_message(conv, threading_metadata("m1@zaq.local"))

      assert %{message_id: "m1@zaq.local"} =
               Conversations.email_thread_anchor(person.id, nil, "The Subject")
    end
  end

  describe "email_thread_anchor/3 — picking the right message" do
    # Bug #2: a newer non-email / pre-fix row must not shadow the last real email.
    test "picks the latest email-threaded message, skipping threading-less rows" do
      person = person_fixture()
      conv = email_conversation(person, "Topic A")

      add_message(conv, threading_metadata("m1@zaq.local"))
      Process.sleep(2)
      add_message(conv, threading_metadata("m2@zaq.local", ["m1@zaq.local"]))
      Process.sleep(2)
      # A later row with no threading (e.g. a chat message or a pre-fix send).
      add_message(conv, %{"topic" => "Topic A"})

      anchor = Conversations.email_thread_anchor(person.id, "Topic A", "Topic A")

      assert anchor.message_id == "m2@zaq.local"
      assert anchor.references == ["m1@zaq.local"]
    end

    # Bug #1: the IMAP parser stores `references` as a space-joined STRING.
    # The anchor must always hand back a list so Notifications' `++` is safe.
    test "normalizes a string references value (inbound parser shape) into a list" do
      person = person_fixture()
      conv = email_conversation(person, "Topic A")

      add_message(conv, %{
        "email" => %{
          "threading" => %{
            "message_id" => "m2@zaq.local",
            "references" => "<m0@zaq.local> <m1@zaq.local>"
          }
        }
      })

      anchor = Conversations.email_thread_anchor(person.id, "Topic A", "Topic A")

      assert anchor.references == ["m0@zaq.local", "m1@zaq.local"]
      assert anchor.thread_key == "m0@zaq.local"
    end

    test "normalizes bracketed ids to the stored bracket-less form" do
      person = person_fixture()
      conv = email_conversation(person, "Topic A")

      add_message(conv, %{
        "email" => %{
          "threading" => %{"message_id" => "<m1@zaq.local>", "references" => []}
        }
      })

      anchor = Conversations.email_thread_anchor(person.id, "Topic A", "Topic A")

      assert anchor.message_id == "m1@zaq.local"
    end
  end
end
