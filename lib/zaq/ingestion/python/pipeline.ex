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

  alias Zaq.Agent.PromptTemplate
  alias Zaq.Ingestion.SourcePath

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
    original_pdf_path = pdf_path
    api_key = resolve_api_key(opts)
    md_path = opts[:output] || Path.rootname(original_pdf_path) <> ".md"
    base = opts[:base] || resolve_volume_base(original_pdf_path)

    images_dir =
      opts[:images_dir] ||
        Path.join(System.tmp_dir!(), "zaq_images_#{System.unique_integer([:positive])}")

    {pipeline_pdf_path, cleanup_pdf_alias} = prepare_pdf_input(original_pdf_path)

    pdf_name = Path.basename(pipeline_pdf_path, ".pdf")
    images_folder = Path.join(images_dir, pdf_name)
    descriptions_json = Path.join(images_folder, "descriptions.json")

    result =
      try do
        with {:ok, _} <- PdfToMd.run(pipeline_pdf_path, md_path, images_dir),
             {:ok, _} <- ImageDedup.run(images_folder),
             {:ok, _} <- CleanMd.run(md_path, images_folder),
             {:ok, _} <-
               maybe_image_to_text(
                 api_key,
                 images_folder,
                 descriptions_json,
                 resolve_image_to_text_prompt()
               ),
             {:ok, _} <- maybe_inject_descriptions(api_key, md_path, descriptions_json) do
          {:ok, md_path}
        end
      after
        cleanup_pdf_alias.()
      end

    case result do
      {:ok, md_path} ->
        strip_local_image_refs(md_path)
        File.rm_rf!(images_dir)
        {:ok, md_path}

      {:error, reason} ->
        move_to_debug(base, images_folder, pdf_name)
        File.rm_rf!(images_dir)
        {:error, reason}
    end
  end

  # --- Private ---

  defp resolve_volume_base(pdf_path) do
    SourcePath.volume_root_for_absolute(pdf_path)
  end

  defp resolve_api_key(opts) do
    key =
      opts[:api_key] ||
        Zaq.System.get_image_to_text_config().api_key

    if key && key != "", do: key, else: nil
  end

  defp maybe_image_to_text(nil, _folder, _output, _prompt) do
    Logger.warning("[Pipeline] No Scaleway API key — skipping image descriptions")
    {:ok, :skipped}
  end

  defp maybe_image_to_text(api_key, images_folder, descriptions_json, prompt) do
    opts = [api_key: api_key]
    opts = if prompt, do: Keyword.put(opts, :prompt, prompt), else: opts
    ImageToText.run(images_folder, descriptions_json, opts)
  end

  defp resolve_image_to_text_prompt do
    case PromptTemplate.get_active("image_to_text") do
      {:ok, body} -> body
      {:error, :not_found} -> nil
    end
  end

  defp maybe_inject_descriptions(nil, _md_path, _descriptions_json) do
    {:ok, :skipped}
  end

  defp maybe_inject_descriptions(_api_key, md_path, descriptions_json) do
    if File.exists?(descriptions_json) do
      InjectDescriptions.run(md_path, descriptions_json)
    else
      Logger.info("[Pipeline] No descriptions.json found — skipping injection")
      {:ok, :skipped}
    end
  end

  # Removes markdown image references pointing to local absolute paths (e.g. /tmp/...).
  # These are left behind when the image-to-text step is skipped (no API key).
  # Keeping them causes 404s in the preview because Phoenix does not serve /tmp.
  defp strip_local_image_refs(md_path) do
    case File.read(md_path) do
      {:ok, content} ->
        stripped = Regex.replace(~r/!\[[^\]]*\]\(\/[^)]+\)\n?/, content, "")

        if stripped != content do
          File.write!(md_path, stripped)
          Logger.info("[Pipeline] Stripped local image references from #{md_path}")
        end

      {:error, reason} ->
        Logger.warning("[Pipeline] Could not strip image refs from #{md_path}: #{inspect(reason)}")
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

  defp prepare_pdf_input(pdf_path) do
    basename = Path.basename(pdf_path)

    if String.contains?(basename, " ") do
      alias_path = build_pdf_alias_path(pdf_path)

      case create_pdf_alias(pdf_path, alias_path) do
        :ok ->
          Logger.info("[Pipeline] Using temporary PDF alias for processing: #{alias_path}")
          {alias_path, fn -> cleanup_pdf_alias(alias_path) end}

        {:error, reason} ->
          Logger.warning(
            "[Pipeline] Failed to create PDF alias, using original path: #{inspect(reason)}"
          )

          {pdf_path, fn -> :ok end}
      end
    else
      {pdf_path, fn -> :ok end}
    end
  end

  defp build_pdf_alias_path(pdf_path) do
    dir = Path.dirname(pdf_path)
    ext = Path.extname(pdf_path)

    normalized_stem =
      pdf_path
      |> Path.basename(ext)
      |> String.replace(~r/\s+/, "_")

    candidate = Path.join(dir, normalized_stem <> ext)

    if File.exists?(candidate) do
      unique = System.unique_integer([:positive])
      Path.join(dir, "#{normalized_stem}__zaq_tmp_#{unique}#{ext}")
    else
      candidate
    end
  end

  defp create_pdf_alias(source, alias_path) do
    case File.ln_s(source, alias_path) do
      :ok ->
        :ok

      {:error, _} ->
        File.cp(source, alias_path)
    end
  end

  defp cleanup_pdf_alias(alias_path) do
    case File.rm(alias_path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Pipeline] Failed to remove temporary PDF alias: #{inspect(reason)}")
        :ok
    end
  end
end
