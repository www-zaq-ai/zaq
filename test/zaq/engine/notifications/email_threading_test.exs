defmodule Zaq.Engine.Notifications.EmailThreadingTest do
  @moduledoc """
  Outbound email threading through the real seam: `Notifications` resolves the
  opaque anchor and passes it down; the real `EmailBridge` mints the Message-ID,
  builds the RFC headers, and returns the delivery receipt; the engine surfaces
  the receipt on `:sent` only.

  Only the SMTP boundary is stubbed — the notification travels through
  `Channels.Api` and `EmailBridge.send_reply` exactly as in production, so these
  tests observe the headers the recipient's mail client would actually see.
  """
  use Zaq.DataCase, async: false

  @moduletag capture_log: true

  import Ecto.Query

  alias Zaq.Accounts.People
  alias Zaq.Accounts.PersonChannel
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Engine.Notifications
  alias Zaq.Repo

  # ── Stubs ──────────────────────────────────────────────────────────

  defmodule StubNodeRouter do
    def dispatch(event) do
      api_module = Keyword.get(event.opts, :channels_api_module, Zaq.Channels.Api)
      action = Keyword.get(event.opts, :action, :invoke)

      api_module =
        if action == :bridge_available,
          do: Zaq.Engine.Notifications.EmailThreadingTest.AlwaysAvailableChannelsApi,
          else: api_module

      api_module.handle_event(event, action, nil)
    end
  end

  defmodule AlwaysAvailableChannelsApi do
    alias Zaq.Channels.Api

    def handle_event(event, :bridge_available, _context), do: %{event | response: true}
    def handle_event(event, action, context), do: Api.handle_event(event, action, context)
  end

  # Routes delivery to the REAL EmailBridge — the hop under test.
  defmodule RealEmailBridgeRouter do
    def bridge_for(_provider), do: Zaq.Channels.EmailBridge
    def fetch_connection_details(_provider), do: %{}
  end

  # SMTP boundary stubs — the only stubbed hop.
  defmodule CapturingSmtp do
    def send_notification(recipient, payload, _metadata) do
      send(self(), {:smtp, recipient, payload})
      :ok
    end
  end

  defmodule FailingSmtp do
    def send_notification(_recipient, _payload, _metadata), do: {:error, :smtp_down}
  end

  # Chat-channel stub: a bridge without receipts, returning bare `:ok`.
  defmodule CapturingChatBridge do
    def bridge_for(_provider), do: __MODULE__
    def fetch_connection_details(_provider), do: %{}

    def send_reply(%Outgoing{} = outgoing, _connection_details) do
      send(self(), {:delivered, outgoing})
      :ok
    end
  end

  # ── Fixtures ───────────────────────────────────────────────────────

  defp smtp_config(settings \\ %{"from_email" => "bot@acme.test"}) do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "Email-#{System.unique_integer([:positive])}",
      provider: "email:smtp",
      kind: "retrieval",
      url: "smtp://localhost",
      token: "test-token",
      enabled: true,
      settings: settings
    })
    |> Repo.insert!()
  end

  defp person_with_email do
    {:ok, person} =
      People.create_person(%{full_name: "Lead #{System.unique_integer([:positive])}"})

    Repo.insert!(%PersonChannel{
      person_id: person.id,
      platform: "email",
      channel_identifier: "lead-#{System.unique_integer([:positive])}@example.test",
      weight: 1
    })

    person
  end

  defp seed_prior_send(person, topic, message_id, references) do
    {:ok, conv} =
      Conversations.create_conversation(%{
        channel_type: "email:imap",
        channel_user_id: topic,
        person_id: person.id
      })

    {:ok, _msg} =
      Conversations.add_message(conv, %{
        role: "assistant",
        content: "prior send",
        metadata: %{
          "topic" => topic,
          "email" => %{
            "threading" => %{"message_id" => message_id, "references" => references}
          }
        }
      })

    conv
  end

  defp notify(person, subject, opts \\ []) do
    bridge = Keyword.get(opts, :bridge, RealEmailBridgeRouter)

    Notifications.notify_person(
      person.id,
      %{subject: subject, message: "hello"},
      channels_event_opts: [bridge_module: bridge]
    )
  end

  defp captured_headers do
    receive do
      {:smtp, _recipient, payload} -> payload["headers"]
    after
      0 -> flunk("no SMTP delivery captured")
    end
  end

  setup do
    Application.put_env(:zaq, :notifications_node_router_module, StubNodeRouter)
    Application.put_env(:zaq, :email_bridge_notification_module, CapturingSmtp)

    on_exit(fn ->
      Application.delete_env(:zaq, :notifications_node_router_module)
      Application.delete_env(:zaq, :email_bridge_notification_module)
    end)

    from(c in ChannelConfig, where: c.provider == "email:smtp") |> Repo.delete_all()
    smtp_config()

    :ok
  end

  # ── First send: mint only, no anchor ───────────────────────────────

  describe "first send (no anchor)" do
    test "mints a Message-ID, sets no In-Reply-To, and is its own thread root" do
      person = person_with_email()

      assert {:ok, result} = notify(person, "Topic A")
      headers = captured_headers()

      assert headers["Message-ID"] =~ ~r/^<zaq-[0-9a-f-]{36}@acme\.test>$/
      refute Map.has_key?(headers, "In-Reply-To")
      refute Map.has_key?(headers, "References")

      # Generic threading fields surfaced on the result, matching the wire.
      assert result.status == :sent
      assert headers["Message-ID"] == "<#{result.message_id}>"
      # First send is the root of its own thread.
      assert result.thread_id == result.message_id
      assert result.thread_metadata["email"]["threading"]["references"] == []
    end

    test "falls back to the default domain when no SMTP from_email is configured" do
      from(c in ChannelConfig, where: c.provider == "email:smtp") |> Repo.delete_all()
      smtp_config(%{})
      person = person_with_email()

      assert {:ok, result} = notify(person, "Topic A")

      assert result.message_id =~ ~r/@zaq\.local$/
    end
  end

  # ── Follow-up send: chains onto the anchor ─────────────────────────

  describe "follow-up send (anchor present)" do
    test "points In-Reply-To at the prior Message-ID and extends the references chain" do
      person = person_with_email()
      seed_prior_send(person, "Topic A", "m1@acme.test", [])

      assert {:ok, result} = notify(person, "Topic A")
      headers = captured_headers()

      # In-Reply-To points at the prior send; References = prior chain ++ [parent].
      assert headers["In-Reply-To"] == "<m1@acme.test>"
      assert headers["References"] == "<m1@acme.test>"
      # One-message thread → the prior message is the root.
      assert result.thread_id == "m1@acme.test"

      # This send mints its own fresh id, distinct from the parent.
      refute result.message_id == "m1@acme.test"
      assert headers["Message-ID"] == "<#{result.message_id}>"
    end

    test "carries the existing root and appends the parent to a longer chain" do
      person = person_with_email()
      seed_prior_send(person, "Topic A", "m2@acme.test", ["m0@acme.test", "m1@acme.test"])

      assert {:ok, result} = notify(person, "Topic A")
      headers = captured_headers()

      assert headers["In-Reply-To"] == "<m2@acme.test>"
      assert headers["References"] == "<m0@acme.test> <m1@acme.test> <m2@acme.test>"

      # Root stays the head of the chain.
      assert result.thread_id == "m0@acme.test"
    end

    # Bug #1: the inbound parser stores references as a space-joined string.
    test "tolerates a string references chain on the anchor (parser shape)" do
      person = person_with_email()
      seed_prior_send(person, "Topic A", "m2@acme.test", "<m0@acme.test> <m1@acme.test>")

      assert {:ok, _result} = notify(person, "Topic A")
      headers = captured_headers()

      assert headers["References"] == "<m0@acme.test> <m1@acme.test> <m2@acme.test>"
    end

    test "does not chain onto another person's send under the same topic" do
      lead_a = person_with_email()
      lead_b = person_with_email()
      seed_prior_send(lead_a, "Topic A", "a1@acme.test", [])

      assert {:ok, _result} = notify(lead_b, "Topic A")
      headers = captured_headers()

      refute Map.has_key?(headers, "In-Reply-To")
    end
  end

  # ── Grouping guard ─────────────────────────────────────────────────

  describe "grouping guard" do
    # Writing email.thread_key would re-key the conversation to the minted id, and
    # the next topic/subject lookup would miss it — breaking the chain.
    test "the surfaced residue never carries a thread_key" do
      person = person_with_email()

      assert {:ok, result} = notify(person, "Topic A")

      refute Map.has_key?(result.thread_metadata["email"], "thread_key")
      refute Map.has_key?(result.thread_metadata["email"]["threading"], "thread_key")
    end
  end

  # ── Store-only-on-success (Bug #3) ─────────────────────────────────

  describe "store-only-on-success (Bug #3)" do
    test "surfaces no threading when delivery fails on every channel" do
      Application.put_env(:zaq, :email_bridge_notification_module, FailingSmtp)
      person = person_with_email()

      assert {:error, failed} = notify(person, "Topic A")

      assert failed.status == :failed
      refute Map.has_key?(failed, :message_id)
      refute Map.has_key?(failed, :thread_id)
      refute Map.has_key?(failed, :thread_metadata)
    end

    test "a failed send leaves no anchor for the next send" do
      Application.put_env(:zaq, :email_bridge_notification_module, FailingSmtp)
      person = person_with_email()

      assert {:error, _} = notify(person, "Topic A")

      # Nothing was persisted, so the anchor lookup still finds nothing.
      assert Conversations.thread_anchor(person.id, "email:smtp", "Topic A", "Topic A") == nil
    end

    test "surfaces no threading on a skipped notification" do
      {:ok, person} = People.create_person(%{full_name: "No Channels"})

      assert {:ok, result} = Notifications.notify_person(person.id, %{subject: "T", message: "b"})

      assert result.status == :skipped
      refute Map.has_key?(result, :message_id)
      refute Map.has_key?(result, :thread_metadata)
    end
  end

  # ── Non-email channels untouched ───────────────────────────────────

  describe "non-email channels" do
    test "a chat notification gets no anchor, no receipt fields, no email metadata" do
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "MM-#{System.unique_integer([:positive])}",
        provider: "mattermost",
        kind: "retrieval",
        url: "https://mm.test",
        token: "t",
        enabled: true
      })
      |> Repo.insert!()

      {:ok, person} = People.create_person(%{full_name: "Chat Person"})

      Repo.insert!(%PersonChannel{
        person_id: person.id,
        platform: "mattermost",
        channel_identifier: "U123",
        weight: 1
      })

      assert {:ok, result} = notify(person, "Topic A", bridge: CapturingChatBridge)

      assert_receive {:delivered, %Outgoing{} = outgoing}
      refute Map.has_key?(outgoing.metadata, "email")
      assert outgoing.thread_anchor == nil
      assert outgoing.in_reply_to == nil
      refute Map.has_key?(result, :message_id)
    end
  end
end
