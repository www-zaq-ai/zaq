defmodule Zaq.Engine.Notifications.EmailThreadingTest do
  @moduledoc """
  Step 3 of the outbound email threading plan: `Notifications` mints the
  Message-ID, resolves the anchor, sets the generic `Outgoing.thread_id` /
  `in_reply_to`, and surfaces the threading result on `:sent` only.

  The bridge is stubbed so we can capture the exact `%Outgoing{}` that would be
  delivered.
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

  defmodule CapturingBridge do
    def bridge_for(_provider), do: __MODULE__
    def fetch_connection_details(_provider), do: %{}

    def send_reply(%Outgoing{} = outgoing, _connection_details) do
      send(self(), {:delivered, outgoing})
      :ok
    end
  end

  defmodule FailingBridge do
    def bridge_for(_provider), do: __MODULE__
    def fetch_connection_details(_provider), do: %{}

    def send_reply(%Outgoing{} = outgoing, _connection_details) do
      send(self(), {:delivered, outgoing})
      {:error, :smtp_down}
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
    bridge = Keyword.get(opts, :bridge, CapturingBridge)

    Notifications.notify_person(
      person.id,
      %{subject: subject, message: "hello"},
      channels_event_opts: [bridge_module: bridge]
    )
  end

  defp captured_outgoing do
    receive do
      {:delivered, %Outgoing{} = outgoing} -> outgoing
    after
      0 -> nil
    end
  end

  setup do
    Application.put_env(:zaq, :notifications_node_router_module, StubNodeRouter)
    on_exit(fn -> Application.delete_env(:zaq, :notifications_node_router_module) end)

    from(c in ChannelConfig, where: c.provider == "email:smtp") |> Repo.delete_all()
    smtp_config()

    :ok
  end

  # ── First send: mint only, no anchor ───────────────────────────────

  describe "first send (no anchor)" do
    test "mints a Message-ID, sets no in_reply_to, and is its own thread root" do
      person = person_with_email()

      assert {:ok, result} = notify(person, "Topic A")
      outgoing = captured_outgoing()

      threading = outgoing.metadata["email"]["threading"]

      assert threading["message_id"] =~ ~r/^zaq-[0-9a-f-]{36}@acme\.test$/
      assert threading["in_reply_to"] == nil
      assert threading["references"] == []

      assert outgoing.in_reply_to == nil
      # First send is the root of its own thread.
      assert outgoing.thread_id == threading["message_id"]

      # Generic threading fields surfaced on the result.
      assert result.status == :sent
      assert result.message_id == threading["message_id"]
      assert result.thread_id == threading["message_id"]
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
    test "sets in_reply_to to the prior Message-ID and extends the references chain" do
      person = person_with_email()
      seed_prior_send(person, "Topic A", "m1@acme.test", [])

      assert {:ok, result} = notify(person, "Topic A")
      outgoing = captured_outgoing()
      threading = outgoing.metadata["email"]["threading"]

      # In-Reply-To points at the prior send.
      assert outgoing.in_reply_to == "m1@acme.test"
      assert threading["in_reply_to"] == "m1@acme.test"
      # References = prior chain ++ [parent].
      assert threading["references"] == ["m1@acme.test"]
      # One-message thread → the prior message is the root.
      assert outgoing.thread_id == "m1@acme.test"
      assert result.thread_id == "m1@acme.test"

      # This send mints its own fresh id, distinct from the parent.
      refute threading["message_id"] == "m1@acme.test"
      assert result.message_id == threading["message_id"]
    end

    test "carries the existing root and appends the parent to a longer chain" do
      person = person_with_email()
      seed_prior_send(person, "Topic A", "m2@acme.test", ["m0@acme.test", "m1@acme.test"])

      assert {:ok, result} = notify(person, "Topic A")
      outgoing = captured_outgoing()

      assert outgoing.in_reply_to == "m2@acme.test"

      assert outgoing.metadata["email"]["threading"]["references"] == [
               "m0@acme.test",
               "m1@acme.test",
               "m2@acme.test"
             ]

      # Root stays the head of the chain.
      assert outgoing.thread_id == "m0@acme.test"
      assert result.thread_id == "m0@acme.test"
    end

    # Bug #1: the inbound parser stores references as a space-joined string.
    test "tolerates a string references chain on the anchor (parser shape)" do
      person = person_with_email()
      seed_prior_send(person, "Topic A", "m2@acme.test", "<m0@acme.test> <m1@acme.test>")

      assert {:ok, _result} = notify(person, "Topic A")
      outgoing = captured_outgoing()

      assert outgoing.metadata["email"]["threading"]["references"] == [
               "m0@acme.test",
               "m1@acme.test",
               "m2@acme.test"
             ]
    end

    test "does not chain onto another person's send under the same topic" do
      lead_a = person_with_email()
      lead_b = person_with_email()
      seed_prior_send(lead_a, "Topic A", "a1@acme.test", [])

      assert {:ok, _result} = notify(lead_b, "Topic A")
      outgoing = captured_outgoing()

      assert outgoing.in_reply_to == nil
    end
  end

  # ── Grouping guard ─────────────────────────────────────────────────

  describe "grouping guard" do
    # Writing email.thread_key would re-key the conversation to the minted id, and
    # the next topic/subject lookup would miss it — breaking the chain.
    test "never sets metadata.email.thread_key" do
      person = person_with_email()

      assert {:ok, _result} = notify(person, "Topic A")
      outgoing = captured_outgoing()

      refute Map.has_key?(outgoing.metadata["email"], "thread_key")
      refute Map.has_key?(outgoing.metadata, "thread_key")
    end
  end

  # ── Store-only-on-success (Bug #3) ─────────────────────────────────

  describe "store-only-on-success (Bug #3)" do
    test "surfaces no threading when delivery fails on every channel" do
      person = person_with_email()

      assert {:error, failed} = notify(person, "Topic A", bridge: FailingBridge)

      assert failed.status == :failed
      refute Map.has_key?(failed, :message_id)
      refute Map.has_key?(failed, :thread_id)
      refute Map.has_key?(failed, :thread_metadata)
    end

    test "a failed send leaves no anchor for the next send" do
      person = person_with_email()

      assert {:error, _} = notify(person, "Topic A", bridge: FailingBridge)

      # Nothing was persisted, so the anchor lookup still finds nothing.
      assert Conversations.email_thread_anchor(person.id, "Topic A", "Topic A") == nil
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
    test "a chat notification mints nothing and sets no threading metadata" do
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

      assert {:ok, result} = notify(person, "Topic A")
      outgoing = captured_outgoing()

      refute Map.has_key?(outgoing.metadata, "email")
      assert outgoing.in_reply_to == nil
      refute Map.has_key?(result, :message_id)
    end
  end
end
