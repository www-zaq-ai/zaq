defmodule Zaq.Channels.EmailBridge.IncomingAttachmentMaterializationIntegrationTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.{Api, ChannelConfig, EmailBridge}
  alias Zaq.Channels.EmailBridge.{ImapAdapter, ImapClient, ImapConfigHelpers}
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Materialization
  alias Zaq.Materialization.Handle
  alias Zaq.Repo
  alias Zaq.TestSupport.FakeImapServer

  defmodule InlineNodeRouter do
    @moduledoc false

    def dispatch(event) do
      Api.handle_event(event, Keyword.fetch!(event.opts, :action), nil)
    end
  end

  setup do
    for {key, value} <- [
          channels: %{email: %{bridge: EmailBridge, adapter: ImapAdapter}},
          imap_client: ImapClient
        ] do
      previous = Application.fetch_env(:zaq, key)

      on_exit(fn ->
        case previous do
          {:ok, original} -> Application.put_env(:zaq, key, original)
          :error -> Application.delete_env(:zaq, key)
        end
      end)

      Application.put_env(:zaq, key, value)
    end

    :ok
  end

  test "discovers an inbound IMAP attachment and materializes its generated handle" do
    fake =
      start_supervised!(
        {FakeImapServer,
         owner: self(),
         uid_validity: 1_193_810_872,
         message: %{
           uid: 4_281,
           subject: "Invoice",
           from_mailbox: "sender",
           from_host: "example.com",
           body_structure:
             ~s|(("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 5 1 NIL NIL NIL)("APPLICATION" "PDF" ("NAME" "invoice.pdf") NIL NIL "BASE64" 20 NIL ("ATTACHMENT" ("FILENAME" "invoice.pdf")) NIL) "MIXED")|,
           body_sections: %{"1" => "hello", "2" => Base.encode64("invoice bytes")}
         }}
      )

    insert_config("email:smtp", %{url: "smtp://example.test", token: "smtp-token"})

    imap_config =
      insert_config("email:imap", %{
        url: FakeImapServer.config(fake).url,
        token: "secret",
        settings: %{
          "imap" => %{
            "username" => "demo",
            "ssl" => false,
            "timeout" => 1_500,
            "selected_mailboxes" => ["INBOX"]
          }
        }
      })

    runtime_config =
      imap_config
      |> ChannelConfig.to_runtime_config()
      |> ImapConfigHelpers.normalize_bridge_config()

    assert {:ok, client} = ImapAdapter.connect(runtime_config, "INBOX")
    owner = self()

    try do
      assert :ok =
               ImapAdapter.fetch_unseen(
                 client,
                 "INBOX",
                 fn payload -> send(owner, {:inbound_email, payload}) end,
                 config: runtime_config
               )
    after
      ImapAdapter.disconnect(client)
    end

    assert_receive {:inbound_email, payload}, 1_000

    assert %Incoming{} =
             incoming =
             EmailBridge.to_internal(payload, %{
               adapter: ImapAdapter,
               config: runtime_config,
               mailbox: "INBOX"
             })

    assert incoming.author_id == "sender@example.com"
    assert incoming.content == "Subject: Invoice\n\nhello"
    assert [attachment] = incoming.attachments
    assert %Record{kind: :file, content: nil} = attachment
    assert is_binary(attachment.materialization_handle)
    assert attachment.name == "invoice.pdf"
    assert attachment.mime_type == "application/pdf"
    assert attachment.size == byte_size(Base.encode64("invoice bytes"))

    assert {:ok, %{type: "communication_media", locator: locator}} =
             Handle.verify(attachment.materialization_handle)

    assert locator["provider"] == "email:imap"
    assert locator["channel_config_id"] == to_string(imap_config.id)
    assert locator["mailbox"] == "INBOX"
    assert locator["uid_validity"] == 1_193_810_872
    assert locator["uid"] == 4_281
    assert locator["section"] == "2"
    assert locator["name"] == "invoice.pdf"
    assert locator["mime_type"] == "application/pdf"
    assert locator["encoding"] == "base64"
    assert locator["source_author_id"] == "sender@example.com"
    assert attachment.attributes["mime_section"] == locator["section"]
    assert attachment.attributes["message_uid"] == locator["uid"]

    # Consume the first connection through LOGOUT so later commands belong to redemption.
    ingestion_commands = session_commands(fake)
    assert Enum.any?(ingestion_commands, fn {_, raw} -> raw =~ "BODYSTRUCTURE" end)
    assert Enum.any?(ingestion_commands, fn {_, raw} -> raw =~ "BODY.PEEK[1]" end)

    refute Enum.any?(ingestion_commands, fn {_, raw} ->
             raw =~ "BODY.PEEK[#{locator["section"]}]" or raw =~ "RFC822"
           end)

    assert {:ok, %{record: materialized}} =
             Materialization.materialize(attachment.materialization_handle, %{
               node_router: InlineNodeRouter,
               actor: %{id: "sender@example.com"}
             })

    materialization_commands = session_commands(fake)
    assert [{:uid, fetch}] = Enum.filter(materialization_commands, fn {cmd, _} -> cmd == :uid end)
    assert fetch =~ "UID FETCH #{locator["uid"]}"
    assert fetch =~ "BODY.PEEK[#{locator["section"]}]"
    refute Enum.any?(materialization_commands, fn {_, raw} -> raw =~ "RFC822" end)

    assert %Record{} = materialized
    assert materialized.id == attachment.id
    assert materialized.content == "invoice bytes"
    assert materialized.name == "invoice.pdf"
    assert materialized.mime_type == "application/pdf"
    assert materialized.size == byte_size("invoice bytes")
    assert materialized.materialization_handle == nil
  end

  defp session_commands(fake) do
    assert_receive {:imap_fake_command, ^fake, command, raw}, 1_000

    if command == :logout do
      []
    else
      [{command, raw} | session_commands(fake)]
    end
  end

  defp insert_config(provider, attrs) do
    base = %{
      name: "cfg-#{provider}-#{System.unique_integer([:positive])}",
      provider: provider,
      kind: "retrieval",
      enabled: true
    }

    (ChannelConfig.get_any_by_provider(provider) || %ChannelConfig{})
    |> ChannelConfig.changeset(Map.merge(base, attrs))
    |> Repo.insert_or_update!()
  end
end
