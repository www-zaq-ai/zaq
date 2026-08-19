defmodule Zaq.Agent.MediaResultTransformer do
  @moduledoc """
  Projects materialized communication media into model-facing content.

  This plugin changes only the content sent to the next LLM turn; the canonical
  tool result remains a materialized Record for workflows and trace capture.
  """

  use Jido.Plugin,
    name: "zaq_media_result_transformer",
    description: "Projects communication media tool results for the model",
    category: "ai",
    state_key: :zaq_media_result_transformer,
    actions: []

  alias ReqLLM.Message.ContentPart
  alias Zaq.Contracts.Record

  @default_max_bytes 100 * 1024 * 1024
  @source_type "communication_media"

  @impl Jido.Plugin
  def transform_tool_result(_tool_call, content, %{tool_result: result} = context) do
    case media_record(result) do
      {:ok, record} -> project_media(record, Map.get(context, :runtime_context, %{}))
      :error -> {:ok, content}
    end
  end

  defp media_record({:ok, payload, _effects}) when is_map(payload) do
    payload
    |> Map.get(:record, Map.get(payload, "record"))
    |> communication_media_record()
  end

  defp media_record(_result), do: :error

  defp communication_media_record(%Record{content: content, attributes: attributes} = record)
       when is_binary(content) do
    if source_type(attributes) == @source_type, do: {:ok, record}, else: :error
  end

  defp communication_media_record(_record), do: :error

  defp source_type(attributes) when is_map(attributes),
    do: Map.get(attributes, :source_type, Map.get(attributes, "source_type"))

  defp source_type(_attributes), do: nil

  defp project_media(record, runtime_context) do
    max_bytes = max_bytes(runtime_context)

    with :ok <- enforce_size(record.size, max_bytes),
         {:ok, content} <- decode_content(record),
         :ok <- enforce_size(byte_size(content), max_bytes) do
      {:ok, model_content(record, content)}
    else
      {:error, :too_large} -> {:ok, fallback(record, :too_large)}
      {:error, _reason} -> {:ok, fallback(record, :unavailable)}
    end
  end

  defp decode_content(%Record{content: content, attributes: attributes})
       when is_binary(content) do
    if encoding(attributes) == "base64" do
      case Base.decode64(content) do
        {:ok, decoded} -> {:ok, decoded}
        :error -> {:error, :invalid_encoding}
      end
    else
      {:ok, content}
    end
  end

  defp decode_content(%Record{}), do: {:error, :invalid_content}

  defp encoding(attributes) when is_map(attributes),
    do: Map.get(attributes, :encoding, Map.get(attributes, "encoding"))

  defp encoding(_attributes), do: nil

  defp model_content(%Record{mime_type: "image/" <> _ = mime_type}, content) do
    [ContentPart.image(content, mime_type)]
  end

  defp model_content(%Record{mime_type: "application/pdf", name: name}, content) do
    [ContentPart.file(content, name || "attachment.pdf", "application/pdf")]
  end

  defp model_content(%Record{mime_type: "text/" <> _}, content) do
    if String.valid?(content),
      do: [ContentPart.text(content)],
      else: fallback_content(:unsupported)
  end

  defp model_content(%Record{}, _content), do: fallback_content(:unsupported)

  defp fallback(record, reason) do
    name = record_name(record)

    case reason do
      :too_large -> [ContentPart.text("Attachment #{name} exceeds the configured size limit.")]
      :unavailable -> [ContentPart.text("Attachment #{name} could not be accessed.")]
    end
  end

  defp fallback_content(:unsupported),
    do: [ContentPart.text("This attachment type is not supported for model input.")]

  defp record_name(%Record{name: name}) when is_binary(name) and name != "", do: name

  defp record_name(%Record{}), do: "attachment"

  defp enforce_size(size, max_bytes) when is_integer(size) and size > max_bytes,
    do: {:error, :too_large}

  defp enforce_size(_size, _max_bytes), do: :ok

  defp max_bytes(runtime_context) do
    case Map.get(runtime_context, :media_max_bytes) do
      max_bytes when is_integer(max_bytes) and max_bytes > 0 -> max_bytes
      _ -> Application.get_env(:zaq, :message_trace_artifact_max_bytes, @default_max_bytes)
    end
  end
end
