defmodule Zaq.Channels.EmailBridge.ImapAdapter.ParserTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.EmailBridge.ImapAdapter.Parser
  alias Zaq.Contracts.Record

  test "receiving alias is excluded independently of login and sender, using only the first delivery hop" do
    for role <- ["To", "Cc"] do
      raw =
        Enum.join(
          [
            "Delivered-To: BOT-ALIAS@example.com",
            "Delivered-To: human@example.com",
            "From: Human <human@example.com>",
            if(role == "To", do: "To: bot-alias@example.com", else: "To: human@example.com"),
            if(role == "Cc",
              do: "Cc: bot-alias@example.com, colleague@example.com",
              else: "Cc: colleague@example.com"
            ),
            "Message-ID: <original@example.com>",
            "",
            "Count to three"
          ],
          "\r\n"
        )

      incoming =
        Parser.to_incoming(
          %{raw_rfc822: raw, from: %{address: "human@example.com"}},
          %{config: %{username: "login@example.com"}},
          mailbox: "INBOX"
        )

      assert incoming.metadata["email"]["receiving_address"] == "bot-alias@example.com"
      assert incoming.routing_context.reply_targets.to == ["human@example.com"]
      assert incoming.routing_context.reply_targets.cc == ["colleague@example.com"]
      assert incoming.metadata["email"]["reply_from"] == "bot-alias@example.com"
    end
  end

  test "automatic replies are recognized without inferring ownership from From or Message-ID" do
    for {header, automatic?} <- [
          {"Auto-Submitted: AUTO-REPLIED; owner-email=bot@example.com", true},
          {"Auto-Submitted: no", false},
          {"", false}
        ] do
      incoming =
        Parser.to_incoming(
          %{
            raw_header: header,
            from: %{address: "login@example.com"},
            to: "human@example.com",
            message_id: "<zaq-human@example.com>"
          },
          %{}
        )

      assert incoming.metadata["email"]["automatic_reply"] == automatic?
    end
  end

  test "reply sender falls back to the configured mailbox when delivery evidence is unavailable" do
    for header <- ["", "Delivered-To: not-an-address\r\n"] do
      incoming =
        Parser.to_incoming(
          %{
            from: %{address: "human@example.com"},
            raw_header: header <> "To: login@example.com, colleague@example.com"
          },
          %{username: "login@example.com"}
        )

      assert incoming.metadata["email"]["receiving_address"] == nil
      assert incoming.metadata["email"]["reply_from"] == "login@example.com"

      assert incoming.routing_context.reply_targets.to == [
               "human@example.com",
               "colleague@example.com"
             ]
    end
  end

  property "receiving aliases are excluded from replies and discovery without dropping human recipients" do
    check all(
            local <- string(:alphanumeric, min_length: 1, max_length: 20),
            role <- member_of(["To", "Cc"]),
            folded? <- boolean(),
            max_runs: 40
          ) do
      address = String.downcase(local) <> "@aliases.example.com"
      separator = if folded?, do: "\r\n\t", else: " "

      incoming =
        Parser.to_incoming(
          %{
            from: %{address: "human@example.com"},
            raw_header:
              "Delivered-To:#{separator}#{String.upcase(address)}\r\n#{role}: #{address}, colleague@example.com"
          },
          %{username: "login@example.com"}
        )

      assert incoming.metadata["email"]["receiving_address"] == address
      assert incoming.metadata["email"]["reply_from"] == address
      targets = incoming.routing_context.reply_targets
      assert Enum.sort(targets.to ++ targets.cc) == ["colleague@example.com", "human@example.com"]
      refute address in incoming.routing_context.audience.recipients

      refute Enum.any?(
               incoming.routing_context.audience.participants,
               &(&1.identifier == address)
             )

      assert "colleague@example.com" in incoming.routing_context.audience.recipients
    end
  end

  test "malformed or body-only delivery headers never remove a visible human recipient" do
    for header <- [
          "",
          "Delivered-To: not-an-address",
          "Delivered-To: one@example.com, two@example.com"
        ] do
      incoming =
        Parser.to_incoming(
          %{
            from: %{address: "human@example.com"},
            raw_rfc822:
              "To: colleague@example.com\r\nReturn-Path: colleague@example.com\r\n" <>
                header <> "\r\n\r\nDelivered-To: colleague@example.com"
          },
          %{}
        )

      assert incoming.metadata["email"]["receiving_address"] == nil
      assert "colleague@example.com" in incoming.routing_context.reply_targets.to
    end
  end

  test "preserves visible names and roles and normalizes reply-all independently of sender routing" do
    raw =
      Enum.join(
        [
          "Message-ID: <root@example.com>",
          "Subject:   Quarterly plan  ",
          "Reply-To: Support <reply@example.com>",
          "To: ZAQ <bot@example.com>, Alex <alex@example.com>",
          "Cc: Sam <sam@example.com>, Alex <alex@example.com>",
          "Delivered-To: hidden@example.com",
          "",
          "Hello"
        ],
        "\r\n"
      )

    incoming =
      Parser.to_incoming(
        %{raw_rfc822: raw, from: %{address: "SENDER@example.com", name: "Sender"}},
        %{config: %{settings: %{"imap" => %{"username" => "bot@example.com"}}}},
        mailbox: "INBOX"
      )

    assert incoming.author_id == "sender@example.com"
    assert incoming.metadata["email"]["reply_from"] == "hidden@example.com"
    assert incoming.routing_context.conversation_id == "root@example.com"
    assert incoming.routing_context.display_subject == "Quarterly plan"
    assert incoming.routing_context.reply_targets.to == ["reply@example.com", "alex@example.com"]
    assert incoming.routing_context.reply_targets.cc == ["sam@example.com"]

    assert %{identifier: "sam@example.com", display_name: "Sam", role: :cc} in incoming.routing_context.audience.participants

    refute "hidden@example.com" in incoming.routing_context.audience.recipients
  end

  test "uses plain text body for incoming content and preserves html in metadata" do
    payload = %{
      body_text: "plain body",
      body_html: "<p>html body</p>",
      from: %{address: "sender@example.com", name: "Sender"},
      message_id: "<msg@example.com>",
      references: "<root@example.com>",
      attachments: [
        %Record{
          id: "email:1:2:3:4",
          kind: :file,
          name: "report.csv",
          materialization_handle: "signed"
        }
      ]
    }

    incoming = Parser.to_incoming(payload, %{}, mailbox: "Support")

    assert incoming.content == "plain body"
    assert incoming.channel_id == "sender@example.com"
    assert incoming.author_id == "sender@example.com"
    assert incoming.thread_id == "root@example.com"
    assert incoming.provider == :"email:imap"
    assert incoming.metadata["email"]["thread_key"] == "root@example.com"
    assert incoming.metadata["email"]["html_body"] == "<p>html body</p>"

    assert [%Record{name: "report.csv", materialization_handle: "signed"}] = incoming.attachments
    refute Map.has_key?(incoming.metadata["email"], "attachments")
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
    assert incoming.metadata["email"]["receiving_address"] == "julien@eweev.com"
    assert incoming.metadata["email"]["reply_from"] == "julien@eweev.com"
  end

  test "prepends subject to incoming content when subject is present" do
    payload = %{
      body_text: "plain body",
      subject: "  Need help  ",
      from: %{address: "sender@example.com", name: "Sender"}
    }

    incoming = Parser.to_incoming(payload, %{}, mailbox: "Support")

    assert incoming.content == "Subject: Need help\n\nplain body"
    assert incoming.metadata["subject"] == "  Need help  "
    assert incoming.metadata["email"]["subject"] == "  Need help  "
  end

  test "keeps incoming content unchanged when subject is blank or missing" do
    for subject <- [nil, "", "   "] do
      payload = %{
        body_text: "plain body",
        subject: subject,
        from: %{address: "sender@example.com", name: "Sender"}
      }

      incoming = Parser.to_incoming(payload, %{}, mailbox: "Support")

      assert incoming.content == "plain body"
    end
  end

  test "uses subject-only content when email body is empty" do
    payload = %{
      body_text: "",
      subject: "Need help",
      from: %{address: "sender@example.com", name: "Sender"}
    }

    incoming = Parser.to_incoming(payload, %{}, mailbox: "Support")

    assert incoming.content == "Subject: Need help"
  end

  test "returns tagged error for non-map payload" do
    assert {:error, :invalid_email_payload} = Parser.to_incoming("not-a-map", %{})
  end

  test "rescues internal parser errors for invalid config shapes" do
    payload = %{
      body_text: "body",
      from: %{address: "sender@example.com"}
    }

    result = Parser.to_incoming(payload, :invalid_config, mailbox: "Support")

    assert {:error, {:invalid_email_payload, message}} = result
    assert is_binary(message)
    assert message != ""
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

    assert incoming.content == "Subject: Fallback subject\n\nfallback plain"
    assert incoming.message_id == "<raw-msg@example.com>"
    assert incoming.metadata["email"]["html_body"] == "<p>fallback html</p>"
    assert incoming.metadata["email"]["subject"] == "Fallback subject"
    assert incoming.metadata["email"]["reply_from"] == nil
    assert incoming.routing_context.reply_targets.to == ["sender@example.com", "team@example.com"]

    assert incoming.metadata["email"]["headers"]["references"] ==
             "<raw-root@example.com> <raw-parent@example.com>"
  end

  test "missing delivery headers do not infer receiving or sending identity from To" do
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

    assert incoming.metadata["email"]["reply_from"] == nil
    assert incoming.metadata["email"]["receiving_address"] == nil

    assert incoming.routing_context.reply_targets.to == [
             "sender@example.com",
             "support@example.com"
           ]
  end

  test "records only the current message's sender and visible To/Cc from RFC headers" do
    payload = %{
      from: %{address: "sender@example.com", name: "Sender"},
      to: "wrong@example.com",
      cc: "wrong-cc@example.com",
      raw_header:
        Enum.join(
          [
            "To: One <one@example.com>, TWO@Example.com",
            "Cc: Two <two@example.com>, one@example.com",
            "Bcc: hidden@example.com",
            "Delivered-To: undisclosed@example.com",
            "References: <older@example.com>"
          ],
          "\r\n"
        )
    }

    incoming = Parser.to_incoming(payload, %{}, mailbox: "INBOX")

    assert incoming.routing_context.audience == %Zaq.Engine.Messages.Incoming.Audience{
             platform: "email",
             sender: "sender@example.com",
             recipients: ["one@example.com", "two@example.com"],
             participants: [
               %{identifier: "sender@example.com", role: :sender, display_name: "Sender"},
               %{identifier: "one@example.com", role: :to, display_name: "One"},
               %{identifier: "two@example.com", role: :to, display_name: nil},
               %{identifier: "two@example.com", role: :cc, display_name: "Two"},
               %{identifier: "one@example.com", role: :cc, display_name: nil}
             ]
           }

    assert incoming.metadata["email"]["receiving_address"] == "undisclosed@example.com"
    assert incoming.metadata["email"]["reply_from"] == "undisclosed@example.com"
    refute inspect(incoming.routing_context.audience) =~ "hidden@example.com"
    refute inspect(incoming.routing_context.audience) =~ "undisclosed@example.com"

    later =
      Parser.to_incoming(%{from: %{address: "later@example.com"}, to: "new@example.com"}, %{})

    assert later.routing_context.audience == %Zaq.Engine.Messages.Incoming.Audience{
             platform: "email",
             sender: "later@example.com",
             recipients: ["new@example.com"],
             participants: [
               %{identifier: "later@example.com", role: :sender, display_name: nil},
               %{identifier: "new@example.com", role: :to, display_name: nil}
             ]
           }
  end

  test "falls back to all structured To/Cc addresses without treating Bcc as visible" do
    incoming =
      Parser.to_incoming(
        %{
          raw_rfc822: <<255>>,
          from: %{address: " SENDER@Example.com "},
          to: [{"One", "one@example.com"}, %{"email" => "two@example.com"}],
          cc: ["Three <three@example.com>, one@example.com", %{email: "bad address"}],
          bcc: "hidden@example.com"
        },
        %{}
      )

    assert incoming.routing_context.audience == %Zaq.Engine.Messages.Incoming.Audience{
             platform: "email",
             sender: "sender@example.com",
             recipients: ["one@example.com", "two@example.com", "three@example.com"],
             participants: [
               %{identifier: "sender@example.com", role: :sender, display_name: nil},
               %{identifier: "one@example.com", role: :to, display_name: "One"},
               %{identifier: "two@example.com", role: :to, display_name: nil},
               %{identifier: "three@example.com", role: :cc, display_name: "Three"},
               %{identifier: "one@example.com", role: :cc, display_name: nil}
             ]
           }
  end

  test "a parsed message without visible recipients does not use an envelope recipient as Bcc proof" do
    incoming =
      Parser.to_incoming(
        %{
          raw_header: "Delivered-To: hidden@example.com\r\nMessage-ID: <private@example.com>",
          from: %{address: "sender@example.com"},
          to: "hidden@example.com"
        },
        %{},
        mailbox: "INBOX"
      )

    assert incoming.routing_context.audience == %Zaq.Engine.Messages.Incoming.Audience{
             platform: "email",
             sender: "sender@example.com",
             recipients: [],
             participants: [%{identifier: "sender@example.com", role: :sender, display_name: nil}]
           }

    assert incoming.metadata["email"]["receiving_address"] == "hidden@example.com"
    assert incoming.metadata["email"]["reply_from"] == "hidden@example.com"
  end

  property "duplicate To/Cc addresses do not create extra message recipients" do
    check all(local <- string(:alphanumeric, min_length: 1, max_length: 20), max_runs: 45) do
      email = local <> "@example.com"

      incoming =
        Parser.to_incoming(
          %{
            from: %{address: "sender@example.com"},
            to: [email, String.upcase(email)],
            cc: [email, "not-an-address"]
          },
          %{}
        )

      assert incoming.routing_context.audience.recipients == [
               String.downcase(email)
             ]
    end
  end

  test "uses fetched header-only payload for receiving alias, reply sender and threading" do
    raw_header =
      [
        "Delivered-To: alias@example.com",
        "Message-ID: <HeaderMsg@Example.COM>",
        "In-Reply-To: <Root@Example.com>",
        "References: <Root@Example.com>",
        "Subject: Alias thread",
        "To: Main Inbox <main@example.com>"
      ]
      |> Enum.join("\r\n")

    payload = %{
      raw_header: raw_header,
      body_text: "body",
      from: %{address: "sender@example.com", name: "Sender"},
      message_id: "<wrong@example.com>",
      in_reply_to: "<wrong-root@example.com>",
      references: "<wrong-root@example.com>",
      subject: "Wrong subject"
    }

    incoming = Parser.to_incoming(payload, %{}, mailbox: "Support")

    assert incoming.message_id == "<HeaderMsg@Example.COM>"
    assert incoming.thread_id == "Root@Example.com"
    assert incoming.metadata["email"]["receiving_address"] == "alias@example.com"
    assert incoming.metadata["email"]["reply_from"] == "alias@example.com"
    assert incoming.metadata["email"]["subject"] == "Alias thread"
    assert incoming.metadata["email"]["headers"]["message_id"] == "<HeaderMsg@Example.COM>"
    assert incoming.metadata["email"]["headers"]["in_reply_to"] == "<Root@Example.com>"
    assert incoming.metadata["email"]["headers"]["references"] == "<Root@Example.com>"
  end

  test "structured To variants remain reply recipients without becoming the sending identity" do
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

      assert incoming.metadata["email"]["reply_from"] == nil
      assert expected in incoming.routing_context.reply_targets.to
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

  test "normalizes non-binary references to nil" do
    payload = %{
      body_text: "plain body",
      message_id: "<msg@example.com>",
      references: ["<root@example.com>"],
      from: %{address: "sender@example.com"}
    }

    incoming = Parser.to_incoming(payload, %{}, mailbox: "Support")

    assert incoming.metadata["email"]["headers"]["references"] == nil
    assert incoming.thread_id == "msg@example.com"

    assert incoming.metadata["threading"]["anchor"] == %{
             "message_id" => "msg@example.com",
             "thread_id" => "msg@example.com",
             "references" => []
           }
  end

  test "normalizes blank reply_from to nil" do
    payload = %{
      raw_rfc822: <<255>>,
      body_text: "body",
      to: "   ",
      from: %{address: "sender@example.com"}
    }

    incoming = Parser.to_incoming(payload, %{}, mailbox: "Support")

    assert incoming.metadata["email"]["reply_from"] == nil
  end

  test "supports sender variants and keeps only canonical Record attachments" do
    record = %Record{id: "email:1:2:3:4", kind: :file, name: "report.csv"}

    payload = %{
      body_text: "plain body",
      from: "sender@example.com",
      attachments: [
        %{filename: "report.csv", size: 12},
        record,
        %{"content_type" => "application/pdf", "download_ref" => "ref-2"}
      ]
    }

    incoming = Parser.to_incoming(payload, %{}, mailbox: "Support")

    assert incoming.channel_id == "sender@example.com"
    assert incoming.author_name == nil

    assert incoming.attachments == [record]
    refute Map.has_key?(incoming.metadata["email"], "attachments")
  end

  describe "channel-agnostic threading anchor" do
    test "writes the anchor at parse time when a Message-ID is present" do
      payload = %{
        body_text: "hello",
        from: %{address: "sender@example.com"},
        message_id: "<msg@example.com>",
        references: "<root@example.com> <mid@example.com>"
      }

      incoming = Parser.to_incoming(payload, %{}, mailbox: "Support")

      assert incoming.metadata["threading"]["anchor"] == %{
               "message_id" => "msg@example.com",
               "thread_id" => "root@example.com",
               "references" => ["root@example.com", "mid@example.com"]
             }
    end

    test "a message without references roots its own thread" do
      payload = %{
        body_text: "hello",
        from: %{address: "sender@example.com"},
        message_id: "<msg@example.com>"
      }

      incoming = Parser.to_incoming(payload, %{}, mailbox: "Support")

      assert incoming.metadata["threading"]["anchor"] == %{
               "message_id" => "msg@example.com",
               "thread_id" => "msg@example.com",
               "references" => []
             }
    end

    test "writes no anchor without a Message-ID" do
      payload = %{
        body_text: "hello",
        from: %{address: "sender@example.com"}
      }

      incoming = Parser.to_incoming(payload, %{}, mailbox: "Support")

      refute Map.has_key?(incoming.metadata, "threading")
    end
  end
end
