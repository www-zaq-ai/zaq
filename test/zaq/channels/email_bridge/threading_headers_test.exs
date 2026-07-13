defmodule Zaq.Channels.EmailBridge.ThreadingHeadersTest do
  @moduledoc """
  Step 4: the email bridge emits `Message-ID` for every email send, and
  `In-Reply-To`/`References` whenever a parent is present — while keeping the
  `Re:` prefix exclusive to genuine inbound replies.

  The two predicates are deliberately decoupled:

    * `inbound_reply?` (provider == email:imap + in_reply_to) → drives `Re:` only
    * `thread?`        (in_reply_to present, any email provider) → drives headers

  A proactive sequence therefore threads via headers while keeping the clean
  subject the campaign topic defines.
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
    Application.put_env(:zaq, :email_bridge_notification_module, CapturingNotification)
    on_exit(fn -> Application.delete_env(:zaq, :email_bridge_notification_module) end)
    :ok
  end

  defp send_and_capture(%Outgoing{} = outgoing) do
    :ok = EmailBridge.send_reply(outgoing, %{})

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
        "email" => %{"threading" => threading}
      }
    }
  end

  describe "Message-ID emission" do
    test "always emits the minted Message-ID for an email send" do
      payload = send_and_capture(outgoing(%{}))

      assert payload["headers"]["Message-ID"] == "<new@zaq.local>"
    end

    test "emits no Message-ID when none was minted" do
      out = %Outgoing{
        body: "hello",
        channel_id: "lead@example.test",
        provider: :"email:smtp",
        metadata: %{"subject" => "Topic A"}
      }

      payload = send_and_capture(out)

      refute Map.has_key?(payload["headers"], "Message-ID")
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
end
