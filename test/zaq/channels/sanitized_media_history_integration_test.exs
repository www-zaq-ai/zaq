defmodule Zaq.Channels.SanitizedMediaHistoryIntegrationTest do
  use Zaq.DataCase, async: false

  alias Jido.Chat.WhatsApp.Adapter
  alias Zaq.Accounts.People
  alias Zaq.Agent.Tools.DataSource.DownloadDocument
  alias Zaq.Channels.{CommunicationBridge, JidoChatBridge}
  alias Zaq.Engine.{Api, ChannelConfig, Conversations, HistoryIngress}
  alias Zaq.Engine.Conversations.{ExecutionRecord, Message}
  alias Zaq.Event
  alias Zaq.Materialization.Handle
  alias Zaq.Permissions
  alias Zaq.Permissions.ChannelHistoryResource

  defmodule MediaTransport do
    def resolve_conn(_opts), do: {:ok, :connection}
    def media_reference(:connection, _descriptor), do: {:ok, "sealed-provider-reference"}
  end

  # Only provider byte retrieval is replaced. Ingress uses the real adapter;
  # capture, history authorization, hydration and materialization remain real.
  defmodule ProviderMedia do
    def fetch_media("sealed-provider-reference", opts) do
      send(self(), {:provider_download, opts[:url]})
      {:ok, "document bytes"}
    end
  end

  defmodule LocalRouter do
    def dispatch(event) do
      case Keyword.fetch!(event.opts, :action) do
        :receive_incoming_message ->
          result = Zaq.Engine.Api.handle_event(event, :receive_incoming_message, %{})
          send(self(), {:passive_capture, result.response})
          result

        action when action in [:hydrate_attachments, :materialize_record] ->
          Zaq.Channels.Api.handle_event(event, action, %{})
      end
    end
  end

  setup do
    channels = Application.fetch_env!(:zaq, :channels)
    router = Application.fetch_env(:zaq, :chat_bridge_node_router_module)

    Application.put_env(
      :zaq,
      :channels,
      Map.put(channels, :whatsapp, %{bridge: JidoChatBridge, adapter: ProviderMedia})
    )

    Application.put_env(:zaq, :chat_bridge_node_router_module, LocalRouter)

    on_exit(fn ->
      Application.put_env(:zaq, :channels, channels)

      case router do
        {:ok, original} -> Application.put_env(:zaq, :chat_bridge_node_router_module, original)
        :error -> Application.delete_env(:zaq, :chat_bridge_node_router_module)
      end
    end)

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Sanitized media history",
        provider: "whatsapp",
        kind: "retrieval",
        enabled: true,
        url: "https://selected-provider.invalid",
        token: "test-token"
      })
      |> Repo.insert!()

    {:ok, person} = People.create_person(%{full_name: "Media sender"})

    {:ok, _} =
      People.add_channel(%{
        person_id: person.id,
        platform: "whatsapp",
        channel_identifier: "15550002@s.whatsapp.net",
        channel_config_id: config.id
      })

    %{config: config, person: person}
  end

  test "unmentioned sealed media is persisted and downloadable from a later authorized history read",
       %{config: config, person: person} do
    for {id, caption} <- [{"media-only", nil}, {"captioned-media", "A report"}] do
      source = media(id, %{content: %{caption: caption}})

      assert source.raw == %{
               channel_jid: "123@g.us",
               from_jid: "15550002@s.whatsapp.net",
               timestamp: 1_700_000_000
             }

      refute source.was_mentioned

      assert :ok = JidoChatBridge.handle_from_listener(config, source, [])

      assert_receive {:passive_capture,
                      {:ok, %{message_id: message_id, transcript_id: transcript}}}

      stored = Repo.get!(Message, message_id)
      assert stored.content == (caption || "")
      assert stored.external_message_id == id
      assert [descriptor] = stored.attachments
      assert descriptor["id"] == "sealed-provider-reference"
      refute Map.has_key?(descriptor, "materialization_handle")
      refute inspect(descriptor) =~ "media_key"
      refute inspect(descriptor) =~ "private-media-path"
      assert Repo.aggregate(ExecutionRecord, :count) == 0
      refute_received {:provider_download, _}

      # Replaying the provider message captures the same canonical message.
      assert :ok = JidoChatBridge.handle_from_listener(config, source, [])
      assert_receive {:passive_capture, {:ok, %{message_id: ^message_id}}}

      assert {:ok, messages} = Conversations.list_canonical_messages(person, transcript)
      assert Enum.any?(messages, &(&1.message_id == message_id))
    end

    assert Repo.aggregate(Message, :count) == 2

    {:ok, outsider} = People.create_person(%{full_name: "Unrelated person"})
    [transcript | _] = Repo.all(Zaq.Engine.Conversations.Transcript)

    assert {:error, :unauthorized} =
             Conversations.list_canonical_messages(outsider, transcript.id)

    {:ok, _} =
      Permissions.grant(
        ChannelHistoryResource.for("whatsapp", config.id, "123@g.us"),
        %{person_id: person.id, access_rights: ["read"]}
      )

    {:ok, transport} =
      Adapter.transform_incoming(%{
        id: "later-question",
        channel_jid: "123@g.us",
        from_jid: "15550002@s.whatsapp.net",
        type: :text,
        text: "Download the earlier reports",
        timestamp: 1_700_000_001
      })

    question =
      transport
      |> JidoChatBridge.to_internal(config)
      |> Map.put(:person, person)
      |> CommunicationBridge.put_conversation_identity()

    assert {:ok, _} = HistoryIngress.capture(question)
    assert {:ok, binding} = Conversations.admit_incoming(question)
    actor = %{id: question.author_id, person: %{id: person.id}, provider: :whatsapp}

    event =
      Event.new(%{binding: binding, content: question.content}, :engine,
        actor: actor,
        opts: [confidential: true, node_router: LocalRouter]
      )

    assert %{response: {:ok, %{kind: :canonical, messages: messages}}} =
             Api.handle_event(event, :admit_execution, %{})

    assert length(messages) == 2

    for message <- messages do
      assert [attachment] = message.attachments
      handle = attachment["materialization_handle"]
      assert {:ok, %{locator: locator}} = Handle.verify(handle)
      assert locator["provider"] == "whatsapp"
      assert locator["channel_config_id"] == to_string(config.id)
      assert locator["source_channel_id"] == "123@g.us"

      for unauthorized_actor <- [%{id: "other-sender"}, %{}] do
        assert {:error, "Record materialization failed: :unauthorized_materialization_handle"} =
                 DownloadDocument.run(%{materialization_handle: handle}, %{
                   node_router: LocalRouter,
                   actor: unauthorized_actor
                 })
      end

      refute_received {:provider_download, _}

      assert {:ok, %{record: %{content: "document bytes", name: "report.pdf"}}} =
               DownloadDocument.run(%{materialization_handle: handle}, %{
                 node_router: LocalRouter,
                 actor: actor
               })

      assert_receive {:provider_download, "https://selected-provider.invalid"}
    end
  end

  test "self media and mentioned history do not request an agent turn", %{config: config} do
    assert :ok =
             JidoChatBridge.handle_from_listener(config, media("self", %{from_me: true}), [])

    assert :ok =
             JidoChatBridge.handle_from_listener(
               config,
               media("history", %{
                 mentions: ["15550001@s.whatsapp.net"],
                 account_jids: ["15550001@s.whatsapp.net"],
                 metadata: %{history: true}
               }),
               []
             )

    refute_received {:passive_capture, _}
    refute_received {:provider_download, _}
    assert Repo.aggregate(Message, :count) == 0
    assert Repo.aggregate(ExecutionRecord, :count) == 0
  end

  defp media(id, overrides) do
    content = %{
      kind: :document,
      file_name: "report.pdf",
      mimetype: "application/pdf",
      file_length: 14,
      direct_path: "/private-media-path",
      media_key: :binary.copy(<<1>>, 32)
    }

    payload =
      %{
        id: id,
        channel_jid: "123@g.us",
        from_jid: "15550002@s.whatsapp.net",
        timestamp: 1_700_000_000,
        type: :media
      }
      |> Map.merge(Map.delete(overrides, :content))
      |> Map.put(:content, Map.merge(content, Map.get(overrides, :content, %{})))

    {:ok, source} =
      Adapter.transform_incoming(payload, conn: :connection, transport: MediaTransport)

    source
  end
end
