defmodule Zaq.Channels.EmailBridge.AttachmentMaterializationTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.{Api, ChannelConfig, EmailBridge}
  alias Zaq.Channels.EmailBridge.Attachment
  alias Zaq.Channels.EmailBridge.ImapAdapter
  alias Zaq.Contracts.Record
  alias Zaq.Materialization
  alias Zaq.Repo
  alias Zaq.TestSupport.FakeImapServer

  defmodule InlineNodeRouter do
    def dispatch(event) do
      Api.handle_event(event, Keyword.fetch!(event.opts, :action), nil)
    end
  end

  setup do
    previous = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      email: %{bridge: EmailBridge, adapter: ImapAdapter}
    })

    on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)
    :ok
  end

  test "materializes an inbound IMAP attachment handle through Channels" do
    fake =
      start_supervised!(
        {FakeImapServer,
         owner: self(),
         message: %{
           uid: 4_281,
           body_sections: %{"2.1" => Base.encode64("invoice bytes")}
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

    descriptor = %{
      section: "2.1",
      content_type: "application/pdf",
      filename: "invoice.pdf",
      encoding: "base64",
      encoded_size: 20,
      disposition: "attachment"
    }

    record =
      Attachment.to_record(descriptor, %{
        channel_config_id: imap_config.id,
        mailbox: "INBOX",
        uid_validity: 1_193_810_872,
        uid: 4_281,
        source_author_id: "sender@example.com"
      })

    assert %Record{content: nil, materialization_handle: handle} = record

    assert {:ok, %{record: materialized}} =
             Materialization.materialize(handle, %{
               node_router: InlineNodeRouter,
               actor: %{id: "sender@example.com"}
             })

    assert materialized.content == "invoice bytes"
    assert materialized.name == "invoice.pdf"
    assert materialized.mime_type == "application/pdf"
    assert materialized.materialization_handle == nil

    assert_receive {:imap_fake_command, ^fake, :uid, uid_fetch}, 1_000
    assert uid_fetch =~ "UID FETCH 4281"
    assert uid_fetch =~ "BODY.PEEK[2.1]"
    refute uid_fetch =~ "RFC822"
    refute_receive {:imap_fake_command, ^fake, :uid, _}, 100
  end

  defp insert_config(provider, attrs) do
    unique = System.unique_integer([:positive])

    base = %{
      name: "cfg-#{provider}-#{unique}",
      provider: provider,
      kind: "retrieval",
      enabled: true
    }

    (ChannelConfig.get_any_by_provider(provider) || %ChannelConfig{})
    |> ChannelConfig.changeset(Map.merge(base, attrs))
    |> insert_or_update!()
  end

  defp insert_or_update!(
         %Ecto.Changeset{data: %ChannelConfig{__meta__: %{state: :loaded}}} = changeset
       ),
       do: Repo.update!(changeset)

  defp insert_or_update!(changeset), do: Repo.insert!(changeset)
end
