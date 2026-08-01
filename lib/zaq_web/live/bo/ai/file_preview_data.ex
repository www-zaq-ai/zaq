defmodule ZaqWeb.Live.BO.AI.FilePreviewData do
  @moduledoc """
  Shared preview payload builder used by BO file preview surfaces.
  """

  alias Zaq.Ingestion
  alias Zaq.Ingestion.FileExplorer
  alias Zaq.Ingestion.Python.Steps.{DocxToMd, XlsxToMd}
  alias ZaqWeb.Helpers.Markdown

  @markdown_extension ".md"
  @text_extensions ~w(.txt)
  @image_extensions ~w(.png .jpg .jpeg .gif .webp)
  @pdf_extension ".pdf"
  @docx_extension ".docx"
  @xlsx_extensions ~w(.xlsx .xls .csv)

  @previewable_extensions [
    @markdown_extension,
    @pdf_extension,
    @docx_extension
    | @text_extensions ++ @image_extensions ++ @xlsx_extensions
  ]

  @spec previewable_path?(String.t()) :: boolean()
  def previewable_path?(path) when is_binary(path) and path != "" do
    path
    |> Path.extname()
    |> String.downcase()
    |> then(&(&1 in @previewable_extensions))
  end

  def previewable_path?(_), do: false

  @spec load(String.t(), map()) :: {:ok, map()} | {:error, :unauthorized}
  def load(relative_path, current_user) do
    if Ingestion.can_access_file?(relative_path, current_user) do
      filename = Path.basename(relative_path)
      ext = relative_path |> Path.extname() |> String.downcase()

      result =
        with {:ok, full_path} <- FileExplorer.resolve_path(relative_path),
             false <- File.dir?(full_path),
             {:ok, stat} <- File.stat(full_path, time: :posix) do
          {:ok, full_path, stat}
        else
          true -> {:error, :is_directory}
          {:error, reason} -> {:error, reason}
        end

      case result do
        {:ok, full_path, stat} ->
          {kind, content, rendered_html} = load_content(full_path, ext)

          {:ok,
           %{
             relative_path: relative_path,
             filename: filename,
             ext: ext,
             kind: kind,
             content: content,
             rendered_html: rendered_html,
             file_size: stat.size,
             modified_at: stat.mtime |> DateTime.from_unix!(),
             raw_url: "/bo/files/#{relative_path}"
           }}

        {:error, _reason} ->
          {:ok,
           %{
             relative_path: relative_path,
             filename: filename,
             ext: ext,
             kind: :not_found,
             content: nil,
             rendered_html: nil,
             file_size: nil,
             modified_at: nil,
             raw_url: nil
           }}
      end
    else
      {:error, :unauthorized}
    end
  end

  defp load_content(full_path, @markdown_extension) do
    case File.read(full_path) do
      {:ok, content} -> {:markdown, content, render_html(content, ".md")}
      {:error, _} -> {:error, nil, nil}
    end
  end

  defp load_content(full_path, ext) when ext in @text_extensions do
    case File.read(full_path) do
      {:ok, content} -> {:text, content, nil}
      {:error, _} -> {:error, nil, nil}
    end
  end

  defp load_content(_full_path, ext) when ext in @image_extensions, do: {:image, nil, nil}
  defp load_content(_full_path, @pdf_extension), do: {:pdf, nil, nil}

  defp load_content(full_path, @docx_extension) do
    md_path = tmp_md_path(full_path, @docx_extension)

    result =
      case DocxToMd.run(full_path, md_path) do
        {:ok, _} -> File.read(md_path)
        error -> error
      end

    _ = File.rm(md_path)

    converted_or_binary(result)
  end

  defp load_content(full_path, ext) when ext in @xlsx_extensions do
    md_path = tmp_md_path(full_path, ext)

    result =
      case XlsxToMd.run(full_path, md_path) do
        {:ok, _} -> File.read(md_path)
        error -> error
      end

    _ = File.rm(md_path)

    converted_or_binary(result)
  end

  defp load_content(_full_path, _ext), do: {:binary, nil, nil}

  # A conversion step that cannot parse its input copies the bytes through to the output and
  # still reports `:ok`, so a success tuple is not evidence that anything was converted.
  # Markdown is text by definition, so the output is checked rather than trusted: without
  # this a corrupt or mislabelled .docx renders its raw bytes through the markdown renderer.
  defp converted_or_binary({:ok, content}) do
    if text?(content) do
      {:markdown, content, render_html(content, ".md")}
    else
      {:binary, nil, nil}
    end
  end

  defp converted_or_binary(_result), do: {:binary, nil, nil}

  # Valid UTF-8 is necessary but not sufficient: a ZIP header (`PK\x03\x04\x00\x00`) is
  # entirely sub-128 bytes and passes `String.valid?/1`. C0 control characters are what
  # actually separate a document from its container — tab, newline and carriage return
  # excepted, since those are legitimate in markdown.
  defp text?(content) do
    String.valid?(content) and not Regex.match?(~r/[\x00-\x08\x0B\x0C\x0E-\x1F]/, content)
  end

  defp render_html(content, ".md") do
    Markdown.render(content)
  end

  defp render_html(_content, _ext), do: nil

  defp tmp_md_path(full_path, ext) do
    basename = Path.basename(full_path, ext)
    unique = System.unique_integer([:positive])
    Path.join(System.tmp_dir!(), "#{basename}-#{unique}.md")
  end
end
