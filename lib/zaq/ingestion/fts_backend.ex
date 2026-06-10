defmodule Zaq.Ingestion.FTSBackend do
  @moduledoc """
  Behaviour and runtime detector for pluggable full-text search backends.

  The active backend is detected once at application startup and cached in
  `:persistent_term`, keeping search calls free of database probes.
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Zaq.Ingestion.{Document, DocumentAccess}
  alias Zaq.Repo

  require Logger

  @callback bm25_search_group_by(String.t(), pos_integer(), list()) ::
              {:ok, map()} | {:error, term()}
  @callback fts_count_query(String.t(), pos_integer()) :: Ecto.Query.t()
  @callback sanitize_query(String.t()) :: String.t()
  @callback setup_bm25_index(module(), pos_integer()) :: :ok

  @cache_key {__MODULE__, :backend}

  @doc "Returns the cached active backend module."
  def impl do
    case :persistent_term.get(@cache_key, nil) do
      nil -> detect_and_cache()
      backend -> backend
    end
  end

  @doc "Detects whether ParadeDB is installed and caches the active backend."
  def detect_and_cache do
    backend =
      case SQL.query(
             Repo,
             "SELECT 1 FROM pg_extension WHERE extname = 'pg_search' LIMIT 1",
             []
           ) do
        {:ok, %{rows: [_ | _]}} ->
          __MODULE__.ParadeDB

        {:ok, _result} ->
          __MODULE__.Native

        {:error, reason} ->
          Logger.warning(
            "[FTSBackend] detection failed, falling back to native: #{inspect(reason)}"
          )

          __MODULE__.Native
      end

    :persistent_term.put(@cache_key, backend)
    Logger.info("[FTSBackend] active backend: #{inspect(backend)}")
    backend
  end

  @doc "Clears the cached backend. Use in tests or after extension changes."
  def reset_cache do
    :persistent_term.erase(@cache_key)
    :ok
  end

  @doc """
  Sanitizes free-form user input for PostgreSQL full-text query functions.
  """
  def sanitize_query_text(text) do
    text
    |> sanitize_utf8_text()
    |> unicode_normalize()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.replace(~r/ {2,}/, " ")
    |> String.trim()
    |> String.slice(0, 512)
  end

  @doc """
  Removes invalid UTF-8 bytes and null bytes while preserving document content.
  """
  def sanitize_utf8_text(binary), do: sanitize_utf8(binary, [])

  @doc """
  Adds the shared document source filter join to a backend search query.
  """
  def maybe_filter_source(query, []), do: query

  def maybe_filter_source(query, source_filter) do
    query
    |> join(:inner, [c], d in Document, on: c.document_id == d.id, as: :doc)
    |> where(^DocumentAccess.build_source_filter_condition(source_filter))
  end

  @doc """
  Groups flat backend search rows by document ID and section path.
  """
  def group_results(results) do
    results
    |> Enum.group_by(& &1.document_id)
    |> Map.new(fn {doc_id, items} ->
      {doc_id, Enum.group_by(items, & &1.section_path)}
    end)
  end

  defp unicode_normalize(text) do
    case :unicode.characters_to_nfc_binary(text) do
      normalized when is_binary(normalized) -> normalized
      _ -> text
    end
  end

  defp sanitize_utf8(<<0, rest::binary>>, acc), do: sanitize_utf8(rest, acc)
  defp sanitize_utf8(<<>>, acc), do: IO.iodata_to_binary(:lists.reverse(acc))
  defp sanitize_utf8(<<c::utf8, rest::binary>>, acc), do: sanitize_utf8(rest, [<<c::utf8>> | acc])
  defp sanitize_utf8(<<_::8, rest::binary>>, acc), do: sanitize_utf8(rest, acc)
end
