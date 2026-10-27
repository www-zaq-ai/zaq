defmodule Zaq.Channels.DeliveryFiles do
  @moduledoc """
  Prepares explicitly supplied file Records for a synchronous delivery consumer.

  Existing binary content is used directly. Lazy Records are redeemed through the
  registered materialization handlers with normalized trusted identity; returned
  name and MIME describe the acquired representation when supplied. Only raw
  bytes and safe transport metadata reach the consumer; source paths, credentials
  and handles are never forwarded or retained. No temporary files are created or
  original source files deleted. Materialization still acquires whole content.
  """

  alias Zaq.Contracts.Record
  alias Zaq.Events.TrustedContext
  alias Zaq.Materialization

  @type prepared :: %{
          content: binary(),
          name: String.t(),
          mime_type: String.t(),
          size: non_neg_integer()
        }

  @doc """
  Invokes the consumer once with prepared files, or returns a preparation error.

  Decodes only explicitly declared base64 content; nil or `"binary"` encoding
  preserves bytes verbatim. Consumer returns and exceptions propagate unchanged.
  Prepared binaries live only within this call unless the consumer retains them.
  `:node_router` in opts is a local execution dependency, never an identity input.
  """
  @spec with_prepared([Record.t()], map(), ([prepared()] -> result), keyword()) ::
          result | {:error, term()}
        when result: term()
  def with_prepared(records, context, consumer, opts \\ [])

  def with_prepared(records, context, consumer, opts)
      when is_list(records) and is_map(context) and is_function(consumer, 1) and is_list(opts) do
    source_context =
      context
      |> TrustedContext.normalize()
      |> Map.from_struct()
      |> Map.merge(Map.new(Keyword.take(opts, [:node_router])))

    with {:ok, files} <- prepare_all(records, source_context) do
      consumer.(files)
    end
  end

  def with_prepared(_records, _context, _consumer, _opts),
    do: {:error, :invalid_attachments}

  defp prepare_all(records, context) do
    records
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, files} ->
      case prepare(record, context) do
        {:ok, file} -> {:cont, {:ok, [file | files]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  end

  defp prepare(%Record{id: id, kind: :file, attributes: attrs} = record, context)
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

  defp prepare(_record, _context), do: {:error, :invalid_attachment}

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
        case Base.decode64(content) do
          {:ok, bytes} -> {:ok, bytes}
          :error -> {:error, :invalid_attachment_base64}
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
