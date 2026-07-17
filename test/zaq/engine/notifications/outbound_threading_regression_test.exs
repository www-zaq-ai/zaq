defmodule Zaq.Engine.Notifications.OutboundThreadingRegressionTest do
  @moduledoc """
  Reproduces the production failure the outbound-threading plan was meant to fix:
  two proactive emails to the same person + subject still land in separate Gmail
  threads (run `4a8aad3d`, conversation `7c40de0f`, 2026-07-14).

  Nothing is seeded and nothing is stubbed except the SMTP boundary: send 1 must
  leave behind the anchor send 2 needs, through the real `Channels.Api` →
  `EmailBridge` delivery path, no matter how the workflow DAG is wired.
  """
  use Zaq.DataCase, async: false

  @moduletag capture_log: true

  import Ecto.Query

  alias Zaq.Accounts.People
  alias Zaq.Accounts.PersonChannel
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Notifications
  alias Zaq.Repo

  defmodule StubNodeRouter do
    def dispatch(event) do
      api_module = Keyword.get(event.opts, :channels_api_module, Zaq.Channels.Api)
      action = Keyword.get(event.opts, :action, :invoke)

      api_module =
        if action == :bridge_available,
          do: Zaq.Engine.Notifications.OutboundThreadingRegressionTest.AlwaysAvailableChannelsApi,
          else: api_module

      api_module.handle_event(event, action, nil)
    end
  end

  defmodule AlwaysAvailableChannelsApi do
    alias Zaq.Channels.Api

    def handle_event(event, :bridge_available, _context), do: %{event | response: true}
    def handle_event(event, action, context), do: Api.handle_event(event, action, context)
  end

  # Routes delivery to the REAL EmailBridge — only SMTP is stubbed.
  defmodule RealEmailBridgeRouter do
    def bridge_for(_provider), do: Zaq.Channels.EmailBridge
    def fetch_connection_details(_provider), do: %{}
  end

  defmodule CapturingSmtp do
    def send_notification(recipient, payload, _metadata) do
      send(self(), {:smtp, recipient, payload})
      :ok
    end
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

  defp notify(person, subject) do
    Notifications.notify_person(
      person.id,
      %{subject: subject, message: "hello"},
      channels_event_opts: [bridge_module: RealEmailBridgeRouter]
    )
  end

  defp captured_headers do
    receive do
      {:smtp, _recipient, payload} -> payload["headers"]
    after
      0 -> nil
    end
  end

  defp unbracket("<" <> rest), do: String.trim_trailing(rest, ">")
  defp unbracket(value), do: value

  setup do
    Application.put_env(:zaq, :notifications_node_router_module, StubNodeRouter)
    Application.put_env(:zaq, :email_bridge_smtp_module, CapturingSmtp)

    on_exit(fn ->
      Application.delete_env(:zaq, :notifications_node_router_module)
      Application.delete_env(:zaq, :email_bridge_smtp_module)
    end)

    from(c in ChannelConfig, where: c.provider == "email:smtp") |> Repo.delete_all()

    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "Email-#{System.unique_integer([:positive])}",
      provider: "email:smtp",
      kind: "retrieval",
      url: "smtp://localhost",
      token: "test-token",
      enabled: true,
      settings: %{"from_email" => "bot@acme.test"}
    })
    |> Repo.insert!()

    :ok
  end

  describe "two consecutive proactive sends (the production scenario)" do
    # The guarantee the plan's Goal states: "every follow-up carries In-Reply-To +
    # References pointing at the prior send, so the thread is deterministic."
    # Nothing is seeded here — send 1 must leave behind the anchor send 2 needs.
    test "send 2 threads onto send 1 without any workflow wiring the anchor through" do
      person = person_with_email()

      assert {:ok, first} = notify(person, "Instant AI label mockups")
      headers_one = captured_headers()
      minted = unbracket(headers_one["Message-ID"])

      assert is_binary(minted), "send 1 must mint a Message-ID"
      refute Map.has_key?(headers_one, "In-Reply-To"), "send 1 opens the thread"
      assert first.message_id == minted

      assert {:ok, _second} = notify(person, "Instant AI label mockups")
      headers_two = captured_headers()

      # This is what Gmail needs to fold send 2 into send 1's thread: without the
      # anchor round trip, every send would be a fresh root.
      assert headers_two["In-Reply-To"] == "<#{minted}>",
             "send 2 must point In-Reply-To at send 1's Message-ID, got: #{inspect(headers_two["In-Reply-To"])}"

      assert "<#{minted}>" in String.split(headers_two["References"] || "", " "),
             "send 2's References chain must contain send 1's Message-ID"
    end
  end

  describe "the workflow definition running in production" do
    # The stored `send_email -> update_history` edge (workflow 44f9d42f, updated
    # 2026-07-12) maps only `topic` and `person`, so the send's `thread_metadata`
    # is dropped at the edge and the persisted message carries no threading. That
    # must not break the chain: an anchor may not depend on how a DAG is wired,
    # or any workflow built or edited in the BO silently stops threading.
    test "threading survives a workflow whose edge drops thread_metadata" do
      person = person_with_email()
      topic = "Instant AI label mockups"

      assert {:ok, first} = notify(person, topic)
      minted = unbracket(captured_headers()["Message-ID"])

      # What `update_history` actually persists under the production mapping: the
      # message lands with topic/subject metadata and no `email.threading` key.
      {:ok, conv} =
        Conversations.create_conversation(%{
          channel_type: "email:imap",
          channel_user_id: topic,
          person_id: person.id
        })

      {:ok, _msg} =
        Conversations.add_message(conv, %{
          role: "assistant",
          content: "the email we just sent",
          metadata: %{
            "topic" => topic,
            "subject" => topic,
            "notification_log_id" => first.notification_log_id
          }
        })

      assert {:ok, _second} = notify(person, topic)
      headers_two = captured_headers()

      assert headers_two["In-Reply-To"] == "<#{minted}>",
             "send 2 must thread onto send 1 even though the DAG persisted no threading, got: #{inspect(headers_two["In-Reply-To"])}"

      assert "<#{minted}>" in String.split(headers_two["References"] || "", " ")
    end
  end
end
