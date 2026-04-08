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

  test "returns tagged error for non-map payload" do
    assert {:error, :invalid_email_payload} = Parser.to_incoming("not-a-map", %{})
  end

  test "falls back to raw payload fields when RFC822 parsing fails" do
    payload = %{
      raw_rfc822: <<255>>,
      body_text: "fallback plain",
      body_html: "<p>fallback html</p>",
      message_id: "<raw-msg@example.com>",
      in_reply_to: "<raw-root@example.com>",
      references: "  <raw-root@example.com>   \n   <raw-parent@example.com>  ",
      subject: "Fallback subject",
      to: "Team Inbox <team@example.com>",
      from: %{"address" => "sender@example.com", "name" => "Sender"}
    }

    incoming = Parser.to_incoming(payload, %{}, mailbox: "Support")

    assert incoming.content == "fallback plain"
    assert incoming.message_id == "<raw-msg@example.com>"
    assert incoming.metadata["email"]["html_body"] == "<p>fallback html</p>"
    assert incoming.metadata["email"]["subject"] == "Fallback subject"
    assert incoming.metadata["email"]["reply_from"] == "team@example.com"

    assert incoming.metadata["email"]["headers"]["references"] ==
             "<raw-root@example.com> <raw-parent@example.com>"
  end

  test "uses parsed To header when Delivered-To is absent" do
    raw_rfc822 =
      [
        "Message-ID: <msg@example.com>",
        "To: Support Team <support@example.com>",
        "Content-Type: text/plain; charset=UTF-8",
        "",
        "Body",
        ""
      ]
      |> Enum.join("\r\n")

    payload = %{
      raw_rfc822: raw_rfc822,
      from: %{address: "sender@example.com", name: "Sender"}
    }

    incoming = Parser.to_incoming(payload, %{}, mailbox: "Support")

    assert incoming.metadata["email"]["reply_from"] == "support@example.com"
  end

  test "supports To fallback variants from payload" do
    cases = [
      {{"Support", "support@example.com"}, "support@example.com"},
      {%{email: "support@example.com"}, "support@example.com"},
      {%{"email" => "support@example.com"}, "support@example.com"},
      {[%{email: "first@example.com"}, %{"email" => "second@example.com"}], "first@example.com"},
      {"Support Team <support@example.com>", "support@example.com"}
    ]

    Enum.each(cases, fn {to_value, expected} ->
      payload = %{
        raw_rfc822: <<255>>,
        body_text: "body",
        to: to_value,
        from: %{address: "sender@example.com", name: "Sender"}
      }

      incoming = Parser.to_incoming(payload, %{}, mailbox: "Support")

      assert incoming.metadata["email"]["reply_from"] == expected
    end)
  end

  test "normalizes empty references to nil" do
    payload = %{
      body_text: "plain body",
      references: " \n   ",
      from: %{address: "sender@example.com", name: "Sender"}
    }

    incoming = Parser.to_incoming(payload, %{}, mailbox: "Support")

    assert incoming.metadata["email"]["headers"]["references"] == nil
  end

  test "supports sender variants and filters nil attachment fields" do
    payload = %{
      body_text: "plain body",
      from: "sender@example.com",
      attachments: [
        %{filename: "report.csv", size: 12},
        %{"content_type" => "application/pdf", "download_ref" => "ref-2"},
        %{filename: nil, download_ref: nil}
      ]
    }

    incoming = Parser.to_incoming(payload, %{}, mailbox: "Support")

    assert incoming.channel_id == "sender@example.com"
    assert incoming.author_name == nil

    assert incoming.metadata["email"]["attachments"] == [
             %{"filename" => "report.csv", "size" => 12},
             %{"content_type" => "application/pdf", "download_ref" => "ref-2"},
             %{}
           ]
  end
end
