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
    assert incoming.channel_id == "sender@example.com"
    assert incoming.author_id == "sender@example.com"
    assert incoming.thread_id == "root@example.com"
    assert incoming.provider == :"email:imap"
    assert incoming.metadata["email"]["thread_key"] == "root@example.com"
    assert incoming.metadata["email"]["html_body"] == "<p>html body</p>"

    assert [%{"filename" => "report.csv", "download_ref" => "ref-1"}] =
             incoming.metadata["email"]["attachments"]
  end

  test "extracts text and html parts from raw multipart rfc822" do
    raw_rfc822 =
      [
        "MIME-Version: 1.0",
        "Content-Type: multipart/alternative; boundary=000000000000719c9f064ef244db",
        "",
        "--000000000000719c9f064ef244db",
        "Content-Type: text/plain; charset=UTF-8",
        "",
        "Yo",
        "",
        "How to compute the area of a circle ?",
        "",
        "--000000000000719c9f064ef244db",
        "Content-Type: text/html; charset=UTF-8",
        "",
        "<div dir=\"ltr\"><div>Yo</div><div><br></div><div>How to compute the area of a circle ?</div></div>",
        "",
        "--000000000000719c9f064ef244db--",
        ""
      ]
      |> Enum.join("\r\n")

    payload = %{
      raw_rfc822: raw_rfc822
    }

    incoming = Parser.to_incoming(payload, %{}, mailbox: "Support")

    assert incoming.content =~ "Yo"
    assert incoming.content =~ "How to compute the area of a circle ?"
    refute incoming.content =~ "Content-Type:"

    assert incoming.metadata["email"]["html_body"] =~
             "<div dir=\"ltr\"><div>Yo</div><div><br></div><div>How to compute the area of a circle ?</div></div>"
  end

  test "uses canonical RFC headers for threading and subject" do
    raw_rfc822 =
      [
        "Delivered-To: julien@eweev.com",
        "Message-ID: <AbC123@Example.COM>",
        "In-Reply-To: <Root42@Example.com>",
        "References: <Root42@Example.com>",
        "Subject: Need help",
        "To: Julien Fayad <julien@eweev.com>",
        "Content-Type: text/plain; charset=UTF-8",
        "",
        "Body",
        ""
      ]
      |> Enum.join("\r\n")

    payload = %{
      raw_rfc822: raw_rfc822,
      message_id: "<wrong@example.com>",
      in_reply_to: "<wrong-root@example.com>",
      references: "<wrong-root@example.com>",
      subject: "Wrong subject",
      from: %{address: "sender@example.com", name: "Sender"}
    }

    incoming = Parser.to_incoming(payload, %{}, mailbox: "Support")

    assert incoming.message_id == "<AbC123@Example.COM>"
    assert incoming.thread_id == "Root42@Example.com"
    assert incoming.metadata["subject"] == "Need help"
    assert incoming.metadata["email"]["subject"] == "Need help"
    assert incoming.metadata["email"]["headers"]["message_id"] == "<AbC123@Example.COM>"
    assert incoming.metadata["email"]["headers"]["in_reply_to"] == "<Root42@Example.com>"
    assert incoming.metadata["email"]["headers"]["references"] == "<Root42@Example.com>"
    assert incoming.metadata["email"]["reply_from"] == "julien@eweev.com"
  end
end
