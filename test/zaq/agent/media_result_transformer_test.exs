defmodule Zaq.Agent.MediaResultTransformerTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolResult
  alias Zaq.Agent.MediaResultTransformer
  alias Zaq.Contracts.Record

  test "passes non-media tool results through the default formatter" do
    result = {:ok, %{answer: 42}, []}

    assert {:ok, ^result} =
             MediaResultTransformer.project_tool_result(
               %{id: "call-1", name: "calculator", arguments: %{}},
               result,
               %{}
             )
  end

  test "passes through successful results with non-map payloads" do
    result = {:ok, "plain result", [:effect]}

    assert {:ok, ^result} =
             MediaResultTransformer.project_tool_result(
               %{id: "call-plain", name: "calculator", arguments: %{}},
               result,
               %{}
             )
  end

  test "passes through records whose attributes are not a map" do
    record = %{media_record("image/png") | content: <<0, 1>>, attributes: nil}
    result = {:ok, %{record: record}, []}

    assert {:ok, ^result} =
             MediaResultTransformer.project_tool_result(
               %{id: "call-invalid-attributes", name: "download_document", arguments: %{}},
               result,
               %{}
             )
  end

  test "projects materialized communication images without changing the canonical result" do
    record = %{media_record("image/png") | content: <<0, 1, 2, 3>>}
    canonical_result = {:ok, %{record: record}, []}
    tool_call = %{id: "call-image", name: "download_document", arguments: %{}}

    assert {:ok,
            {:ok,
             %ToolResult{
               content: [%ContentPart{type: :image} = part],
               output: %{record: ^record}
             }, []}} =
             MediaResultTransformer.project_tool_result(
               tool_call,
               canonical_result,
               %{}
             )

    assert part.data == <<0, 1, 2, 3>>
    assert part.media_type == "image/png"
    assert canonical_result == {:ok, %{record: record}, []}
  end

  test "decodes base64 communication images before projecting them" do
    bytes = <<0, 1, 2, 255>>
    content = Base.encode64(bytes)
    attributes = Map.put(media_record("image/png").attributes, "encoding", "base64")
    record = %{media_record("image/png") | content: content, attributes: attributes}
    effects = [:downloaded]
    result = {:ok, %{record: record}, effects}

    assert {:ok,
            {:ok,
             %ToolResult{
               content: [%ContentPart{type: :image} = part],
               output: %{record: ^record}
             }, ^effects}} =
             MediaResultTransformer.project_tool_result(
               %{id: "call-base64", name: "download_document", arguments: %{}},
               result,
               %{}
             )

    assert part.data == bytes
    assert part.media_type == "image/png"
  end

  test "returns an unavailable fallback for invalid base64 content" do
    attributes = Map.put(media_record("image/png").attributes, "encoding", "base64")

    record = %{
      media_record("image/png")
      | content: "not base64",
        name: nil,
        attributes: attributes
    }

    effects = [:downloaded]
    result = {:ok, %{record: record}, effects}

    assert {:ok,
            {:ok,
             %ToolResult{
               content: [
                 %ContentPart{type: :text, text: "Attachment attachment could not be accessed."}
               ],
               output: %{record: ^record}
             }, ^effects}} =
             MediaResultTransformer.project_tool_result(
               %{id: "call-invalid-base64", name: "download_document", arguments: %{}},
               result,
               %{}
             )
  end

  test "projects PDFs as file content and supplies the default filename" do
    bytes = "%PDF-1.7"
    record = %{media_record("application/pdf") | content: bytes, name: nil}
    result = {:ok, %{record: record}, []}

    assert {:ok,
            {:ok,
             %ToolResult{
               content: [%ContentPart{type: :file} = part],
               output: %{record: ^record}
             }, []}} =
             MediaResultTransformer.project_tool_result(
               %{id: "call-pdf", name: "download_document", arguments: %{}},
               result,
               %{}
             )

    assert part.data == bytes
    assert part.filename == "attachment.pdf"
    assert part.media_type == "application/pdf"
  end

  test "projects valid UTF-8 text attachments as text content" do
    record = %{media_record("text/plain") | content: "hello"}
    effects = [:downloaded]
    result = {:ok, %{record: record}, effects}

    assert {:ok,
            {:ok,
             %ToolResult{
               content: [%ContentPart{type: :text, text: "hello"}],
               output: %{record: ^record}
             }, ^effects}} =
             MediaResultTransformer.project_tool_result(
               %{id: "call-text", name: "download_document", arguments: %{}},
               result,
               %{}
             )
  end

  test "returns an unsupported fallback for invalid UTF-8 text attachments" do
    record = %{media_record("text/plain") | content: <<255>>}
    effects = [:downloaded]
    result = {:ok, %{record: record}, effects}

    assert {:ok,
            {:ok,
             %ToolResult{
               content: [
                 %ContentPart{
                   type: :text,
                   text: "This attachment type is not supported for model input."
                 }
               ],
               output: %{record: ^record}
             }, ^effects}} =
             MediaResultTransformer.project_tool_result(
               %{id: "call-invalid-text", name: "download_document", arguments: %{}},
               result,
               %{}
             )
  end

  test "gives the model a fallback for unsupported materialized media" do
    record = %{media_record("audio/ogg") | content: <<0, 1, 2, 3>>}

    assert {:ok, {:ok, %ToolResult{content: [%ContentPart{type: :text, text: text}]}, []}} =
             MediaResultTransformer.project_tool_result(
               %{id: "call-audio", name: "download_document", arguments: %{}},
               {:ok, %{record: record}, []},
               %{}
             )

    assert text =~ "not supported"
  end

  test "rejects materialized media above the configured limit" do
    record = %{media_record("image/png") | size: 10, content: <<0, 1, 2, 3>>}

    assert {:ok, {:ok, %ToolResult{content: [%ContentPart{type: :text, text: text}]}, []}} =
             MediaResultTransformer.project_tool_result(
               %{id: "call-large", name: "download_document", arguments: %{}},
               {:ok, %{record: record}, []},
               %{media_max_bytes: 3}
             )

    assert text =~ "size limit"
  end

  defp media_record(mime_type) do
    %Record{
      id: "media-1",
      kind: :file,
      name: "attachment",
      mime_type: mime_type,
      size: 4,
      attributes: %{
        "source_type" => "communication_media",
        "provider" => "mattermost",
        "source_id" => "media-1"
      }
    }
  end
end
