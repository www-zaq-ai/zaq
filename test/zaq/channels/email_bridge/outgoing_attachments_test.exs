defmodule Zaq.Channels.EmailBridge.OutgoingAttachmentsTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Channels.EmailBridge
  alias Zaq.Channels.EmailBridge.SmtpSender
  alias Zaq.Contracts.Record
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Storage.Materializers.DiskDocument

  setup :verify_on_exit!

  test "multiple files preserve bytes, names, MIME types, selected sender, recipients and threading" do
    selected = smtp_config("selected@example.test")
    smtp_config("other@example.test")
    bytes = <<0, 255, 254, 128, 10>>

    outgoing = %{
      outgoing(selected.id)
      | attachments: [file(bytes), %{file("second") | name: "notes.txt", mime_type: "text/plain"}],
        thread_anchor: %{
          "message_id" => "parent@example.test",
          "references" => ["root@example.test"]
        },
        routing_context: %{
          channel_config_id: selected.id,
          reply_targets: %{to: ["recipient@example.test"], cc: ["copied@example.test"]}
        }
    }

    assert {:ok, receipt} = EmailBridge.send_reply(outgoing, %{})
    assert_receive {:email, email}
    assert [first, second] = email.attachments
    assert first.data == bytes
    assert first.filename == "report.bin"
    assert first.content_type == "application/octet-stream"
    assert first.path == nil
    assert second.data == "second"
    assert second.filename == "notes.txt"
    assert second.content_type == "text/plain"
    assert email.from == {"Selected", "selected@example.test"}
    assert email.to == [{"", "recipient@example.test"}]
    assert email.cc == [{"", "copied@example.test"}]
    assert email.headers["Message-ID"] == "<sent@example.test>"
    assert email.headers["In-Reply-To"] == "<parent@example.test>"
    assert email.headers["References"] == "<root@example.test> <parent@example.test>"
    assert receipt.message_id == "sent@example.test"
    assert receipt.confirmation == :confirmed
    assert receipt.audience.sender == "selected@example.test"
    assert receipt.audience.recipients == ["recipient@example.test", "copied@example.test"]
    refute_receive {:email, _}
  end

  property "one attachment reaches the synchronous mailer with every byte intact" do
    config = smtp_config("selected@example.test")

    check all(bytes <- binary(max_length: 2_048), max_runs: 30) do
      assert {:ok, _} =
               EmailBridge.send_reply(%{outgoing(config.id) | attachments: [file(bytes)]}, %{})

      assert_receive {:email, %{attachments: [attachment]}}
      assert Swoosh.Attachment.get_content(attachment) == bytes
      assert attachment.path == nil
    end
  end

  test "one failed preparation prevents sending already prepared files" do
    config = smtp_config("selected@example.test")

    for invalid <- [file("%%%", %{"encoding" => "base64"}), %{file(nil) | path: "/private/file"}] do
      assert {:error, _} =
               EmailBridge.send_reply(
                 %{outgoing(config.id) | attachments: [file("ready"), invalid]},
                 %{}
               )

      refute_receive {:email, _}
    end
  end

  test "lazy files carry only trusted context and materialize once before delivery" do
    config = smtp_config("selected@example.test")
    assert {:ok, handle} = DiskDocument.issue("source-file")
    bytes = <<255, 0, 128>>

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      assert event.actor == %{person_id: 123}
      refute Keyword.has_key?(event.opts, :credentials)
      refute_received {:email, _}

      %{
        event
        | response:
            {:ok, %{record: %{file(bytes) | name: "resolved.pdf", mime_type: "application/pdf"}}}
      }
    end)

    details = %{
      trusted_context: %{actor: %{person_id: 123}, credentials: "private"},
      node_router: Zaq.NodeRouterMock
    }

    assert {:ok, _} =
             EmailBridge.send_reply(
               %{
                 outgoing(config.id)
                 | attachments: [%{file(nil) | materialization_handle: handle}]
               },
               details
             )

    assert_receive {:email, %{attachments: [attachment]}}
    assert Swoosh.Attachment.get_content(attachment) == bytes
    assert attachment.filename == "resolved.pdf"
    assert attachment.content_type == "application/pdf"
  end

  test "malformed internal prepared payloads are rejected without sending or reading paths" do
    config = smtp_config("selected@example.test")

    for attachments <- [
          nil,
          %{},
          ["/private/file"],
          [%{path: "/private/file"}],
          [%{content: 12, name: "x", mime_type: "text/plain", size: 1}]
        ] do
      assert {:error, :invalid_prepared_attachment} =
               SmtpSender.send_notification_with_receipt(
                 "recipient@example.test",
                 %{"body" => "hello", "attachments" => attachments},
                 %{},
                 config.id
               )

      refute_receive {:email, _}
    end
  end

  test "SMTP rejection propagates without a confirmed receipt or fallback send" do
    config =
      smtp_config("selected@example.test", %{
        "relay" => "127.0.0.1",
        "port" => "1",
        "tls" => "never"
      })

    assert {:error, _} =
             EmailBridge.send_reply(%{outgoing(config.id) | attachments: [file(<<255, 0>>)]}, %{})

    refute_receive {:email, _}
  end

  defp outgoing(config_id) do
    %Outgoing{
      provider: :"email:smtp",
      channel_id: "recipient@example.test",
      body: "hello",
      routing_context: %{channel_config_id: config_id},
      metadata: %{"subject" => "Files", "threading" => %{"message_id" => "sent@example.test"}}
    }
  end

  defp file(content, attributes \\ %{}) do
    %Record{
      id: "source-file",
      kind: :file,
      content: content,
      name: "report.bin",
      mime_type: "application/octet-stream",
      attributes: attributes
    }
  end

  defp smtp_config(address, overrides \\ %{}) do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: address,
      provider: "email:smtp",
      kind: "retrieval",
      url: "smtp.example.test",
      token: "fixture-token",
      enabled: true,
      settings:
        Map.merge(%{"relay" => "", "from_email" => address, "from_name" => "Selected"}, overrides)
    })
    |> Repo.insert!()
  end
end
