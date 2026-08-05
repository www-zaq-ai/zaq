defmodule Zaq.Utils.MimeSnifferTest do
  use ExUnit.Case, async: true

  doctest Zaq.Utils.MimeSniffer

  alias Zaq.Utils.MimeSniffer

  describe "detect/1" do
    test "recognises the image formats a chat provider actually sends" do
      assert MimeSniffer.detect(<<0xFF, 0xD8, 0xFF, 0xE0, 0, 0>>) == "image/jpeg"
      assert MimeSniffer.detect(<<0x89, "PNG\r\n", 0x1A, "\n", 0, 0>>) == "image/png"
      assert MimeSniffer.detect(<<"GIF89a", 0, 0>>) == "image/gif"
      assert MimeSniffer.detect(<<"GIF87a", 0, 0>>) == "image/gif"
      assert MimeSniffer.detect(<<"RIFF", 1, 2, 3, 4, "WEBP", 0>>) == "image/webp"
      assert MimeSniffer.detect(<<"BM", 0, 0>>) == "image/bmp"
    end

    test "recognises audio, video, and pdf" do
      assert MimeSniffer.detect(<<"OggS", 0, 0>>) == "audio/ogg"
      assert MimeSniffer.detect(<<"ID3", 0, 0>>) == "audio/mpeg"
      assert MimeSniffer.detect(<<0xFF, 0xFB, 0, 0>>) == "audio/mpeg"
      assert MimeSniffer.detect(<<"RIFF", 1, 2, 3, 4, "WAVE", 0>>) == "audio/wav"
      assert MimeSniffer.detect(<<0, 0, 0, 24, "ftypisom", 0>>) == "video/mp4"
      assert MimeSniffer.detect(<<0x1A, 0x45, 0xDF, 0xA3, 0>>) == "video/webm"
      assert MimeSniffer.detect(<<"%PDF-1.7", 0>>) == "application/pdf"
    end

    test "answers nil for anything it does not recognise" do
      assert MimeSniffer.detect("plain text") == nil
      assert MimeSniffer.detect(<<>>) == nil
      assert MimeSniffer.detect(<<0, 1, 2>>) == nil
    end

    test "a webp header is not mistaken for a wav" do
      refute MimeSniffer.detect(<<"RIFF", 1, 2, 3, 4, "WEBP", 0>>) == "audio/wav"
    end
  end

  describe "ensure_extension/2" do
    test "adds the extension a nameless provider file never had" do
      assert MimeSniffer.ensure_extension("image-0", "image/jpeg") =~ ~r/^image-0\.jpe?g$/
      assert MimeSniffer.ensure_extension("image-0", "image/png") == "image-0.png"
    end

    test "leaves a name that already carries a matching extension" do
      assert MimeSniffer.ensure_extension("photo.png", "image/png") == "photo.png"
    end

    test "accepts any extension the type allows, not just the preferred one" do
      # image/jpeg maps to several extensions; none of them should be appended twice.
      name = MimeSniffer.ensure_extension("photo.jpeg", "image/jpeg")

      assert name == "photo.jpeg"
    end

    test "corrects a name whose extension contradicts the sniffed bytes" do
      assert MimeSniffer.ensure_extension("photo.txt", "image/png") == "photo.txt.png"
    end

    test "leaves the name alone when the type is unknown or unmapped" do
      assert MimeSniffer.ensure_extension("image-0", nil) == "image-0"
      assert MimeSniffer.ensure_extension("image-0", "application/x-nonsense") == "image-0"
    end

    test "is case-insensitive about an existing extension" do
      assert MimeSniffer.ensure_extension("PHOTO.PNG", "image/png") == "PHOTO.PNG"
    end
  end
end
