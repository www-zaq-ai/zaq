defmodule Zaq.Agent.MediaResultTransformerTest do
  use ExUnit.Case, async: true

  alias Jido.AI.Turn
  alias ReqLLM.Message.ContentPart
  alias Zaq.Agent.MediaResultTransformer
  alias Zaq.Contracts.{Record, RecordCapability}

  test "passes non-media tool results through the default formatter" do
    result = {:ok, %{answer: 42}, []}

    assert {:ok, content} =
             MediaResultTransformer.transform_tool_result(
               %{id: "call-1", name: "calculator", arguments: %{}},
               Turn.format_tool_result_content(result),
               %{tool_result: result, runtime_context: %{}}
             )

    assert content == Turn.format_tool_result_content(result)
  end

  test "projects materialized communication images without changing the canonical result" do
    record = %{media_record("image/png") | content: <<0, 1, 2, 3>>}
    canonical_result = {:ok, %{record: record}, []}
    tool_call = %{id: "call-image", name: "download_document", arguments: %{}}

    assert {:ok, [%ContentPart{type: :image} = part]} =
             MediaResultTransformer.transform_tool_result(
               tool_call,
               Turn.format_tool_result_content(canonical_result),
               %{tool_result: canonical_result, runtime_context: %{}}
             )

    assert part.data == <<0, 1, 2, 3>>
    assert part.media_type == "image/png"
    assert canonical_result == {:ok, %{record: record}, []}
  end

  test "gives the model a fallback for unsupported materialized media" do
    record = %{media_record("audio/ogg") | content: <<0, 1, 2, 3>>}

    assert {:ok, [%ContentPart{type: :text, text: text}]} =
             MediaResultTransformer.transform_tool_result(
               %{id: "call-audio", name: "download_document", arguments: %{}},
               "default",
               %{tool_result: {:ok, %{record: record}, []}, runtime_context: %{}}
             )

    assert text =~ "not supported"
  end

  test "rejects materialized media above the configured limit" do
    record = %{media_record("image/png") | size: 10, content: <<0, 1, 2, 3>>}

    assert {:ok, [%ContentPart{type: :text, text: text}]} =
             MediaResultTransformer.transform_tool_result(
               %{id: "call-large", name: "download_document", arguments: %{}},
               "default",
               %{
                 tool_result: {:ok, %{record: record}, []},
                 runtime_context: %{media_max_bytes: 3}
               }
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
    |> RecordCapability.sign!()
  end
end
