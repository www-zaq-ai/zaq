defmodule Zaq.Ingestion.Python.Pipeline do
  @moduledoc """
  Elixir orchestrator for the PDF → clean markdown pipeline.

  Calls each Python step script individually so steps can be
  conditionally skipped. Steps 4 and 5 (image descriptions) are
  skipped when no Scaleway API key is configured.

  ## Usage

      Pipeline.run("/path/to/report.pdf")
      # => {:ok, "/path/to/report.md"} | {:error, reason}

  """

  require Logger

  alias Zaq.Ingestion.FileExplorer

  alias Zaq.Ingestion.Python.Steps.{
    CleanMd,
    ImageDedup,
    ImageToText,
    InjectDescriptions,
    PdfToMd
  }

  @doc """
  Run the full pipeline for a single PDF.
  Returns `{:ok, md_path}` on success.
  """
  @spec run(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run(pdf_path, opts \\ []) do
    api_key = resolve_api_key(opts)
    md_path = opts[:output] || Path.rootname(pdf_path) <> ".md"
    base = opts[:base] || resolve_volume_base(pdf_path)
    images_dir = opts[:images_dir] || Path.join(base, "images")

    pdf_name = Path.basename(pdf_path, ".pdf")
    images_folder = Path.join(images_dir, pdf_name)
    descriptions_json = Path.join(images_folder, "descriptions.json")

    result =
      with {:ok, _} <- PdfToMd.run(pdf_path, md_path, images_dir),
           {:ok, _} <- ImageDedup.run(images_folder),
           {:ok, _} <- CleanMd.run(md_path, images_folder),
           {:ok, _} <- maybe_image_to_text(api_key, images_folder, descriptions_json),
           {:ok, _} <- maybe_inject_descriptions(api_key, md_path, descriptions_json) do
        {:ok, md_path}
      end

    case result do
      {:ok, md_path} ->
        cleanup_images(images_dir, images_folder)
        {:ok, md_path}

      {:error, reason} ->
        move_to_debug(base, images_folder, pdf_name)
        {:error, reason}
    end
  end

  # --- Private ---

  defp resolve_volume_base(pdf_path) do
    expanded = Path.expand(pdf_path)

    FileExplorer.list_volumes()
    |> Map.values()
    |> Enum.find(fn vol_root -> String.starts_with?(expanded, vol_root <> "/") end)
    |> case do
      nil -> FileExplorer.base_path()
      vol_root -> vol_root
    end
  end

  defp resolve_api_key(opts) do
    key =
      opts[:api_key] ||
        Application.get_env(:zaq, Zaq.Ingestion.Python.ImageToText, [])[:api_key]

    if key && key != "", do: key, else: nil
  end

  defp maybe_image_to_text(nil, _folder, _output) do
    Logger.warning("[Pipeline] No Scaleway API key — skipping image descriptions")
    {:ok, :skipped}
  end

  defp maybe_image_to_text(api_key, images_folder, descriptions_json) do
    ImageToText.run(images_folder, descriptions_json, api_key)
  end

  defp maybe_inject_descriptions(nil, _md_path, _descriptions_json) do
    {:ok, :skipped}
  end

  defp maybe_inject_descriptions(_api_key, md_path, descriptions_json) do
    InjectDescriptions.run(md_path, descriptions_json)
  end

  defp cleanup_images(images_dir, images_folder) do
    if File.dir?(images_folder) do
      File.rm_rf!(images_folder)
      Logger.info("[Pipeline] Cleaned up images folder: #{images_folder}")
    end

    # Remove the parent images/ dir if now empty
    if File.dir?(images_dir) and File.ls!(images_dir) == [] do
      File.rmdir(images_dir)
    end
  end

  defp move_to_debug(base, images_folder, pdf_name) do
    if File.dir?(images_folder) do
      debug_dir = Path.join(base, "debugging")
      debug_dest = Path.join(debug_dir, pdf_name)
      File.mkdir_p!(debug_dir)
      File.rename(images_folder, debug_dest)
      Logger.warning("[Pipeline] Debug images saved to: #{debug_dest}")
    end
  end
end
