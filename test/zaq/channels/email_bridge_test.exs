defmodule Zaq.Channels.EmailBridgeTest do
  use Zaq.DataCase, async: false
  import ExUnit.CaptureLog

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.EmailBridge
  alias Zaq.Channels.EmailBridge.ImapConfigHelpers
  alias Zaq.Channels.EmailBridge.SmtpSender
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Repo
  alias Zaq.SystemConfigFixtures

  defmodule UnresolvedIdentityResolver do
    def resolve(_incoming, _opts), do: {:error, :not_found}
    def person_payload(_person), do: raise("unexpected person payload")
  end

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

  defmodule MaterializationAdapterStub do
    def download_attachment(config, request) do
      send(self(), {:download_attachment, config, request})
      Process.get(:email_materialization_download_result, {:ok, "downloaded-bytes"})
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

  defmodule MailboxErrorAdapterStub do
    def list_mailboxes(_config), do: {:error, :imap_unreachable}
  end

  defmodule CaptureMailboxAdapterStub do
    def list_mailboxes(config) do
      send(self(), {:captured_mailbox_config, config})
      {:ok, ["INBOX"]}
    end
  end

  defmodule MixedMailboxAdapterStub do
    def list_mailboxes(_config) do
      {:ok, [%{mailbox: "INBOX"}, %{"mailbox" => "Support"}, "Sales", :skip]}
    end
  end

  defmodule RuntimeErrorAdapterStub do
    def runtime_specs(_config, _bridge_id, _opts), do: {:error, :runtime_failed}
  end

  defmodule RuntimeInvalidSpecAdapterStub do
    def runtime_specs(_config, _bridge_id, _opts) do
      {:ok, {nil, [%{id: :invalid_listener}]}}
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

  defmodule RuntimeCaptureAdapterStub do
    def runtime_specs(config, _bridge_id, _opts) do
      send(self(), {:captured_runtime_config, config})
      {:ok, {nil, []}}
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

  defmodule PipelineUnexpectedValueStub do
    def run(_incoming, _opts), do: :queued
  end

  defmodule RouterOkStub do
    def deliver(_outgoing), do: :ok
  end

  defmodule ApiDeliveryNodeRouterStub do
    def dispatch(event) do
      if event.opts[:action] == :deliver_outgoing do
        send(self(), {:api_delivery_event, event})
      end

      %{event | response: :ok}
    end
  end

  defmodule RouterErrorStub do
    def deliver(_outgoing), do: {:error, :delivery_failed}
  end

  defmodule RouterUnexpectedStub do
    def deliver(_outgoing), do: :queued
  end

  defmodule ConversationsOkStub do
    def persist_from_incoming(_incoming, _metadata), do: :ok
  end

  defmodule ConversationsErrorStub do
    def persist_from_incoming(_incoming, _metadata), do: {:error, :persist_failed}
  end

  defmodule NodeRouterOkStub do
    alias Zaq.Engine.Messages.Outgoing

    def dispatch(event) do
      response =
        case event.opts[:action] do
          :route_incoming_message ->
            %Outgoing{
              body: "from-node-router",
              channel_id: event.request.channel_id,
              provider: :email
            }

          :run_pipeline ->
            %Outgoing{
              body: "from-node-router",
              channel_id: event.request.channel_id,
              provider: :email
            }

          :deliver_outgoing ->
            {:ok, %{message_id: "delivered@zaq.test"}}

          _ ->
            {:error, :unsupported}
        end

      %{event | response: response}
    end

    def fire(event) do
      send(self(), {:node_router_fire_event, event})
      event
    end
  end

  defmodule NodeRouterBadPipelineStub do
    def dispatch(event), do: %{event | response: :unexpected}
  end

  defmodule NodeRouterErrorPipelineStub do
    def dispatch(event), do: %{event | response: {:error, :pipeline_failed}}
  end

  defmodule CapturingNodeRouterStub do
    alias Zaq.Engine.Messages.Outgoing

    def dispatch(event) do
      response =
        case event.opts[:action] do
          :route_incoming_message ->
            send(self(), {:node_router_route_incoming_event, event})

            %Outgoing{
              body: "captured",
              channel_id: event.request.channel_id,
              provider: :email,
              metadata: %{answer: "captured"}
            }

          :run_pipeline ->
            send(self(), {:node_router_run_pipeline_event, event})

            %Outgoing{
              body: "captured",
              channel_id: event.request.channel_id,
              provider: :email,
              metadata: %{answer: "captured"}
            }

          :deliver_outgoing ->
            :ok

          _ ->
            {:error, :unsupported}
        end

      %{event | response: response}
    end

    def fire(event) do
      send(self(), {:node_router_fire_event, event})
      event
    end
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
      config = %{id: 42}

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
                 config: config,
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
      assert incoming.routing_context.channel_config_id == 42
      assert incoming.metadata["email"]["html_body"] == "<p>hello from imap</p>"

      assert incoming.attachments == []
      refute Map.has_key?(incoming.metadata["email"], "attachments")
    end

    test "materializes email attachments through configured IMAP adapter" do
      previous = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{
        email: %{adapter: MaterializationAdapterStub}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      config = %{id: 3, provider: "email:imap"}

      request = %{
        "reference" => "email:3:10:42:2.1",
        "mailbox" => "INBOX",
        "uid_validity" => 10,
        "uid" => 42,
        "section" => "2.1",
        "name" => "invoice.pdf",
        "mime_type" => "application/pdf"
      }

      assert {:ok, %{record: record}} = EmailBridge.materialize_record(config, request, %{})
      assert record.id == "email:3:10:42:2.1"
      assert record.content == "downloaded-bytes"
      assert record.name == "invoice.pdf"
      assert record.mime_type == "application/pdf"
      assert record.attributes["encoding"] == "binary"

      assert_received {:download_attachment, ^config, ^request}
    end

    test "rejects invalid adapter download content" do
      previous = Application.get_env(:zaq, :channels)
      Application.put_env(:zaq, :channels, %{email: %{adapter: MaterializationAdapterStub}})
      Process.put(:email_materialization_download_result, {:ok, :not_binary})

      on_exit(fn ->
        Application.put_env(:zaq, :channels, previous)
        Process.delete(:email_materialization_download_result)
      end)

      config = %{id: 3, provider: "email:imap"}
      request = %{"mailbox" => "INBOX", "uid_validity" => 10, "uid" => 42, "section" => "2.1"}

      assert {:error, :invalid_media_content} =
               EmailBridge.materialize_record(config, request, %{})

      assert_received {:download_attachment, ^config, ^request}
    end

    test "returns unexpected adapter download result" do
      previous = Application.get_env(:zaq, :channels)
      Application.put_env(:zaq, :channels, %{email: %{adapter: MaterializationAdapterStub}})
      Process.put(:email_materialization_download_result, :unexpected_download_result)

      on_exit(fn ->
        Application.put_env(:zaq, :channels, previous)
        Process.delete(:email_materialization_download_result)
      end)

      config = %{id: 3, provider: "email:imap"}
      request = %{"mailbox" => "INBOX", "uid_validity" => 10, "uid" => 42, "section" => "2.1"}

      assert {:error, :unexpected_download_result} =
               EmailBridge.materialize_record(config, request, %{})
    end

    test "rejects invalid materialization argument shapes without resolving an adapter" do
      assert {:error, :invalid_media_request} = EmailBridge.materialize_record(:bad, %{}, %{})
      assert {:error, :invalid_media_request} = EmailBridge.materialize_record(%{}, :bad, %{})
      assert {:error, :invalid_media_request} = EmailBridge.materialize_record(%{}, %{}, :bad)
      refute_received {:download_attachment, _, _}
    end

    test "returns unsupported for an adapter without attachment downloads" do
      previous = Application.get_env(:zaq, :channels)
      Application.put_env(:zaq, :channels, %{email: %{adapter: DynamicAdapterStub}})

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      assert {:error, :unsupported} =
               EmailBridge.materialize_record(
                 %{provider: "email:imap"},
                 %{"mailbox" => "INBOX"},
                 %{}
               )
    end

    test "generates attachment id when reference is absent" do
      previous = Application.get_env(:zaq, :channels)
      Application.put_env(:zaq, :channels, %{email: %{adapter: MaterializationAdapterStub}})

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      config = %{id: 7, provider: "email:imap"}
      request = %{"channel_config_id" => 7, "uid_validity" => 10, "uid" => 42, "section" => "2.1"}

      assert {:ok, %{record: %{id: "email:7:10:42:2.1"}}} =
               EmailBridge.materialize_record(config, request, %{})
    end

    test "accepts string attachment size at the configured limit" do
      previous = Application.get_env(:zaq, :channels)
      Application.put_env(:zaq, :channels, %{email: %{adapter: MaterializationAdapterStub}})
      Process.put(:email_materialization_download_result, {:ok, "1234567"})

      on_exit(fn ->
        Application.put_env(:zaq, :channels, previous)
        Process.delete(:email_materialization_download_result)
      end)

      config = %{id: 3, provider: "email:imap"}
      request = %{"size" => "7", "uid_validity" => 10, "uid" => 42, "section" => "2.1"}

      assert {:ok, %{record: %{content: "1234567"}}} =
               EmailBridge.materialize_record(config, request, %{
                 config_opts: [max_media_bytes: 7]
               })

      assert_received {:download_attachment, ^config, ^request}
    end

    test "ignores invalid attachment size strings" do
      previous = Application.get_env(:zaq, :channels)
      Application.put_env(:zaq, :channels, %{email: %{adapter: MaterializationAdapterStub}})

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      config = %{id: 3, provider: "email:imap"}

      for size <- ["7bytes", "-1"] do
        request = %{"size" => size, "uid_validity" => 10, "uid" => 42, "section" => "2.1"}

        assert {:ok, _} =
                 EmailBridge.materialize_record(config, request, %{
                   config_opts: [max_media_bytes: 20]
                 })
      end
    end

    test "allows attachment content when no size limit is configured" do
      previous = Application.get_env(:zaq, :channels)
      Application.put_env(:zaq, :channels, %{email: %{adapter: MaterializationAdapterStub}})

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      assert {:ok, _} =
               EmailBridge.materialize_record(
                 %{id: 3, provider: "email:imap"},
                 %{"size" => 999, "uid_validity" => 10, "uid" => 42, "section" => "2.1"},
                 %{config_opts: [max_media_bytes: nil]}
               )
    end

    test "rejects oversized declared and downloaded attachment content" do
      previous = Application.get_env(:zaq, :channels)
      Application.put_env(:zaq, :channels, %{email: %{adapter: MaterializationAdapterStub}})

      on_exit(fn ->
        Application.put_env(:zaq, :channels, previous)
        Process.delete(:email_materialization_download_result)
      end)

      config = %{id: 3, provider: "email:imap"}
      request = %{"size" => 8, "uid_validity" => 10, "uid" => 42, "section" => "2.1"}

      assert {:error, :media_too_large} =
               EmailBridge.materialize_record(config, request, %{
                 config_opts: [max_media_bytes: 7]
               })

      refute_received {:download_attachment, _, _}

      Process.put(:email_materialization_download_result, {:ok, "12345678"})
      request = Map.put(request, "size", 7)

      assert {:error, :media_too_large} =
               EmailBridge.materialize_record(config, request, %{
                 config_opts: [max_media_bytes: 7]
               })

      assert_received {:download_attachment, ^config, ^request}
    end

    test "rejects non-IMAP configs for email attachment materialization" do
      assert {:error, :invalid_email_attachment_provider} =
               EmailBridge.materialize_record(%{provider: "email:smtp"}, %{}, %{})
    end

    test "dispatches to adapter passed through connection details" do
      payload = %{"body_text" => "hello"}
      details = %{adapter: DynamicAdapterStub, mailbox: "INBOX"}

      assert %Zaq.Engine.Messages.Incoming{} = EmailBridge.to_internal(payload, details)
      assert_received {:dynamic_adapter_called, ^payload, ^details}
    end

    test "returns invalid payload error when args are not maps" do
      assert {:error, :invalid_email_payload} = EmailBridge.to_internal("bad", %{})
      assert {:error, :invalid_email_payload} = EmailBridge.to_internal(%{}, :bad)
    end

    test "falls back to provider adapter from config when adapter key is absent" do
      previous = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{
        :email => %{adapter: DynamicAdapterStub}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      payload = %{"body_text" => "hello"}
      details = %{config: %{provider: "missing-provider"}, mailbox: "INBOX"}

      assert %Zaq.Engine.Messages.Incoming{} = EmailBridge.to_internal(payload, details)
      assert_received {:dynamic_adapter_called, ^payload, ^details}
    end

    test "uses default email:imap provider when config is absent" do
      previous = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{
        :email => %{adapter: DynamicAdapterStub}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      payload = %{"body_text" => "hello"}
      details = %{mailbox: "INBOX"}

      assert %Zaq.Engine.Messages.Incoming{} = EmailBridge.to_internal(payload, details)
      assert_received {:dynamic_adapter_called, ^payload, ^details}
    end
  end

  describe "from_listener/3 via NodeRouter event dispatch" do
    setup do
      Application.put_env(:zaq, :email_bridge_pipeline_module, Zaq.Agent.Pipeline)
      Application.put_env(:zaq, :email_bridge_router_module, Zaq.Channels.Router)
      Application.put_env(:zaq, :email_bridge_conversations_module, Zaq.Engine.Conversations)

      Application.put_env(
        :zaq,
        :communication_bridge_identity_resolver,
        UnresolvedIdentityResolver
      )

      on_exit(fn ->
        Application.delete_env(:zaq, :email_bridge_pipeline_module)
        Application.delete_env(:zaq, :email_bridge_router_module)
        Application.delete_env(:zaq, :email_bridge_conversations_module)
        Application.delete_env(:zaq, :email_bridge_node_router_module)
        Application.delete_env(:zaq, :communication_bridge_identity_resolver)
      end)

      :ok
    end

    test "returns :ok when NodeRouter provides pipeline/delivery/persist responses" do
      Application.put_env(:zaq, :email_bridge_node_router_module, NodeRouterOkStub)

      config = %{provider: "email:imap", id: 1}
      payload = %{"body_text" => "hello"}
      sink_opts = [adapter: IncomingAdapterStub, mailbox: "INBOX"]

      assert :ok = EmailBridge.from_listener(config, payload, sink_opts)
    end

    test "treats non-error route responses as acknowledged" do
      Application.put_env(:zaq, :email_bridge_node_router_module, NodeRouterBadPipelineStub)

      config = %{provider: "email:imap", id: 1}
      payload = %{"body_text" => "hello"}
      sink_opts = [adapter: IncomingAdapterStub, mailbox: "INBOX"]

      assert :ok = EmailBridge.from_listener(config, payload, sink_opts)
    end

    test "returns pipeline error when NodeRouter responds with {:error, reason}" do
      Application.put_env(:zaq, :email_bridge_node_router_module, NodeRouterErrorPipelineStub)

      config = %{provider: "email:imap", id: 1}
      payload = %{"body_text" => "hello"}
      sink_opts = [adapter: IncomingAdapterStub, mailbox: "INBOX"]

      log =
        capture_log(fn ->
          assert {:error, :pipeline_failed} =
                   EmailBridge.from_listener(config, payload, sink_opts)
        end)

      assert log =~ "Failed to process inbound message"
    end

    test "routes with email imap channel config id for provider rule lookup" do
      Application.put_env(:zaq, :email_bridge_node_router_module, CapturingNodeRouterStub)

      config = insert_imap_channel_config(%{})
      provider_agent = insert_configured_agent(true)

      assert {:ok, config} =
               ChannelConfig.set_provider_default_agent_id(config, provider_agent.id)

      payload = %{"body_text" => "hello"}
      sink_opts = [adapter: IncomingAdapterStub, mailbox: "INBOX"]

      assert :ok = EmailBridge.from_listener(config, payload, sink_opts)
      assert_received {:node_router_route_incoming_event, event}

      assert event.request.routing_context.channel_config_id == config.id

      assert %{
               source: :provider,
               configured_agent_id: configured_agent_id
             } = IncomingMessageRouting.resolve(event.request)

      assert configured_agent_id == provider_agent.id
    end

    test "runtime-normalized email imap config preserves channel config id for routing" do
      Application.put_env(:zaq, :email_bridge_node_router_module, CapturingNodeRouterStub)

      config = insert_imap_channel_config(%{})
      normalized = ImapConfigHelpers.normalize_bridge_config(config)

      payload = %{"body_text" => "hello"}
      sink_opts = [adapter: IncomingAdapterStub, mailbox: "INBOX"]

      assert :ok = EmailBridge.from_listener(normalized, payload, sink_opts)
      assert_received {:node_router_route_incoming_event, event}

      assert event.request.routing_context.channel_config_id == config.id
    end

    test "route_incoming_message event carries channel actor" do
      Application.put_env(:zaq, :email_bridge_node_router_module, CapturingNodeRouterStub)

      Application.put_env(
        :zaq,
        :communication_bridge_identity_resolver,
        UnresolvedIdentityResolver
      )

      config = insert_imap_channel_config(%{})
      payload = %{"body_text" => "hello"}
      sink_opts = [adapter: IncomingAdapterStub, mailbox: "INBOX"]

      assert :ok = EmailBridge.from_listener(config, payload, sink_opts)
      assert_received {:node_router_route_incoming_event, event}

      assert event.actor == %{
               id: "author@example.com",
               name: nil,
               provider: :"email:imap"
             }
    end

    test "routes with global default when provider default is absent" do
      Application.put_env(:zaq, :email_bridge_node_router_module, CapturingNodeRouterStub)

      on_exit(fn ->
        :ok = Zaq.System.set_global_default_agent_id(nil)
      end)

      config = insert_imap_channel_config(%{})
      global_agent = insert_configured_agent(true)
      :ok = Zaq.System.set_global_default_agent_id(global_agent.id)

      payload = %{"body_text" => "hello"}
      sink_opts = [adapter: IncomingAdapterStub, mailbox: "INBOX"]

      assert :ok = EmailBridge.from_listener(config, payload, sink_opts)
      assert_received {:node_router_route_incoming_event, event}

      assert %{source: :global, configured_agent_id: configured_agent_id} =
               IncomingMessageRouting.resolve(event.request)

      assert configured_agent_id == global_agent.id
    end

    test "routes to default ZAQ agent when no explicit or global selection is configured" do
      Application.put_env(:zaq, :email_bridge_node_router_module, CapturingNodeRouterStub)

      on_exit(fn ->
        :ok = Zaq.System.set_global_default_agent_id(nil)
      end)

      :ok = Zaq.System.set_global_default_agent_id(nil)

      config =
        insert_imap_channel_config(%{settings: %{"imap" => %{"selected_mailboxes" => ["INBOX"]}}})

      payload = %{"body_text" => "hello"}
      sink_opts = [adapter: IncomingAdapterStub, mailbox: "INBOX"]

      assert :ok = EmailBridge.from_listener(config, payload, sink_opts)
      assert_received {:node_router_route_incoming_event, event}

      assert %{source: :default_zaq_agent, configured_agent_id: nil} =
               IncomingMessageRouting.resolve(event.request)
    end

    test "keeps mailbox-specific agent routing when using runtime-prepared config" do
      Application.put_env(:zaq, :email_bridge_node_router_module, CapturingNodeRouterStub)

      on_exit(fn ->
        :ok = Zaq.System.set_global_default_agent_id(nil)
      end)

      :ok = Zaq.System.set_global_default_agent_id(nil)

      config = %{
        provider: "email:imap",
        settings: %{
          "imap" => %{"selected_mailboxes" => ["INBOX"]}
        }
      }

      prepared = ImapConfigHelpers.normalize_bridge_config(config)
      payload = %{"body_text" => "hello"}
      sink_opts = [adapter: IncomingAdapterStub, mailbox: "INBOX"]

      assert :ok = EmailBridge.from_listener(prepared, payload, sink_opts)
      assert_received {:node_router_route_incoming_event, event}

      assert event.opts[:action] == :route_incoming_message
      assert event.request.routing_context.topic_id == "INBOX"
      refute Map.has_key?(event.assigns || %{}, "agent_selection")
    end

    test "NONE mailbox routing fires trigger event without agent dispatch" do
      Application.put_env(:zaq, :email_bridge_node_router_module, CapturingNodeRouterStub)

      on_exit(fn ->
        :ok = Zaq.System.set_global_default_agent_id(nil)
      end)

      config = %{
        provider: "email:imap",
        settings: %{
          "imap" => %{"selected_mailboxes" => ["INBOX"]}
        }
      }

      prepared = ImapConfigHelpers.normalize_bridge_config(config)
      payload = %{"body_text" => "hello"}
      sink_opts = [adapter: IncomingAdapterStub, mailbox: "INBOX"]

      assert :ok = EmailBridge.from_listener(prepared, payload, sink_opts)
      assert_received {:node_router_route_incoming_event, event}
      assert event.request.content == "incoming"
      assert event.name == :incoming_message_routing_requested
      assert event.request.routing_context.topic_id == "INBOX"
      refute Map.has_key?(event.assigns || %{}, "agent_selection")
      refute_received {:node_router_run_pipeline_event, _}
    end
  end

  describe "email:smtp notification delivery" do
    test "delivers notifications using the email:smtp ChannelConfig" do
      upsert_smtp_channel()

      payload = %{"subject" => "Test subject", "body" => "Test body"}

      assert :ok = SmtpSender.send_notification("recipient@example.com", payload, %{})

      assert_receive {:email, email}
      assert email.to == [{"", "recipient@example.com"}]
      assert email.subject == "Test subject"
      assert email.from == {"ZAQ", "noreply@example.com"}
    end

    test "uses default sender when no email:smtp ChannelConfig exists" do
      payload = %{"subject" => "Fallback", "body" => "Hello"}

      assert :ok = SmtpSender.send_notification("recipient@example.com", payload, %{})

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

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{})

      assert_receive {:email, email}
      assert email.subject == "Re: Support request"
      assert email.from == {"ZAQ", "julien@eweev.com"}
      assert {"In-Reply-To", "<msg-2@example.com>"} in email.headers
      assert {"References", "<msg-1@example.com> <msg-2@example.com>"} in email.headers
    end

    test "send_reply uses SMTP from_name for IMAP replies" do
      upsert_smtp_channel(%{
        settings: smtp_settings(%{"from_name" => "Zaq local"})
      })

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Reply body",
        channel_id: "recipient@example.com",
        provider: :"email:imap",
        in_reply_to: "<msg@example.com>",
        metadata: %{
          "email" => %{
            "subject" => "Support request",
            "reply_from" => "support@example.com"
          }
        }
      }

      assert {:ok, _} = EmailBridge.send_reply(outgoing, %{})

      assert_receive {:email, email}
      assert email.subject == "Re: Support request"
      assert email.from == {"Zaq local", "support@example.com"}
      assert {"In-Reply-To", "<msg@example.com>"} in email.headers
    end

    test "reply without email metadata map does not set reply_from" do
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Reply body",
        channel_id: "recipient@example.com",
        provider: :"email:imap",
        in_reply_to: "<msg@example.com>",
        metadata: %{"email" => "invalid", "subject" => "Question"}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{})

      assert_receive {:email, email}
      assert email.subject == "Re: Question"
      assert email.from == {"ZAQ", "noreply@example.com"}
      assert {"In-Reply-To", "<msg@example.com>"} in email.headers
    end

    test "send_reply keeps subject unchanged for non-reply emails" do
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Notification body",
        channel_id: "recipient@example.com",
        provider: :email,
        metadata: %{"subject" => "Security alert"}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{})

      assert_receive {:email, email}
      assert email.subject == "Security alert"
      assert email.from == {"ZAQ", "noreply@example.com"}
      refute Enum.any?(email.headers, fn {k, _v} -> k in ["In-Reply-To", "References"] end)
    end

    test "send_reply relays formatter format for html delivery" do
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "<h1>Title</h1><p><strong>hello</strong></p>",
        channel_id: "recipient@example.com",
        provider: :email,
        metadata: %{"subject" => "Formatted", "format" => "html"}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{})

      assert_receive {:email, email}
      assert email.subject == "Formatted"
      assert email.html_body == "<h1>Title</h1><p><strong>hello</strong></p>"
      assert email.text_body == "Title\nhello"
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
            "headers" => %{"references" => "<Root42@Example.com>"}
          }
        }
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{})

      assert_receive {:email, email}
      assert email.subject == "Re: Threaded question"
      assert email.from == {"ZAQ", "julien@eweev.com"}
      assert {"In-Reply-To", "<AbC123@Example.COM>"} in email.headers
      assert {"References", "<Root42@Example.com> <AbC123@Example.COM>"} in email.headers
    end

    test "send_reply keeps already-prefixed subject and falls back to reply_from when from_email is blank" do
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Reply body",
        channel_id: "recipient@example.com",
        provider: :"email:imap",
        in_reply_to: "<msg-3@example.com>",
        metadata: %{
          "subject" => "  Re: Existing thread  ",
          "from_email" => "   ",
          "from" => %{"name" => "  Agent Name  "},
          "email" => %{"reply_from" => "reply-fallback@example.com"}
        }
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{})

      assert_receive {:email, email}
      assert email.subject == "Re: Existing thread"
      assert email.from == {"Agent Name", "reply-fallback@example.com"}
      assert {"In-Reply-To", "<msg-3@example.com>"} in email.headers
      assert {"References", "<msg-3@example.com>"} in email.headers
    end

    test "send_reply uses default reply subject for blank subject and dedupes list references" do
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Reply body",
        channel_id: "recipient@example.com",
        provider: :"email:imap",
        in_reply_to: "  <Root@Example.com>  ",
        metadata: %{
          "subject" => "   ",
          "email" => %{
            "headers" => %{
              "references" => [
                "<A@Example.com>",
                "A@Example.com",
                "  <B@Example.com>  ",
                nil,
                123
              ]
            }
          }
        }
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{})

      assert_receive {:email, email}
      assert email.subject == "Re: Notification from ZAQ"
      assert {"In-Reply-To", "<Root@Example.com>"} in email.headers
      assert {"References", "<A@Example.com> <B@Example.com> <Root@Example.com>"} in email.headers
    end

    test "send_reply parses string references from incoming headers and appends in_reply_to once" do
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Reply body",
        channel_id: "recipient@example.com",
        provider: :"email:imap",
        in_reply_to: "<Msg-2@Example.com>",
        metadata: %{
          "email" => %{
            "subject" => "Thread follow-up",
            "headers" => %{
              "references" => " <Msg-1@Example.com>   Msg-2@Example.com  <Msg-1@Example.com> "
            }
          }
        }
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{})

      assert_receive {:email, email}
      assert {"In-Reply-To", "<Msg-2@Example.com>"} in email.headers
      assert {"References", "<Msg-1@Example.com> <Msg-2@Example.com>"} in email.headers
    end

    test "send_reply resolves sender from tuple and map address forms" do
      upsert_smtp_channel()

      tuple_outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Hello",
        channel_id: "recipient@example.com",
        provider: :email,
        metadata: %{"from" => {"  Tuple Name  ", " tuple@example.com "}}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(tuple_outgoing, %{})
      assert_receive {:email, tuple_email}
      assert tuple_email.from == {"Tuple Name", "tuple@example.com"}

      map_outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Hello",
        channel_id: "recipient@example.com",
        provider: :email,
        metadata: %{"from" => %{"address" => " addr@example.com "}}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(map_outgoing, %{})
      assert_receive {:email, map_email}
      assert map_email.from == {"ZAQ", "addr@example.com"}
    end

    test "send_reply uses nested email subject when top-level subject is absent" do
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Reply body",
        channel_id: "recipient@example.com",
        provider: :email,
        metadata: %{"email" => %{"subject" => "Nested Subject"}}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{})

      assert_receive {:email, email}
      assert email.subject == "Nested Subject"
    end

    test "send_reply falls back to default subject when metadata is not a map" do
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Body",
        channel_id: "recipient@example.com",
        provider: :email,
        metadata: :invalid
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{})

      assert_receive {:email, email}
      assert email.subject == "Notification from ZAQ"
    end

    test "send_reply does not treat blank in_reply_to as reply" do
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Message",
        channel_id: "recipient@example.com",
        provider: :"email:imap",
        in_reply_to: "   ",
        metadata: %{"subject" => "Plain subject"}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{})

      assert_receive {:email, email}
      assert email.subject == "Plain subject"
      refute Enum.any?(email.headers, fn {k, _} -> k in ["In-Reply-To", "References"] end)
    end

    test "send_reply prefers explicit from_name and from_email" do
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Message",
        channel_id: "recipient@example.com",
        provider: :email,
        metadata: %{
          "from_name" => "  Explicit Name ",
          "from_email" => " explicit@example.com ",
          "from" => %{"name" => "Ignored", "email" => "ignored@example.com"}
        }
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{})

      assert_receive {:email, email}
      assert email.from == {"Explicit Name", "explicit@example.com"}
    end

    test "send_reply with non-binary thread metadata omits threading headers" do
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Reply body",
        channel_id: "recipient@example.com",
        provider: :"email:imap",
        in_reply_to: 123,
        metadata: %{
          "subject" => "Threaded",
          "threading" => %{"references" => 999}
        }
      }

      assert {:ok, receipt} = EmailBridge.send_reply(outgoing, %{})

      assert_receive {:email, email}
      refute Enum.any?(email.headers, fn {k, _} -> k in ["In-Reply-To", "References"] end)
      assert receipt.anchor["in_reply_to"] == nil
      assert receipt.anchor["references"] == []
    end

    test "send_reply with nil in_reply_to omits threading headers" do
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Reply body",
        channel_id: "recipient@example.com",
        provider: :"email:imap",
        in_reply_to: nil,
        metadata: %{"threading" => %{"references" => []}}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{})

      assert_receive {:email, email}
      refute Enum.any?(email.headers, fn {k, _} -> k in ["In-Reply-To", "References"] end)
    end

    test "send_reply omits threading headers when message ids normalize to nil" do
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Reply body",
        channel_id: "recipient@example.com",
        provider: :"email:imap",
        in_reply_to: "<>",
        metadata: %{"threading" => %{"references" => 123}}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{})

      assert_receive {:email, email}
      refute Enum.any?(email.headers, fn {k, _} -> k in ["In-Reply-To", "References"] end)
    end

    test "send_reply derives sender from map and binary variants" do
      upsert_smtp_channel()

      outgoing_map = %Zaq.Engine.Messages.Outgoing{
        body: "Message",
        channel_id: "recipient@example.com",
        provider: :email,
        metadata: %{"from" => %{"email" => " map@example.com ", "name" => " Map Name "}}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing_map, %{})
      assert_receive {:email, email_map}
      assert email_map.from == {"Map Name", "map@example.com"}

      outgoing_binary = %Zaq.Engine.Messages.Outgoing{
        body: "Message",
        channel_id: "recipient@example.com",
        provider: :email,
        metadata: %{"from" => " binary@example.com "}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing_binary, %{})
      assert_receive {:email, email_binary}
      assert email_binary.from == {"ZAQ", "binary@example.com"}
    end

    test "send_reply derives sender from atom-key map variants" do
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Message",
        channel_id: "recipient@example.com",
        provider: :email,
        metadata: %{from: %{name: " Atom Name ", email: " atom@example.com "}}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{})

      assert_receive {:email, email}
      assert email.from == {"Atom Name", "atom@example.com"}
    end

    test "send_reply derives sender email from atom :address key" do
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Message",
        channel_id: "recipient@example.com",
        provider: :email,
        metadata: %{from: %{address: " atom-address@example.com "}}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{})

      assert_receive {:email, email}
      assert email.from == {"ZAQ", "atom-address@example.com"}
    end

    test "send_reply ignores blank explicit from_name" do
      upsert_smtp_channel()

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "Message",
        channel_id: "recipient@example.com",
        provider: :email,
        metadata: %{"from_name" => "", "from_email" => "sender@example.com"}
      }

      assert {:ok, _receipt} = EmailBridge.send_reply(outgoing, %{})

      assert_receive {:email, email}
      assert email.from == {"ZAQ", "sender@example.com"}
    end
  end

  describe "list_mailboxes/2" do
    test "normalizes tuple mailbox entries from adapter" do
      previous = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{
        :email => %{adapter: MailboxTupleAdapterStub}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      assert {:ok, ["HR", "INBOX"]} =
               EmailBridge.list_mailboxes(%{provider: "email:imap"}, %{})
    end

    test "accepts legacy wrapped list_mailboxes_failed ok payload" do
      previous = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{
        :email => %{adapter: LegacyMailboxTupleAdapterStub}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      assert {:ok, ["HR", "INBOX"]} =
               EmailBridge.list_mailboxes(%{provider: "email:imap"}, %{})
    end

    test "returns unsupported provider when provider is missing" do
      assert {:error, {:unsupported_provider, nil}} = EmailBridge.list_mailboxes(%{}, %{})
    end

    test "passes through adapter list_mailboxes errors" do
      previous = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{
        :email => %{adapter: MailboxErrorAdapterStub}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      assert {:error, :imap_unreachable} =
               EmailBridge.list_mailboxes(%{provider: "email:imap"}, %{})
    end

    test "falls back to the real IMAP adapter when email config is absent" do
      previous = Application.get_env(:zaq, :channels)
      channels = if is_map(previous), do: Map.delete(previous, :email), else: %{}
      Application.put_env(:zaq, :channels, channels)

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      assert {:error, :invalid_imap_url} =
               EmailBridge.list_mailboxes(%{provider: "email:imap"}, %{})
    end

    test "normalizes nested IMAP settings into adapter config" do
      previous = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{
        :email => %{adapter: CaptureMailboxAdapterStub}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      config = %{
        provider: "unknown-provider",
        settings: %{
          "imap" => %{
            "username" => "imap-user",
            "port" => "993",
            "ssl" => false,
            "ssl_depth" => 4,
            "timeout" => 12_000,
            "selected_mailboxes" => [" INBOX ", "Support", ""]
          }
        },
        token: "imap-token"
      }

      assert {:ok, ["INBOX"]} = EmailBridge.list_mailboxes(config, %{})
      assert_receive {:captured_mailbox_config, prepared}
      assert prepared.provider == "unknown-provider"
      assert prepared.username == "imap-user"
      assert prepared.port == "993"
      assert prepared.ssl == false
      assert prepared.ssl_depth == 4
      assert prepared.timeout == 12_000
      assert prepared.token == "imap-token"
      assert prepared.selected_mailboxes == ["INBOX", "Support"]
    end

    test "keeps selected_mailboxes list and tolerates non-map settings" do
      previous = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{
        :email => %{adapter: CaptureMailboxAdapterStub}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      config = %{provider: :"email:imap", settings: "bad", selected_mailboxes: ["INBOX", "Sales"]}

      assert {:ok, ["INBOX"]} = EmailBridge.list_mailboxes(config, %{})
      assert_receive {:captured_mailbox_config, prepared}
      assert prepared.selected_mailboxes == ["INBOX", "Sales"]
    end

    test "normalization tolerates missing map values with string-key config" do
      previous = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{
        :email => %{adapter: CaptureMailboxAdapterStub}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      config = %{"provider" => "email:imap", "settings" => "not-a-map"}

      assert {:ok, ["INBOX"]} = EmailBridge.list_mailboxes(config, %{})
      assert_receive {:captured_mailbox_config, prepared}
      assert prepared.selected_mailboxes == []
    end

    test "normalization handles non-map imap settings" do
      previous = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{
        :email => %{adapter: CaptureMailboxAdapterStub}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      config = %{provider: "email:imap", settings: %{"imap" => "oops"}}

      assert {:ok, ["INBOX"]} = EmailBridge.list_mailboxes(config, %{})
      assert_receive {:captured_mailbox_config, prepared}
      assert prepared.selected_mailboxes == []
    end

    test "accepts atom provider key" do
      previous = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{
        :email => %{adapter: MailboxTupleAdapterStub}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      assert {:ok, ["HR", "INBOX"]} =
               EmailBridge.list_mailboxes(%{provider: :"email:imap"}, %{})
    end

    test "normalizes map and string mailbox entries from adapter" do
      previous = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{
        :email => %{adapter: MixedMailboxAdapterStub}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)

      assert {:ok, ["INBOX", "Sales", "Support"]} =
               EmailBridge.list_mailboxes(%{provider: :"email:imap"}, %{})
    end
  end

  describe "from_listener/3" do
    setup do
      previous_pipeline = Application.get_env(:zaq, :email_bridge_pipeline_module)
      previous_router = Application.get_env(:zaq, :email_bridge_router_module)
      previous_conversations = Application.get_env(:zaq, :email_bridge_conversations_module)
      previous_node_router = Application.get_env(:zaq, :email_bridge_node_router_module)

      on_exit(fn ->
        Application.put_env(:zaq, :email_bridge_pipeline_module, previous_pipeline)
        Application.put_env(:zaq, :email_bridge_router_module, previous_router)
        Application.put_env(:zaq, :email_bridge_conversations_module, previous_conversations)
        Application.put_env(:zaq, :email_bridge_node_router_module, previous_node_router)
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

      log =
        capture_log(fn ->
          assert {:error, :invalid_payload} =
                   EmailBridge.from_listener(
                     config,
                     %{"body_text" => "hello"},
                     adapter: IncomingAdapterErrorStub,
                     mailbox: "INBOX"
                   )
        end)

      assert log =~ "Failed to process inbound message"
    end

    test "returns delivery error" do
      Application.put_env(:zaq, :email_bridge_pipeline_module, PipelineOkStub)
      Application.put_env(:zaq, :email_bridge_router_module, RouterErrorStub)
      Application.put_env(:zaq, :email_bridge_conversations_module, ConversationsOkStub)

      config = %{provider: "email:imap"}

      log =
        capture_log(fn ->
          assert {:error, :delivery_failed} =
                   EmailBridge.from_listener(
                     config,
                     %{"body_text" => "hello"},
                     adapter: IncomingAdapterStub,
                     mailbox: "INBOX"
                   )
        end)

      assert log =~ "Failed to process inbound message"
    end

    test "wraps unexpected direct pipeline value" do
      Application.put_env(:zaq, :email_bridge_pipeline_module, PipelineUnexpectedValueStub)
      Application.put_env(:zaq, :email_bridge_router_module, RouterOkStub)
      Application.put_env(:zaq, :email_bridge_conversations_module, ConversationsOkStub)

      config = %{provider: "email:imap"}

      log =
        capture_log(fn ->
          assert {:error, :queued} =
                   EmailBridge.from_listener(
                     config,
                     %{"body_text" => "hello"},
                     adapter: IncomingAdapterStub,
                     mailbox: "INBOX"
                   )
        end)

      assert log =~ "Failed to process inbound message"
    end

    test "delivers outgoing through NodeRouter when router module is Channels Api" do
      Application.put_env(:zaq, :email_bridge_pipeline_module, PipelineOkStub)
      Application.put_env(:zaq, :email_bridge_router_module, Zaq.Channels.Api)
      Application.put_env(:zaq, :email_bridge_node_router_module, ApiDeliveryNodeRouterStub)
      Application.put_env(:zaq, :email_bridge_conversations_module, ConversationsOkStub)

      config = %{provider: "email:imap"}

      assert :ok =
               EmailBridge.from_listener(
                 config,
                 %{"body_text" => "hello"},
                 adapter: IncomingAdapterStub,
                 mailbox: "INBOX"
               )

      assert_receive {:api_delivery_event, event}
      assert event.opts[:action] == :deliver_outgoing
      assert event.request.body == "outgoing"
      assert event.request.channel_id == "recipient@example.com"
    end

    test "ignores persistence module in bridge path" do
      Application.put_env(:zaq, :email_bridge_pipeline_module, PipelineOkStub)
      Application.put_env(:zaq, :email_bridge_router_module, RouterOkStub)
      Application.put_env(:zaq, :email_bridge_conversations_module, ConversationsErrorStub)

      config = %{provider: "email:imap"}

      log =
        capture_log(fn ->
          assert :ok =
                   EmailBridge.from_listener(
                     config,
                     %{"body_text" => "hello"},
                     adapter: IncomingAdapterStub,
                     mailbox: "INBOX"
                   )
        end)

      refute log =~ "Failed to process inbound message"
    end

    test "returns wrapped error for unexpected non-error pipeline chain value" do
      Application.put_env(:zaq, :email_bridge_pipeline_module, PipelineOkStub)
      Application.put_env(:zaq, :email_bridge_router_module, RouterUnexpectedStub)
      Application.put_env(:zaq, :email_bridge_conversations_module, ConversationsOkStub)

      config = %{provider: "email:imap"}

      log =
        capture_log(fn ->
          assert {:error, :queued} =
                   EmailBridge.from_listener(
                     config,
                     %{"body_text" => "hello"},
                     adapter: IncomingAdapterStub,
                     mailbox: "INBOX"
                   )
        end)

      assert log =~ "Failed to process inbound message"
    end
  end

  describe "start_runtime/1" do
    test "passes routing settings into runtime-prepared listener config" do
      previous_channels = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{
        :email => %{adapter: RuntimeCaptureAdapterStub}
      })

      config_id = System.unique_integer([:positive])

      config = %{
        id: config_id,
        provider: "email:imap",
        settings: %{
          "routing" => %{"default_agent_id" => 123},
          "imap" => %{
            "username" => "imap-user",
            "selected_mailboxes" => ["INBOX"],
            "agent_routing" => %{"mailboxes" => %{"INBOX" => 456}}
          }
        }
      }

      on_exit(fn ->
        _ = EmailBridge.stop_runtime(config)
        Application.put_env(:zaq, :channels, previous_channels)
      end)

      assert :ok = EmailBridge.start_runtime(config)
      assert_receive {:captured_runtime_config, prepared}
      assert prepared.selected_mailboxes == ["INBOX"]
      assert prepared.settings["routing"]["default_agent_id"] == 123
      assert prepared.settings["imap"]["agent_routing"]["mailboxes"]["INBOX"] == 456
    end

    test "restarts running runtime to apply updated selected mailboxes" do
      previous_channels = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{
        :email => %{adapter: RuntimeAdapterStub}
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

    test "returns adapter runtime error" do
      previous_channels = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{
        :email => %{adapter: RuntimeErrorAdapterStub}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous_channels) end)

      assert {:error, :runtime_failed} =
               EmailBridge.start_runtime(%{
                 id: 99,
                 provider: "email:imap",
                 settings: %{"imap" => %{}}
               })
    end

    test "returns runtime start error when supervisor rejects listener specs" do
      previous_channels = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{
        :email => %{adapter: RuntimeInvalidSpecAdapterStub}
      })

      on_exit(fn -> Application.put_env(:zaq, :channels, previous_channels) end)

      log =
        capture_log(fn ->
          assert {:error, _reason} =
                   EmailBridge.start_runtime(%{
                     id: 100,
                     provider: "email:imap",
                     settings: %{"imap" => %{}}
                   })
        end)

      assert log =~ "invalid_child_spec"
    end
  end

  describe "stop_runtime/1" do
    test "returns :ok when runtime is not running" do
      assert :ok =
               EmailBridge.stop_runtime(%{
                 id: System.unique_integer([:positive]),
                 provider: "email:imap"
               })
    end
  end

  defp listener_mailbox(pid) when is_pid(pid) do
    pid
    |> :sys.get_state()
    |> Map.fetch!(:mailbox)
  end

  defp insert_imap_channel_config(attrs) do
    upsert_smtp_channel()

    defaults = %{
      name: "Email IMAP",
      provider: "email:imap",
      kind: "retrieval",
      url: "imap.example.com",
      token: "imap-secret",
      enabled: true,
      settings: %{"imap" => %{"selected_mailboxes" => ["INBOX"]}}
    }

    %ChannelConfig{}
    |> ChannelConfig.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_configured_agent(active) do
    credential =
      SystemConfigFixtures.ai_credential_fixture(%{
        provider: "openai",
        endpoint: "https://api.openai.com/v1"
      })

    {:ok, agent} =
      Zaq.Agent.create_agent(%{
        name: "Email Bridge Agent #{System.unique_integer([:positive, :monotonic])}",
        description: "",
        job: "Route email traffic",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: true,
        active: active,
        advanced_options: %{}
      })

    agent
  end
end
