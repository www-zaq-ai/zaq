defmodule Zaq.Ingestion.Sidecar do
  @moduledoc """
  Shared helpers for sidecar companion metadata and source derivation.
  """

  @sidecar_source_key "sidecar_source"
  @source_document_source_key "source_document_source"
  @source_extensions ~w(.pdf .docx .xlsx .png .jpg)

  @doc """
  Returns expected markdown sidecar path for a source file path.
  """
  def sidecar_path_for(file_path) do
    case Path.extname(file_path) |> String.downcase() do
      ext when ext in @source_extensions -> Path.rootname(file_path) <> ".md"
      _ -> nil
    end
  end

  @doc """
  Metadata for source documents pointing to their sidecar source.
  """
  def source_metadata(nil), do: %{}
  def source_metadata(sidecar_source), do: %{@sidecar_source_key => sidecar_source}

  @doc """
  Sets or removes the sidecar source key in metadata while preserving other keys.
  """
  def put_sidecar_source(metadata, sidecar_source) do
    metadata
    |> normalize_metadata()
    |> put_or_drop(@sidecar_source_key, sidecar_source, :sidecar_source)
  end

  @doc """
  Metadata for sidecar documents pointing back to their source document.
  """
  def sidecar_metadata(source_document_source) do
    %{@source_document_source_key => source_document_source}
  end

  @doc """
  Sets or removes the source-document source key in metadata while preserving other keys.
  """
  def put_source_document_source(metadata, source_document_source) do
    metadata
    |> normalize_metadata()
    |> put_or_drop(
      @source_document_source_key,
      source_document_source,
      :source_document_source
    )
  end

  @doc """
  Reads sidecar source from a metadata map or a struct containing metadata.
  """
  def sidecar_source(%{metadata: metadata}), do: sidecar_source(metadata)

  def sidecar_source(metadata) when is_map(metadata) do
    case Map.get(metadata, @sidecar_source_key) || Map.get(metadata, :sidecar_source) do
      source when is_binary(source) and source != "" -> source
      _ -> nil
    end
  end

  def sidecar_source(_), do: nil

  @doc """
  Builds a new sidecar relative path that follows source move/rename operations.

  If the current sidecar basename starts with the source basename, the same suffix
  is preserved (e.g. `report.generated.md` -> `report-v2.generated.md`).
  Otherwise the original sidecar basename is kept and only directory moves apply.
  """
  def retarget_relative_path(old_source_relative, old_sidecar_relative, new_source_relative) do
    old_source_base = old_source_relative |> Path.basename() |> Path.rootname()
    old_sidecar_base = old_sidecar_relative |> Path.basename() |> Path.rootname()
    old_sidecar_ext = Path.extname(old_sidecar_relative)

    new_source_base = new_source_relative |> Path.basename() |> Path.rootname()

    new_sidecar_base =
      if String.starts_with?(old_sidecar_base, old_source_base) do
        suffix = String.replace_prefix(old_sidecar_base, old_source_base, "")
        new_source_base <> suffix
      else
        old_sidecar_base
      end

    new_sidecar_name = new_sidecar_base <> fallback_ext(old_sidecar_ext)
    new_dir = Path.dirname(new_source_relative)

    case new_dir do
      "." -> new_sidecar_name
      _ -> Path.join(new_dir, new_sidecar_name)
    end
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_), do: %{}

  defp put_or_drop(metadata, string_key, value, atom_key) when is_binary(value) and value != "" do
    metadata
    |> Map.put(string_key, value)
    |> Map.delete(atom_key)
  end

  defp put_or_drop(metadata, string_key, _value, atom_key) do
    metadata
    |> Map.delete(string_key)
    |> Map.delete(atom_key)
  end

  defp fallback_ext(""), do: ".md"
  defp fallback_ext(ext), do: ext
end
