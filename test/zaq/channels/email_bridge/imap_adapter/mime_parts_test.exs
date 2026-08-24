defmodule Zaq.Channels.EmailBridge.ImapAdapter.MimePartsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Mailroom.IMAP.BodyStructure.Part
  alias Zaq.Channels.EmailBridge.ImapAdapter.MimeParts

  describe "body_parts/1 and attachment_parts/1" do
    test "classifies a simple mixed message" do
      body_structure =
        part(nil,
          parts: [
            part("1", type: {"text", "plain"}, encoding: "7BIT"),
            part("2",
              type: {"application", "pdf"},
              disposition: "attachment",
              file_name: "Invoice.PDF"
            )
          ]
        )

      assert [%{section: "1", content_type: "text/plain"}] = MimeParts.body_parts(body_structure)

      assert [attachment] = MimeParts.attachment_parts(body_structure)
      assert attachment.section == "2"
      assert attachment.filename == "Invoice.PDF"
      assert attachment.disposition == "attachment"
      assert attachment.content_type == "application/pdf"
    end

    test "finds alternative bodies and nested attachments" do
      body_structure =
        part(nil,
          parts: [
            part("1",
              parts: [
                part("1.1", type: {"text", "plain"}),
                part("1.2", type: {"text", "html"})
              ]
            ),
            part("2.1", type: {"application", "pdf"}, disposition: "attachment")
          ]
        )

      assert MimeParts.plain_text_part(body_structure).section == "1.1"
      assert MimeParts.html_part(body_structure).section == "1.2"
      assert [%{section: "2.1"}] = MimeParts.attachment_parts(body_structure)
    end

    test "classifies inline files with content ids" do
      body_structure =
        part(nil,
          parts: [
            part("1", type: {"text", "html"}),
            part("2",
              type: {"image", "png"},
              disposition: "inline",
              file_name: "logo.png",
              id: "<logo@example>"
            )
          ]
        )

      assert [%{section: "1"}] = MimeParts.body_parts(body_structure)

      assert [%{disposition: "inline", content_id: "logo@example", filename: "logo.png"}] =
               MimeParts.attachment_parts(body_structure)
    end

    test "treats textual files as attachments when file metadata exists" do
      body_structure =
        part("1", type: {"text", "plain"}, disposition: "attachment", file_name: "notes.txt")

      assert [] = MimeParts.body_parts(body_structure)

      assert [%{content_type: "text/plain", filename: "notes.txt"}] =
               MimeParts.attachment_parts(body_structure)
    end

    test "accepts top-level part lists and ignores unsupported entries" do
      body_structure = [part("1", type: {"text", "plain"}), :unsupported, nil]

      assert [%{section: "1", content_type: "text/plain"}] = MimeParts.body_parts(body_structure)
      assert [] = MimeParts.attachment_parts(body_structure)
    end

    test "normalizes integer sections and rejects missing sections" do
      body_structure = [part(1, type: {"text", "plain"}), part(nil, type: {"text", "html"})]

      assert [%{section: "1", content_type: "text/plain"}] = MimeParts.body_parts(body_structure)
    end

    test "normalizes malformed attachment metadata to safe defaults" do
      body_structure =
        part(3,
          type: {"", ""},
          disposition: " ATTACHMENT ",
          file_name: " Report.PDF ",
          params: [],
          encoding: " ",
          id: "<>"
        )

      assert [attachment] = MimeParts.attachment_parts(body_structure)
      assert attachment.section == "3"
      assert attachment.content_type == "application/octet-stream"
      assert attachment.filename == "Report.PDF"
      assert attachment.disposition == "attachment"
      assert attachment.encoding == nil
      assert attachment.content_id == nil
      assert attachment.params == %{}
    end

    test "uses the binary content-type fallback for unsupported type values" do
      body_structure =
        part("1", type: nil, disposition: "attachment", file_name: "payload.bin")

      assert [%{content_type: "application/octet-stream", filename: "payload.bin"}] =
               MimeParts.attachment_parts(body_structure)
    end
  end

  test "rejects non-binary MIME sections" do
    for section <- [nil, 1, :section, %{}, []] do
      refute MimeParts.valid_section?(section)
    end
  end

  property "valid_section?/1 accepts only positive dotted MIME sections" do
    check all(section <- string(:printable, max_length: 24)) do
      expected = Regex.match?(~r/^[1-9]\d*(?:\.[1-9]\d*)*$/, section)
      assert MimeParts.valid_section?(section) == expected
    end
  end

  defp part(section, attrs) do
    struct!(
      Part,
      Keyword.merge(
        [
          section: section,
          params: %{},
          multipart: Keyword.get(attrs, :parts, []) != [],
          type: {"text", "plain"},
          id: nil,
          encoding: "7BIT",
          encoded_size: 0,
          disposition: nil,
          file_name: nil,
          parts: []
        ],
        attrs
      )
    )
  end
end
