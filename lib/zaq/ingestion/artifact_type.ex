defmodule Zaq.Ingestion.ArtifactType do
  @moduledoc """
  Maps artifact MIME types to safe extensions and checks extension compatibility.

  Uses the MIME library's ordered mappings. Filename selection and materialization
  fallback policy belong to `Zaq.Ingestion.RecordSource`.
  """

  @doc "Returns the first safe mapped extension, or nil for an unmapped MIME type."
  @spec canonical_extension(String.t() | nil) :: String.t() | nil
  def canonical_extension(mime_type), do: mime_type |> extensions() |> List.first()

  @doc "Checks all mapped aliases, ignoring MIME parameters and case."
  @spec compatible_extension?(String.t() | nil, String.t() | nil) :: boolean()
  def compatible_extension?(mime_type, extension) when is_binary(extension) do
    String.downcase(extension) in extensions(mime_type)
  end

  def compatible_extension?(_mime_type, _extension), do: false

  defp extensions(mime_type) when is_binary(mime_type) do
    mime_type
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> String.downcase()
    |> MIME.extensions()
    |> Enum.map(&("." <> String.downcase(&1)))
    |> Enum.filter(&Regex.match?(~r/\A\.[a-z0-9]+\z/, &1))
  end

  defp extensions(_mime_type), do: []
end
