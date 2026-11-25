defmodule Zaq.Ingestion.ImageMarkdown do
  @moduledoc """
  Converts standalone PNG and JPEG files for the legacy ingestion path.

  The document conversion Action does not accept standalone images.
  """

  alias Zaq.Ingestion.FTSBackend
  alias Zaq.Ingestion.Python.Steps.ImageToText

  require Logger

  @doc "Writes the Markdown description next to the ingestion input."
  @spec convert(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def convert(file_path, md_path, opts) do
    with {:ok, markdown} <- read_image_as_markdown(file_path, opts),
         :ok <- File.write(md_path, markdown) do
      {:ok, markdown}
    end
  end

  defp read_image_as_markdown(file_path, opts) do
    {safe_path, cleanup_alias} = prepare_image_input(file_path)
    output_json = image_description_output_path(file_path)
    image_step = Zaq.Config.get(:zaq, :image_to_text_step_module, ImageToText, opts)

    try do
      with {:ok, vision_opts} <- image_to_text_opts(),
           {:ok, _} <- image_step.run_single(safe_path, output_json, vision_opts),
           {:ok, raw_json} <- File.read(output_json),
           {:ok, description} <- extract_image_description(raw_json, file_path) do
        markdown = build_image_markdown(Path.basename(file_path), description)
        {:ok, FTSBackend.sanitize_utf8_text(markdown)}
      end
    after
      cleanup_alias.()
      _ = File.rm(output_json)
    end
  end

  # Python requires an ASCII-safe basename.
  defp prepare_image_input(image_path) do
    basename = Path.basename(image_path)

    if String.match?(basename, ~r/[^a-zA-Z0-9._\-]/) do
      alias_path = build_image_alias_path(image_path)
      create_image_alias(image_path, alias_path)
    else
      {image_path, fn -> :ok end}
    end
  end

  defp create_image_alias(image_path, alias_path) do
    case File.ln_s(image_path, alias_path) do
      :ok -> {alias_path, fn -> File.rm(alias_path) end}
      {:error, _} -> create_image_alias_copy(image_path, alias_path)
    end
  end

  defp create_image_alias_copy(image_path, alias_path) do
    case File.cp(image_path, alias_path) do
      :ok ->
        {alias_path, fn -> File.rm(alias_path) end}

      {:error, reason} ->
        Logger.warning("Failed to create image alias copy at #{alias_path}: #{inspect(reason)}")
        {image_path, fn -> :ok end}
    end
  end

  defp build_image_alias_path(image_path) do
    dir = Path.dirname(image_path)
    ext = Path.extname(image_path)
    unique = System.unique_integer([:positive])

    normalized_stem =
      image_path
      |> Path.basename(ext)
      |> String.replace(~r/[^a-zA-Z0-9._\-]/, "_")

    Path.join(dir, "#{normalized_stem}__zaq_tmp_#{unique}#{ext}")
  end

  defp image_description_output_path(file_path) do
    stem =
      file_path
      |> Path.basename(Path.extname(file_path))
      |> String.replace(~r/[^a-zA-Z0-9._\-]/, "_")

    Path.join(
      System.tmp_dir!(),
      "zaq_image_to_text_#{stem}_#{System.unique_integer([:positive])}.json"
    )
  end

  defp image_to_text_opts do
    cfg = Zaq.System.get_image_to_text_config()

    if is_binary(cfg.api_key) and cfg.api_key != "" do
      opts =
        [api_key: cfg.api_key]
        |> maybe_put(:endpoint, cfg.endpoint)
        |> maybe_put(:model, cfg.model)

      {:ok, opts}
    else
      {:error,
       "Image to text is not configured; set it in System settings to enable PNG/JPG ingestion"}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp extract_image_description(raw_json, file_path) do
    image_name = Path.basename(file_path)

    with {:ok, decoded} <- Jason.decode(raw_json),
         {:ok, description} <- pick_image_description(decoded, image_name),
         :ok <- validate_image_description(description, image_name) do
      {:ok, description}
    end
  end

  defp pick_image_description(%{} = payload, image_name) do
    description =
      Map.get(payload, image_name) ||
        Map.get(payload, String.downcase(image_name)) ||
        single_payload_value(payload)

    {:ok, description}
  end

  defp pick_image_description(_payload, image_name) do
    {:error, "Image-to-text output missing description for #{image_name}"}
  end

  defp single_payload_value(payload) do
    case Map.values(payload) do
      [single] -> single
      _ -> nil
    end
  end

  defp validate_image_description(description, image_name)
       when not is_binary(description) or description == "" do
    {:error, "Image-to-text output missing description for #{image_name}"}
  end

  defp validate_image_description(description, image_name) do
    trimmed_description = String.trim(description)

    cond do
      trimmed_description == "" ->
        {:error, "Image-to-text output missing description for #{image_name}"}

      String.starts_with?(trimmed_description, "ERROR:") ->
        {:error, trimmed_description}

      true ->
        :ok
    end
  end

  defp build_image_markdown(image_name, description) do
    quoted_description =
      description
      |> String.trim()
      |> String.split("\n")
      |> Enum.map_join("\n", fn
        "" -> ">"
        line -> "> #{line}"
      end)

    "> **[Image: #{image_name}]**\n#{quoted_description}\n"
  end
end
