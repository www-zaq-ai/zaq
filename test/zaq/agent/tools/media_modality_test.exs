defmodule Zaq.Agent.Tools.MediaModalityTest do
  use ExUnit.Case, async: true

  alias Jido.AI.Turn
  alias ReqLLM.Message.ContentPart
  alias Zaq.Agent.Tools.MediaModality
  alias Zaq.Contracts.Record

  defp record(attrs \\ %{}) do
    struct!(%Record{id: "42", kind: :file, name: "photo.png", mime_type: "image/png"}, attrs)
  end

  describe "modality/1" do
    test "maps a mime type to the input it needs" do
      assert MediaModality.modality("image/png") == :image
      assert MediaModality.modality("audio/ogg") == :audio
      assert MediaModality.modality("video/mp4") == :video
      assert MediaModality.modality("text/markdown") == :text
      assert MediaModality.modality("application/pdf") == :text
      assert MediaModality.modality(nil) == :text
    end
  end

  describe "readable?/2" do
    test "a vision model can read an image" do
      assert MediaModality.readable?("image/png", [:text, :image])
    end

    test "a text-only model cannot" do
      refute MediaModality.readable?("image/png", [:text])
    end

    test "text is readable by every model" do
      assert MediaModality.readable?("text/markdown", [:text])
      assert MediaModality.readable?("application/pdf", [:text])
    end

    test "an unknown modality list is treated as unknown, not as text-only" do
      # A model missing from the LLMDB catalog must not be assumed blind — the attempt is
      # made and the provider gets to reject it.
      assert MediaModality.readable?("image/png", [])
    end

    test "a document with no declared type is not refused on a guess" do
      assert MediaModality.readable?(nil, [:text])
    end

    test "audio needs an audio-capable model" do
      assert MediaModality.readable?("audio/ogg", [:text, :audio])
      refute MediaModality.readable?("audio/ogg", [:text, :image])
    end
  end

  describe "put_content_parts/2" do
    test "an image becomes a real content part carrying raw bytes" do
      encoded = Base.encode64("PNGDATA")

      payload = %{
        record: record(%{content: encoded, attributes: %{"encoding" => "base64"}})
      }

      assert %{__content_parts__: [%ContentPart{} = part]} =
               MediaModality.put_content_parts(payload, [:text, :image])

      assert part.type == :image
      assert part.media_type == "image/png"
      # Raw, not base64 — ReqLLM re-encodes at the provider boundary.
      assert part.data == "PNGDATA"
    end

    test "the record's content is cleared so the image is not also sent as base64 text" do
      encoded = Base.encode64("PNGDATA")

      payload = %{record: record(%{content: encoded, attributes: %{"encoding" => "base64"}})}

      assert %{record: %Record{} = stripped} =
               MediaModality.put_content_parts(payload, [:text, :image])

      assert stripped.content == nil
      assert stripped.attributes["content_delivered_as"] == "image"
      # The JSON payload jido_ai builds derives from these fields — the bytes must not be here.
      refute stripped |> Record.to_map() |> Elixir.Map.get(:content)
    end

    test "unencoded content is passed through as-is" do
      payload = %{record: record(%{content: "RAWBYTES"})}

      assert %{__content_parts__: [%ContentPart{data: "RAWBYTES"}]} =
               MediaModality.put_content_parts(payload, [:image])
    end

    test "a text document is left alone rather than sent twice" do
      payload = %{record: record(%{mime_type: "text/markdown", content: "# hi"})}

      refute Map.has_key?(
               MediaModality.put_content_parts(payload, [:text, :image]),
               :__content_parts__
             )
    end

    test "an image is left alone when the model cannot see it" do
      payload = %{record: record(%{content: Base.encode64("x")})}

      refute Map.has_key?(MediaModality.put_content_parts(payload, [:text]), :__content_parts__)
    end

    test "undecodable base64 does not produce a broken part" do
      payload = %{
        record: record(%{content: "!!!not base64!!!", attributes: %{"encoding" => "base64"}})
      }

      refute Map.has_key?(MediaModality.put_content_parts(payload, [:image]), :__content_parts__)
    end

    test "a record with no content produces no part" do
      payload = %{record: record()}

      refute Map.has_key?(MediaModality.put_content_parts(payload, [:image]), :__content_parts__)
    end

    test "a payload with no record passes through untouched" do
      assert MediaModality.put_content_parts(%{other: 1}, [:image]) == %{other: 1}
    end
  end

  # Exercises jido_ai's real encoder rather than our assumption about it: it returns
  # `[text_part | media_parts]`, so anything left on the record is serialised into that text
  # part and reaches the model as characters it cannot read.
  describe "through Jido.AI.Turn.format_tool_result_content/1" do
    test "the encoded tool result carries no base64 of the image" do
      bytes = String.duplicate("PNGDATA", 200)
      encoded = Base.encode64(bytes)

      payload =
        MediaModality.put_content_parts(
          %{record: record(%{content: encoded, attributes: %{"encoding" => "base64"}})},
          [:text, :image]
        )

      assert [%ContentPart{type: :text, text: json} | media] =
               Turn.format_tool_result_content({:ok, payload})

      refute json =~ encoded
      refute json =~ String.slice(encoded, 0, 64)
      assert [%ContentPart{type: :image, data: ^bytes}] = media
    end

    test "the image survives as a real image part, not as text" do
      payload =
        MediaModality.put_content_parts(
          %{record: record(%{content: Base.encode64("PNGDATA")})},
          [:image]
        )

      parts = Turn.format_tool_result_content({:ok, payload})

      assert Enum.any?(parts, &match?(%ContentPart{type: :image}, &1))
    end

    test "a text document still travels as plain JSON with its content intact" do
      payload = %{record: record(%{mime_type: "text/markdown", content: "# hi"})}

      encoded = Turn.format_tool_result_content({:ok, payload})

      assert is_binary(encoded)
      assert encoded =~ "# hi"
    end
  end

  describe "refusal/2" do
    test "names the modality and tells the model what to do" do
      message = MediaModality.refusal("photo.png", "image/png")

      assert message =~ "cannot read image"
      assert message =~ "photo.png"
      assert message =~ "Tell the user"
    end

    test "copes with a nameless, typeless attachment" do
      message = MediaModality.refusal(nil, nil)

      assert message =~ "the attachment"
      assert message =~ "unknown type"
    end
  end
end
