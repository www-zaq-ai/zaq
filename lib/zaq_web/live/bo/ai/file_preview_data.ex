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

    case result do
      {:ok, content} ->
        {:markdown, content, render_html(content, ".md")}

      _ ->
        {:binary, nil, nil}
    end
  end

  defp load_content(full_path, ext) when ext in @xlsx_extensions do
    md_path = tmp_md_path(full_path, ext)

    result =
      case XlsxToMd.run(full_path, md_path) do
        {:ok, _} -> File.read(md_path)
        error -> error
      end

    _ = File.rm(md_path)

    case result do
      {:ok, content} ->
        {:markdown, content, render_html(content, ".md")}

      _ ->
        {:binary, nil, nil}
    end
  end

  defp load_content(_full_path, _ext), do: {:binary, nil, nil}

  defp render_html(content, ".md") do
    case Earmark.as_html(content, escape: true, breaks: true) do
      {:ok, html, _} ->
        sanitize_html(html)

      {:error, _, _} ->
        escaped = content |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
        "<pre>#{escaped}</pre>"
    end
  end

  defp render_html(_content, _ext), do: nil

  defp sanitize_html(html) do
    html
    |> then(&Regex.replace(~r/<script\b[^>]*>[\s\S]*?<\/script>/iu, &1, ""))
    |> then(&Regex.replace(~r/\s+on\w+=("[^"]*"|'[^']*'|[^\s>]+)/iu, &1, ""))
    |> then(&Regex.replace(~r/\s+href=("|')\s*javascript:[^"']*("|')/iu, &1, ~s( href="#")))
    |> then(&Regex.replace(~r/\s+src=("|')\s*javascript:[^"']*("|')/iu, &1, ""))
  end

  defp tmp_md_path(full_path, ext) do
    basename = Path.basename(full_path, ext)
    unique = System.unique_integer([:positive])
    Path.join(System.tmp_dir!(), "#{basename}-#{unique}.md")
  end
end
