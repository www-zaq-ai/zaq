defmodule Zaq.Channels.EmailBridge.ThreadingHeadersTest do
  @moduledoc """
  Step 4: the email bridge emits `Message-ID` for every email send, and
  `In-Reply-To`/`References` whenever a parent is present — while keeping the
  `Re:` prefix exclusive to genuine inbound replies.

  The two predicates are deliberately decoupled:

    * `inbound_reply?` (provider == email:imap + in_reply_to) → drives `Re:` only
    * continuity (anchor/in_reply_to present, any email provider) → drives headers

  A proactive sequence therefore threads via headers while keeping the clean
  subject the campaign topic defines. The bridge mints the Message-ID itself when
  the caller did not pre-mint one, and returns the delivered pointers as a receipt.
  """
  use Zaq.DataCase, async: false

  @moduletag capture_log: true

  alias Zaq.Channels.EmailBridge
  alias Zaq.Engine.Messages.Outgoing

  # Captures the payload the bridge hands to EmailNotification.
  defmodule CapturingNotification do
    def send_notification(recipient, payload, metadata) do
      send(self(), {:sent, recipient, payload, metadata})
      :ok
    end
  end

  setup do
    Application.put_env(:zaq, :email_bridge_smtp_module, CapturingNotification)
    on_exit(fn -> Application.delete_env(:zaq, :email_bridge_smtp_module) end)
    :ok
  end

  defp send_and_capture(%Outgoing{} = outgoing) do
    {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{})

    receive do
      {:sent, _recipient, payload, _metadata} -> payload
    after
      0 -> flunk("bridge did not deliver")
    end
  end

  defp outgoing(overrides) do
    threading =
      %{
        "message_id" => "new@zaq.local",
        "in_reply_to" => nil,
        "references" => []
      }
      |> Map.merge(Map.get(overrides, :threading, %{}))

    %Outgoing{
      body: "hello",
      channel_id: "lead@example.test",
      provider: Map.get(overrides, :provider, :"email:smtp"),
      in_reply_to: Map.get(overrides, :in_reply_to),
      thread_id: Map.get(overrides, :thread_id),
      metadata: %{
        "subject" => Map.get(overrides, :subject, "Topic A"),
        "threading" => threading
      }
    }
  end

  describe "Message-ID emission" do
    test "always emits the minted Message-ID for an email send" do
      payload = send_and_capture(outgoing(%{}))

      assert payload["headers"]["Message-ID"] == "<new@zaq.local>"
    end

    test "mints its own Message-ID when the caller did not pre-mint one" do
      out = %Outgoing{
        body: "hello",
        channel_id: "lead@example.test",
        provider: :"email:smtp",
        metadata: %{"subject" => "Topic A"}
      }

      {:ok, receipt} = EmailBridge.send_reply(out, %{})

      assert_receive {:sent, _recipient, payload, _metadata}
      # No SMTP config in this test → default sending domain.
      assert payload["headers"]["Message-ID"] =~ ~r/^<zaq-[0-9a-f-]{36}@zaq\.local>$/
      assert payload["headers"]["Message-ID"] == "<#{receipt.message_id}>"
    end

    test "returns the delivered pointers as a receipt with a verbatim-storable anchor" do
      {:ok, receipt} =
        EmailBridge.send_reply(
          outgoing(%{
            in_reply_to: "m1@zaq.local",
            threading: %{"in_reply_to" => "m1@zaq.local", "references" => ["m1@zaq.local"]}
          }),
          %{}
        )

      assert receipt.message_id == "new@zaq.local"
      # Root of a one-message chain is the parent itself.
      assert receipt.thread_id == "m1@zaq.local"

      assert receipt.anchor == %{
               "message_id" => "new@zaq.local",
               "in_reply_to" => "m1@zaq.local",
               "references" => ["m1@zaq.local"],
               "thread_id" => "m1@zaq.local"
             }
    end
  end

  describe "outbound-first follow-up (proactive sequence)" do
    test "emits Message-ID + In-Reply-To + References, and keeps the clean subject" do
      payload =
        send_and_capture(
          outgoing(%{
            in_reply_to: "m1@zaq.local",
            threading: %{"in_reply_to" => "m1@zaq.local", "references" => ["m1@zaq.local"]}
          })
        )

      headers = payload["headers"]

      assert headers["Message-ID"] == "<new@zaq.local>"
      assert headers["In-Reply-To"] == "<m1@zaq.local>"
      assert headers["References"] == "<m1@zaq.local>"

      # The whole point: threading comes from headers, NOT from a `Re:` subject.
      assert payload["subject"] == "Topic A"
      refute payload["subject"] =~ ~r/^Re:/i
    end

    test "emits the full ancestor chain in References" do
      payload =
        send_and_capture(
          outgoing(%{
            in_reply_to: "m2@zaq.local",
            threading: %{
              "in_reply_to" => "m2@zaq.local",
              "references" => ["m0@zaq.local", "m1@zaq.local", "m2@zaq.local"]
            }
          })
        )

      assert payload["headers"]["References"] ==
               "<m0@zaq.local> <m1@zaq.local> <m2@zaq.local>"
    end

    # reply_headers/1 already append_once-dedupes in_reply_to into references, so
    # storing a chain that already contains the parent must not double it.
    test "does not duplicate the parent id in References" do
      payload =
        send_and_capture(
          outgoing(%{
            in_reply_to: "m1@zaq.local",
            threading: %{"in_reply_to" => "m1@zaq.local", "references" => ["m1@zaq.local"]}
          })
        )

      refs = payload["headers"]["References"]

      assert refs == "<m1@zaq.local>"
      assert length(String.split(refs, " ")) == 1
    end

    test "first send emits only Message-ID — no In-Reply-To, no References" do
      payload = send_and_capture(outgoing(%{}))

      headers = payload["headers"]

      assert headers["Message-ID"] == "<new@zaq.local>"
      refute Map.has_key?(headers, "In-Reply-To")
      refute Map.has_key?(headers, "References")
    end
  end

  describe "inbound reply regression (must keep Re:)" do
    test "a genuine email:imap reply still gets Re: plus the full headers" do
      payload =
        send_and_capture(
          outgoing(%{
            provider: :"email:imap",
            in_reply_to: "inbound@sender.test",
            threading: %{
              "in_reply_to" => "inbound@sender.test",
              "references" => ["inbound@sender.test"]
            }
          })
        )

      assert payload["subject"] == "Re: Topic A"
      assert payload["headers"]["In-Reply-To"] == "<inbound@sender.test>"
      assert payload["headers"]["References"] == "<inbound@sender.test>"
      assert payload["headers"]["Message-ID"] == "<new@zaq.local>"
    end

    test "an email:imap send with no parent is not a reply — no Re:" do
      payload = send_and_capture(outgoing(%{provider: :"email:imap"}))

      assert payload["subject"] == "Topic A"
    end
  end

  describe "delivery receipt" do
    test "thread_metadata carries the channel-agnostic anchor verbatim" do
      {:ok, receipt} =
        EmailBridge.send_reply(
          outgoing(%{
            in_reply_to: "<mid@sender.test>",
            threading: %{
              "message_id" => "own@zaq.local",
              "references" => ["root@sender.test", "mid@sender.test"]
            }
          }),
          %{}
        )

      assert receipt.thread_metadata["threading"]["anchor"] == receipt.anchor

      assert receipt.anchor == %{
               "message_id" => "own@zaq.local",
               "in_reply_to" => "mid@sender.test",
               "references" => ["root@sender.test", "mid@sender.test"],
               "thread_id" => "root@sender.test"
             }
    end

    test "thread_metadata carries only the generic anchor — no email residue" do
      {:ok, receipt} = EmailBridge.send_reply(outgoing(%{}), %{})

      assert receipt.thread_metadata["threading"]["anchor"]["message_id"] == "new@zaq.local"
      refute Map.has_key?(receipt.thread_metadata, "email")
    end
  end
end
