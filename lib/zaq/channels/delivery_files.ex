defmodule Zaq.Channels.DeliveryFiles do
  @moduledoc """
  Prepares explicitly supplied file Records for delivery.

  Existing binary content is used directly. Lazy Records are redeemed through the
  registered materialization handlers with normalized trusted identity; returned
  name and MIME describe the acquired representation when supplied. Only raw
  bytes and safe transport metadata reach the consumer; source paths, credentials
  and handles are never forwarded or retained. No temporary files are created or
  original source files deleted. Materialization still acquires whole content.
  """

  alias Zaq.Agent.Tools.General.DecodeBase64
  alias Zaq.Channels.DeliveryError
  alias Zaq.Contracts.Record
  alias Zaq.Events.TrustedContext
  alias Zaq.Materialization

  @type prepared :: %{
          optional(:attachment_index) => non_neg_integer(),
          content: binary(),
          name: String.t(),
          mime_type: String.t(),
          size: non_neg_integer()
        }

  @doc """
  Returns prepared files in input order, or a preparation error.

  Decodes only explicitly declared standard base64 content through `DecodeBase64`,
  accepting whitespace and optional padding; nil or `"binary"` encoding
  preserves bytes verbatim. Empty attachments return `{:ok, []}` without source access.
  `:node_router` in opts is a local execution dependency, never an identity input.
  With `:attachment_failure_policy`, returns `{:ok, files, failures}` and gives
  each prepared file its original `:attachment_index`. `:continue` retains usable
  files after failures; `:abort` returns the first preparation error. Omitting the
  option preserves the two-element success tuple and fail-fast behavior.
  """
  @spec prepare([Record.t()], map(), keyword()) ::
          {:ok, [prepared()]} | {:ok, [prepared()], [map()]} | {:error, term()}
  def prepare(records, context, opts \\ [])

  def prepare(records, context, opts)
      when is_list(records) and is_map(context) and is_list(opts) do
    source_context =
      context
      |> TrustedContext.normalize()
      |> Map.from_struct()
      |> Map.merge(Map.new(Keyword.take(opts, [:node_router])))

    case Keyword.get(opts, :attachment_failure_policy) do
      policy when policy in [nil, :continue, :abort] ->
        prepare_all(records, source_context, policy)

      policy ->
        {:error, {:invalid_attachment_failure_policy, policy}}
    end
  end

  def prepare(_records, _context, _opts),
    do: {:error, :invalid_attachments}

  @doc "Maps shared attachment selection and preparation failures before transport."
  @spec delivery_error(term()) :: DeliveryError.t()
  def delivery_error(:invalid_attachment_selection) do
    %DeliveryError{
      reason: :invalid_attachment_selection,
      message: "The requested files could not be attached.",
      stage: :selection,
      delivery: :not_sent
    }
  end

  def delivery_error(reason) do
    %DeliveryError{
      reason: reason,
      message: preparation_message(reason),
      stage: :preparation,
      delivery: :not_sent
    }
  end

  defp preparation_message(:invalid_attachment_base64),
    do: "The attachment contains invalid Base64 content."

  defp preparation_message(:invalid_attachment_encoding),
    do: "The attachment encoding is not supported."

  defp preparation_message(:invalid_attachment_metadata),
    do: "The attachment filename or content type is invalid."

  defp preparation_message(reason)
       when reason in [:invalid_attachments, :invalid_attachment, :invalid_attachment_content],
       do: "The attachment data is invalid."

  defp preparation_message(_reason), do: "The attachment content could not be accessed."

  defp prepare_all(records, context, policy) do
    records
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], []}, fn {record, index}, accumulator ->
      prepare_next(record, index, context, policy, accumulator)
    end)
    |> case do
      {:ok, files, _failures} when is_nil(policy) -> {:ok, Enum.reverse(files)}
      {:ok, files, failures} -> {:ok, Enum.reverse(files), Enum.reverse(failures)}
      error -> error
    end
  end

  defp prepare_next(record, index, context, policy, {:ok, files, failures}) do
    case prepare_record(record, context) do
      {:ok, file} ->
        prepared = if is_nil(policy), do: file, else: Map.put(file, :attachment_index, index)
        {:cont, {:ok, [prepared | files], failures}}

      {:error, reason} when policy == :continue ->
        failure = %{
          attachment_index: index,
          stage: :preparation,
          delivery: :not_sent,
          reason: delivery_error(reason).message
        }

        {:cont, {:ok, files, [failure | failures]}}

      {:error, _} = error ->
        {:halt, error}
    end
  end

  defp prepare_record(%Record{id: id, kind: :file, attributes: attrs} = record, context)
       when is_binary(id) and id != "" and is_map(attrs) do
    with :ok <- validate_metadata(record),
         {:ok, materialized} <- acquire(record, context),
         :ok <- validate_metadata(materialized),
         {:ok, content} <- decode_content(materialized) do
      {:ok,
       %{
         content: content,
         name: materialized.name || record.name || "attachment",
         mime_type: materialized.mime_type || record.mime_type || "application/octet-stream",
         size: byte_size(content)
       }}
    end
  end

  defp prepare_record(_record, _context), do: {:error, :invalid_attachment}

  defp acquire(%Record{content: content} = record, _context) when is_binary(content),
    do: {:ok, record}

  defp acquire(%Record{content: nil, materialization_handle: handle}, context)
       when is_binary(handle) and handle != "" do
    Materialization.materialize(handle, context, "Attachment preparation failed")
    |> case do
      {:ok, %{record: %Record{kind: :file, attributes: attrs} = record}} when is_map(attrs) ->
        {:ok, record}

      {:ok, _} ->
        {:error, :invalid_attachment}

      {:error, _} = error ->
        error
    end
  end

  defp acquire(%Record{content: nil}, _context), do: {:error, :attachment_content_unavailable}
  defp acquire(_record, _context), do: {:error, :invalid_attachment_content}

  defp decode_content(%Record{content: content, attributes: attrs}) when is_binary(content) do
    case Map.get(attrs, "encoding", Map.get(attrs, :encoding)) do
      "base64" ->
        case Jido.Exec.run(DecodeBase64, %{data: content, variant: "standard"}, %{}) do
          {:ok, %{decoded: bytes}} -> {:ok, bytes}
          {:error, _reason} -> {:error, :invalid_attachment_base64}
        end

      encoding when encoding in [nil, "binary"] ->
        {:ok, content}

      _ ->
        {:error, :invalid_attachment_encoding}
    end
  end

  defp decode_content(_record), do: {:error, :invalid_attachment_content}

  defp validate_metadata(%Record{name: name, mime_type: mime_type}) do
    if valid_name?(name) and valid_mime?(mime_type),
      do: :ok,
      else: {:error, :invalid_attachment_metadata}
  end

  defp valid_name?(nil), do: true

  defp valid_name?(name) when is_binary(name) and name != "" do
    String.valid?(name) and name not in [".", ".."] and
      not String.match?(name, ~r/[\x00-\x1f\x7f\/\\]/u)
  end

  defp valid_name?(_name), do: false

  defp valid_mime?(nil), do: true

  defp valid_mime?(mime_type) when is_binary(mime_type) do
    String.match?(mime_type, ~r/\A[A-Za-z0-9!#$&^_.+\-]+\/[A-Za-z0-9!#$&^_.+\-]+\z/)
  end

  defp valid_mime?(_mime_type), do: false
end
