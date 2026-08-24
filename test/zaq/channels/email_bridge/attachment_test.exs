defmodule Zaq.Channels.EmailBridge.AttachmentTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.EmailBridge.Attachment
  alias Zaq.Contracts.Record
  alias Zaq.Materialization.Handle

  test "returns safe defaults for invalid outer input shapes" do
    assert Attachment.to_record(nil, valid_context()) == nil
    assert Attachment.to_record(valid_descriptor(), nil) == nil
    assert Attachment.to_record(:invalid_descriptor, :invalid_context) == nil
    assert Attachment.to_records(nil, valid_context()) == []
    assert Attachment.to_records(%{}, valid_context()) == []
    assert Attachment.to_records("not-a-list", valid_context()) == []
  end

  test "converts valid descriptors and filters invalid entries while preserving order" do
    descriptors = [
      valid_descriptor(%{section: "2.1", filename: "first.pdf"}),
      %{section: "", filename: "missing-identity.pdf"},
      :invalid_descriptor,
      valid_descriptor(%{section: "3", filename: "second.pdf"})
    ]

    records = Attachment.to_records(descriptors, valid_context())

    assert [%Record{}, %Record{}] = records

    assert Enum.map(records, & &1.id) == [
             "email:3:1193810872:4281:2.1",
             "email:3:1193810872:4281:3"
           ]

    assert Enum.map(records, & &1.name) == ["first.pdf", "second.pdf"]
  end

  property "normalizes non-negative numeric sizes and integer names" do
    check all(size <- integer(0..1_000_000), filename_number <- integer()) do
      descriptor =
        valid_descriptor(%{
          encoded_size: Integer.to_string(size),
          filename: filename_number
        })

      assert %Record{size: ^size, name: name} =
               record = Attachment.to_record(descriptor, valid_context())

      assert name == Integer.to_string(filename_number)

      assert {:ok, %{locator: locator}} = Handle.verify(record.materialization_handle)
      assert locator["size"] == size
      assert locator["name"] == Integer.to_string(filename_number)
    end
  end

  test "drops unsupported metadata types and uses the default MIME type" do
    descriptor =
      valid_descriptor(%{
        filename: [],
        content_type: %{},
        encoded_size: :unknown,
        content_id: self()
      })

    assert %Record{name: nil, mime_type: "application/octet-stream", size: nil} =
             record = Attachment.to_record(descriptor, valid_context())

    refute Map.has_key?(record.attributes, "content_id")
    assert {:ok, %{locator: locator}} = Handle.verify(record.materialization_handle)
    assert locator["section"] == "2.1"
    assert locator["uid"] == 4_281
    assert locator["channel_config_id"] == "3"
    refute Map.has_key?(locator, "name")
    refute Map.has_key?(locator, "mime_type")
    refute Map.has_key?(locator, "size")
    refute Map.has_key?(locator, "content_id")
  end

  test "rejects binary sizes that are negative, partial, or non-numeric" do
    for encoded_size <- ["-1", "12px", "not-a-number", ""] do
      descriptor = valid_descriptor(%{encoded_size: encoded_size})

      assert %Record{size: nil} = record = Attachment.to_record(descriptor, valid_context())
      assert {:ok, %{locator: locator}} = Handle.verify(record.materialization_handle)
      refute Map.has_key?(locator, "size")
    end
  end

  test "rejects negative integer sizes" do
    descriptor = valid_descriptor(%{encoded_size: -1})

    assert %Record{size: nil} = record = Attachment.to_record(descriptor, valid_context())
    assert {:ok, %{locator: locator}} = Handle.verify(record.materialization_handle)
    refute Map.has_key?(locator, "size")
  end

  defp valid_descriptor(overrides \\ %{}) do
    Map.merge(
      %{
        section: "2.1",
        content_type: "application/pdf",
        filename: "invoice.pdf",
        encoding: "base64",
        encoded_size: 183_221,
        disposition: "attachment",
        content_id: nil
      },
      overrides
    )
  end

  defp valid_context(overrides \\ %{}) do
    Map.merge(
      %{
        channel_config_id: 3,
        mailbox: "INBOX",
        uid_validity: 1_193_810_872,
        uid: 4_281,
        source_author_id: "sender@example.com"
      },
      overrides
    )
  end
end
