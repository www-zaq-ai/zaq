defmodule Zaq.Channels.EmailBridge.ImapAdapter.MimeDecoderTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.EmailBridge.ImapAdapter.MimeDecoder

  test "decodes base64 attachments while ignoring whitespace" do
    assert {:ok, "hello"} = MimeDecoder.decode_attachment("aGVs\r\nbG8=", "BASE64")
  end

  test "decodes quoted printable bodies" do
    assert {:ok, "hello world\nsoft"} =
             MimeDecoder.decode_body("hello=20world=0Asoft=\r\n", "quoted-printable", %{})
  end

  test "passes through 7bit, 8bit, binary, and unknown encodings" do
    for encoding <- ["7bit", "8BIT", "binary", "x-custom", nil] do
      assert {:ok, "abc"} = MimeDecoder.decode_attachment("abc", encoding)
    end
  end

  test "rejects invalid base64" do
    assert {:error, :decode_failed} = MimeDecoder.decode_attachment("not-base64!!", "base64")
  end

  test "rejects non-binary attachment content" do
    assert {:error, :invalid_mime_content} = MimeDecoder.decode_attachment(nil, "base64")
  end

  test "treats whitespace-only transfer encoding as absent" do
    assert {:ok, "raw body"} = MimeDecoder.decode_attachment("raw body", " \t\r\n ")
  end

  test "passes through US-ASCII body content" do
    assert {:ok, "plain ASCII"} =
             MimeDecoder.decode_body("plain ASCII", "7bit", %{"charset" => " US-ASCII "})
  end

  test "passes through body content for unsupported charsets" do
    content = <<255, 254>>

    assert {:ok, ^content} = MimeDecoder.decode_body(content, "8bit", %{charset: "ISO-8859-1"})
  end

  test "treats non-map body parameters as an unspecified charset" do
    assert {:ok, "body"} = MimeDecoder.decode_body("body", "7bit", nil)
  end

  property "quoted-printable decoding is total for binary MIME payloads" do
    check all(binary <- binary()) do
      assert {:ok, decoded} = MimeDecoder.decode_attachment(binary, "quoted-printable")
      assert is_binary(decoded)
    end
  end

  property "7bit pass-through preserves arbitrary binaries" do
    check all(binary <- binary()) do
      assert {:ok, ^binary} = MimeDecoder.decode_attachment(binary, "7bit")
    end
  end
end
