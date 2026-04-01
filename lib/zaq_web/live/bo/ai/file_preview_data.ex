defmodule ZaqWeb.Live.BO.AI.FilePreviewData do
  @moduledoc """
  Shared preview payload builder used by BO file preview surfaces.
  """

  alias Zaq.Ingestion
  alias Zaq.Ingestion.FileExplorer
  alias Zaq.Ingestion.Python.Steps.{DocxToMd, XlsxToMd}

  @markdown_extension ".md"
  @text_extensions ~w(.txt)
  @image_extensions ~w(.png .jpg .jpeg .gif .webp)
  @pdf_extension ".pdf"
  @docx_extension ".docx"
  @xlsx_extensions ~w(.xlsx .xls .csv)

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
    md_path = Path.join(System.tmp_dir!(), Path.basename(full_path, ".docx") <> ".md")

    with {:ok, _} <- DocxToMd.run(full_path, md_path),
         {:ok, content} <- File.read(md_path) do
      File.rm(md_path)
      {:markdown, content, render_html(content, ".md")}
    else
      _ -> {:binary, nil, nil}
    end
  end

  defp load_content(full_path, ext) when ext in @xlsx_extensions do
    basename = Path.basename(full_path, ext)
    md_path = Path.join(System.tmp_dir!(), basename <> ".md")

    with {:ok, _} <- XlsxToMd.run(full_path, md_path),
         {:ok, content} <- File.read(md_path) do
      File.rm(md_path)
      {:markdown, content, render_html(content, ".md")}
    else
      _ -> {:binary, nil, nil}
    end
  end

  defp load_content(_full_path, _ext), do: {:binary, nil, nil}

  defp render_html(content, ".md") do
    case Earmark.as_html(content, escape: false, breaks: true) do
      {:ok, html, _} ->
        html

      {:error, _, _} ->
        escaped = content |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
        "<pre>#{escaped}</pre>"
    end
  end

  defp render_html(_content, _ext), do: nil
end
