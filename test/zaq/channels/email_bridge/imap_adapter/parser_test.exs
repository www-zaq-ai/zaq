defmodule Zaq.Channels.EmailBridge.ImapAdapter.ParserTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.EmailBridge.ImapAdapter.Parser

  test "uses plain text body for incoming content and preserves html in metadata" do
    payload = %{
      body_text: "plain body",
      body_html: "<p>html body</p>",
      from: %{address: "sender@example.com", name: "Sender"},
      message_id: "<msg@example.com>",
      references: "<root@example.com>",
      attachments: [%{filename: "report.csv", download_ref: "ref-1"}]
    }

    incoming = Parser.to_incoming(payload, %{}, mailbox: "Support")

    assert incoming.content == "plain body"
    assert incoming.channel_id == "Support"
    assert incoming.author_id == "sender@example.com"
    assert incoming.thread_id == "root@example.com"
    assert incoming.metadata["email"]["html_body"] == "<p>html body</p>"

    assert [%{"filename" => "report.csv", "download_ref" => "ref-1"}] =
             incoming.metadata["email"]["attachments"]
  end
end
