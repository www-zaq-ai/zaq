defmodule Zaq.Channels.EmailBridgeTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.EmailBridge
  alias Zaq.Engine.Notifications.EmailNotification

  defmodule DynamicAdapterStub do
    def to_internal(payload, connection_details) do
      send(self(), {:dynamic_adapter_called, payload, connection_details})

      %Zaq.Engine.Messages.Incoming{
        content: "ok",
        channel_id: "INBOX",
        provider: :"email:imap",
        metadata: %{}
      }
    end
  end

  defmodule MailboxTupleAdapterStub do
    def list_mailboxes(_config) do
      {:ok,
       [
         {"INBOX", "/", ["\\HasNoChildren"]},
         {"HR", "/", ["\\HasChildren"]},
         {"INBOX", "/", ["\\HasNoChildren"]}
       ]}
    end
  end

  defmodule LegacyMailboxTupleAdapterStub do
    def list_mailboxes(_config) do
      {:error,
       {:list_mailboxes_failed,
        {:ok,
         [
           {"INBOX", "/", ["\\HasNoChildren"]},
           {"HR", "/", ["\\HasChildren"]},
           {"INBOX", "/", ["\\HasNoChildren"]}
         ]}}}
    end
  end

  defmodule RuntimeListenerStub do
    use GenServer

    def start_link(opts) when is_list(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl GenServer
    def init(opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      mailbox = Keyword.fetch!(opts, :mailbox)
      send(test_pid, {:runtime_listener_started, mailbox, self()})
      {:ok, %{mailbox: mailbox}}
    end
  end

  defmodule RuntimeAdapterStub do
    def runtime_specs(config, bridge_id, _opts) do
      selected =
        config
        |> Map.get(:selected_mailboxes, [])
        |> List.wrap()

      listeners =
        Enum.map(selected, fn mailbox ->
          %{
            id: {RuntimeListenerStub, "#{bridge_id}:#{mailbox}"},
            start: {RuntimeListenerStub, :start_link, [[mailbox: mailbox, test_pid: self()]]},
            restart: :permanent,
            type: :worker
          }
        end)

      {:ok, {nil, listeners}}
    end
  end

  defmodule IncomingAdapterStub do
    def to_internal(_payload, _connection_details) do
      %Zaq.Engine.Messages.Incoming{
        content: "incoming",
        channel_id: "author@example.com",
        author_id: "author@example.com",
        provider: :"email:imap",
        metadata: %{"email" => %{}}
      }
    end
  end

  defmodule IncomingAdapterErrorStub do
    def to_internal(_payload, _connection_details), do: {:error, :invalid_payload}
  end

  defmodule PipelineOkStub do
    def run(_incoming, _opts) do
      %Zaq.Engine.Messages.Outgoing{
        body: "outgoing",
        channel_id: "recipient@example.com",
        provider: :email,
        metadata: %{"subject" => "Pipeline subject"}
      }
    end
  end

  defmodule RouterOkStub do
    def deliver(_outgoing), do: :ok
  end

  defmodule RouterErrorStub do
    def deliver(_outgoing), do: {:error, :delivery_failed}
  end

  defmodule ConversationsOkStub do
    def persist_from_incoming(_incoming, _metadata), do: :ok
  end

  defmodule ConversationsErrorStub do
    def persist_from_incoming(_incoming, _metadata), do: {:error, :persist_failed}
  end

  defp smtp_settings(overrides \\ %{}) do
    Map.merge(
      %{
        "relay" => "",
        "port" => "587",
        "transport_mode" => "starttls",
        "tls" => "enabled",
        "tls_verify" => "verify_peer",
        "ca_cert_path" => nil,
        "username" => nil,
        "password" => nil,
        "from_email" => "noreply@example.com",
        "from_name" => "ZAQ"
      },
      overrides
    )
  end

  defp upsert_smtp_channel(attrs \\ %{}) do
    defaults = %{
      name: "Email SMTP",
      kind: "retrieval",
      enabled: true,
      settings: smtp_settings()
    }

    assert {:ok, _channel} =
             ChannelConfig.upsert_by_provider("email:smtp", Map.merge(defaults, attrs))

    :ok
  end

  describe "to_internal/2" do
    test "maps imap payload into Incoming message" do
      payload = %{
        "body_text" => "hello from imap",
        "body_html" => "<p>hello from imap</p>",
        "from" => %{"address" => "alice@example.com", "name" => "Alice"},
        "subject" => "Hello",
        "message_id" => "<msg-1@example.com>",
        "in_reply_to" => "<root@example.com>",
        "references" => "<a@example.com> <root@example.com>",
        "attachments" => [
          %{
            "filename" => "manual.pdf",
            "content_type" => "application/pdf",
            "download_ref" => "att-1"
          }
        ]
      }

      assert incoming =
               EmailBridge.to_internal(payload, %{
                 mailbox: "INBOX",
                 adapter: Zaq.Channels.EmailBridge.ImapAdapter
               })

      assert incoming.content == "hello from imap"
      assert incoming.channel_id == "alice@example.com"
      assert incoming.author_id == "alice@example.com"
      assert incoming.author_name == "Alice"
      assert incoming.thread_id == "a@example.com"
      assert incoming.message_id == "<msg-1@example.com>"
      assert incoming.provider == :"email:imap"
      assert incoming.metadata["email"]["html_body"] == "<p>hello from imap</p>"

      assert [%{"filename" => "manual.pdf", "download_ref" => "att-1"}] =
               incoming.metadata["email"]["attachments"]
    end

    test "dispatches to adapter passed through connection details" do
      payload = %{"body_text" => "hello"}
      details = %{adapter: DynamicAdapterStub, mailbox: "INBOX"}

      assert %Zaq.Engine.Messages.Incoming{} = EmailBridge.to_internal(payload, details)
      assert_received {:dynamic_adapter_called, ^payload, ^details}
    end
  end

  describe "email:smtp notification delivery" do
    test "delivers notifications using the email:smtp ChannelConfig" do
      upsert_smtp_channel()

      payload = %{"subject" => "Test subject", "body" => "Test body"}

      assert :ok = EmailNotification.send_notification("recipient@example.com", payload, %{})

      assert_receive {:email, email}
      assert email.to == [{"", "recipient@example.com"}]
      assert email.subject == "Test subject"
      assert email.from == {"ZAQ", "noreply@zaq.local"}
    end

    test "uses default sender when no email:smtp ChannelConfig exists" do
      payload = %{"subject" => "Fallback", "body" => "Hello"}

      assert :ok = EmailNotification.send_notification("recipient@example.com", payload, %{})

      assert_receive {:email, email}
      assert email.from == {"ZAQ", "noreply@zaq.local"}
    end

    test "send_reply sets In-Reply-To and References headers" do
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Reply body",
        channel_id: "recipient@example.com",
        provider: :"email:imap",
        in_reply_to: "<msg-2@example.com>",
        metadata: %{
          "email" => %{
            "subject" => "Support request",
            "reply_from" => "julien@eweev.com",
            "headers" => %{"references" => "<msg-1@example.com> <msg-2@example.com>"}
          }
        }
      }

      assert :ok = EmailBridge.send_reply(outgoing, %{})

      assert_receive {:email, email}
      assert email.subject == "Re: Support request"
      assert email.from == {"ZAQ", "julien@eweev.com"}
      assert {"In-Reply-To", "<msg-2@example.com>"} in email.headers
      assert {"References", "<msg-1@example.com> <msg-2@example.com>"} in email.headers
    end

    test "send_reply keeps subject unchanged for non-reply emails" do
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Notification body",
        channel_id: "recipient@example.com",
        provider: :email,
        metadata: %{"subject" => "Security alert"}
      }

      assert :ok = EmailBridge.send_reply(outgoing, %{})

      assert_receive {:email, email}
      assert email.subject == "Security alert"
      assert email.from == {"ZAQ", "noreply@zaq.local"}
      refute Enum.any?(email.headers, fn {k, _v} -> k in ["In-Reply-To", "References"] end)
    end

    test "send_reply keeps canonical message-id casing for threading headers" do
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Reply body",
        channel_id: "recipient@example.com",
        provider: :"email:imap",
        in_reply_to: "<AbC123@Example.COM>",
        metadata: %{
          "email" => %{
            "subject" => "Threaded question",
            "reply_from" => "julien@eweev.com",
            "threading" => %{"references" => "<Root42@Example.com>"}
          }
        }
      }

      assert :ok = EmailBridge.send_reply(outgoing, %{})

      assert_receive {:email, email}
      assert email.subject == "Re: Threaded question"
      assert email.from == {"ZAQ", "julien@eweev.com"}
      assert {"In-Reply-To", "<AbC123@Example.COM>"} in email.headers
      assert {"References", "<Root42@Example.com> <AbC123@Example.COM>"} in email.headers
    end
  end

  describe "list_mailboxes/2" do
    test "normalizes tuple mailbox entries from adapter" do
      previous = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{
        :"email:imap" => %{adapter: MailboxTupleAdapterStub}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      assert {:ok, ["HR", "INBOX"]} =
               EmailBridge.list_mailboxes(%{provider: "email:imap"}, %{})
    end

    test "accepts legacy wrapped list_mailboxes_failed ok payload" do
      previous = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{
        :"email:imap" => %{adapter: LegacyMailboxTupleAdapterStub}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      assert {:ok, ["HR", "INBOX"]} =
               EmailBridge.list_mailboxes(%{provider: "email:imap"}, %{})
    end
  end

  describe "from_listener/3" do
    setup do
      previous_pipeline = Application.get_env(:zaq, :email_bridge_pipeline_module)
      previous_router = Application.get_env(:zaq, :email_bridge_router_module)
      previous_conversations = Application.get_env(:zaq, :email_bridge_conversations_module)

      on_exit(fn ->
        Application.put_env(:zaq, :email_bridge_pipeline_module, previous_pipeline)
        Application.put_env(:zaq, :email_bridge_router_module, previous_router)
        Application.put_env(:zaq, :email_bridge_conversations_module, previous_conversations)
      end)

      :ok
    end

    test "processes inbound payload end-to-end" do
      Application.put_env(:zaq, :email_bridge_pipeline_module, PipelineOkStub)
      Application.put_env(:zaq, :email_bridge_router_module, RouterOkStub)
      Application.put_env(:zaq, :email_bridge_conversations_module, ConversationsOkStub)

      config = %{provider: "email:imap"}

      assert :ok =
               EmailBridge.from_listener(
                 config,
                 %{"body_text" => "hello"},
                 adapter: IncomingAdapterStub,
                 mailbox: "INBOX"
               )
    end

    test "returns adapter conversion error" do
      Application.put_env(:zaq, :email_bridge_pipeline_module, PipelineOkStub)
      Application.put_env(:zaq, :email_bridge_router_module, RouterOkStub)
      Application.put_env(:zaq, :email_bridge_conversations_module, ConversationsOkStub)

      config = %{provider: "email:imap"}

      assert {:error, :invalid_payload} =
               EmailBridge.from_listener(
                 config,
                 %{"body_text" => "hello"},
                 adapter: IncomingAdapterErrorStub,
                 mailbox: "INBOX"
               )
    end

    test "returns delivery error" do
      Application.put_env(:zaq, :email_bridge_pipeline_module, PipelineOkStub)
      Application.put_env(:zaq, :email_bridge_router_module, RouterErrorStub)
      Application.put_env(:zaq, :email_bridge_conversations_module, ConversationsOkStub)

      config = %{provider: "email:imap"}

      assert {:error, :delivery_failed} =
               EmailBridge.from_listener(
                 config,
                 %{"body_text" => "hello"},
                 adapter: IncomingAdapterStub,
                 mailbox: "INBOX"
               )
    end

    test "returns persistence error" do
      Application.put_env(:zaq, :email_bridge_pipeline_module, PipelineOkStub)
      Application.put_env(:zaq, :email_bridge_router_module, RouterOkStub)
      Application.put_env(:zaq, :email_bridge_conversations_module, ConversationsErrorStub)

      config = %{provider: "email:imap"}

      assert {:error, :persist_failed} =
               EmailBridge.from_listener(
                 config,
                 %{"body_text" => "hello"},
                 adapter: IncomingAdapterStub,
                 mailbox: "INBOX"
               )
    end
  end

  describe "start_runtime/1" do
    test "restarts running runtime to apply updated selected mailboxes" do
      previous_channels = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{
        :email => %{adapter: RuntimeAdapterStub},
        :"email:imap" => %{adapter: RuntimeAdapterStub}
      })

      config_id = System.unique_integer([:positive])
      bridge_id = "email:imap_#{config_id}"

      initial_config = %{
        id: config_id,
        provider: "email:imap",
        settings: %{"imap" => %{"selected_mailboxes" => ["INBOX"]}}
      }

      updated_config =
        put_in(initial_config, [:settings, "imap", "selected_mailboxes"], ["Support", "Sales"])

      on_exit(fn ->
        _ = EmailBridge.stop_runtime(initial_config)
        Application.put_env(:zaq, :channels, previous_channels)
      end)

      assert :ok = EmailBridge.start_runtime(initial_config)
      assert_receive {:runtime_listener_started, "INBOX", _pid}, 500

      assert {:ok, runtime} = Zaq.Channels.Supervisor.lookup_runtime(bridge_id)
      assert Enum.sort(Enum.map(runtime.listener_pids, &listener_mailbox/1)) == ["INBOX"]

      assert :ok = EmailBridge.start_runtime(updated_config)
      assert_receive {:runtime_listener_started, "Support", _pid}, 500
      assert_receive {:runtime_listener_started, "Sales", _pid}, 500

      assert {:ok, refreshed_runtime} = Zaq.Channels.Supervisor.lookup_runtime(bridge_id)

      assert Enum.sort(Enum.map(refreshed_runtime.listener_pids, &listener_mailbox/1)) ==
               ["Sales", "Support"]
    end
  end

  defp listener_mailbox(pid) when is_pid(pid) do
    pid
    |> :sys.get_state()
    |> Map.fetch!(:mailbox)
  end
end
