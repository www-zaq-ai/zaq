defmodule Zaq.Ingestion.ArtifactType do
  @moduledoc """
  Owns ingestion artifact MIME normalization and safe extension handling.

  The MIME library remains the mapping source. Only explicitly registered MIME
  types are accepted, so its structured-suffix fallback cannot make an unknown
  specific type look recognized. Representation precedence and materialization
  fallback policy belong to `Zaq.Ingestion.RecordSource`.
  """

  alias Plug.Conn.Utils

  @safe_extension ~r/\A\.[a-z0-9]+\z/

  @doc "Returns the first safe extension for an explicitly registered MIME type."
  @spec canonical_extension(String.t() | nil) :: String.t() | nil
  def canonical_extension(mime_type), do: mime_type |> extensions() |> List.first()

  @doc "Checks all mapped aliases, ignoring MIME parameters and case."
  @spec compatible_extension?(String.t() | nil, String.t() | nil) :: boolean()
  def compatible_extension?(mime_type, extension) do
    case normalize_extension(extension) do
      nil -> false
      extension -> extension in extensions(mime_type)
    end
  end

  @doc "Returns a safe, lowercase filename extension or nil."
  @spec filename_extension(String.t() | nil) :: String.t() | nil
  def filename_extension(filename) when is_binary(filename) do
    filename
    |> Path.extname()
    |> normalize_extension()
  end

  def filename_extension(_filename), do: nil

  @doc "Checks whether MIME metadata is absent or generic binary data."
  @spec nonspecific_mime?(term()) :: boolean()
  def nonspecific_mime?(nil), do: true

  def nonspecific_mime?(mime_type) when is_binary(mime_type) do
    String.trim(mime_type) == "" || normalize_mime_type(mime_type) == "application/octet-stream"
  end

  def nonspecific_mime?(_mime_type), do: false

  defp extensions(mime_type) when is_binary(mime_type) do
    with normalized when is_binary(normalized) <- normalize_mime_type(mime_type),
         true <- Map.has_key?(MIME.known_types(), normalized) do
      normalized
      |> MIME.extensions()
      |> Enum.map(&normalize_extension("." <> &1))
      |> Enum.reject(&is_nil/1)
    else
      _ -> []
    end
  end

  defp extensions(_mime_type), do: []

  defp normalize_mime_type(mime_type) do
    case Utils.media_type(mime_type) do
      {:ok, type, subtype, _params} -> type <> "/" <> subtype
      :error -> nil
    end
  end

  defp normalize_extension(extension) when is_binary(extension) do
    extension = String.downcase(extension)
    if Regex.match?(@safe_extension, extension), do: extension
  end

  defp normalize_extension(_extension), do: nil
end
