defmodule Zaq.Agent.Tools.Files.CreateFile do
  @moduledoc "Create file tool — stages a file in-memory without writing to disk"
  use Zaq.Engine.Workflows.Action,
    name: "create_file",
    description:
      "Stage a file in memory with filename, content, and optional directory path. " <>
        "Returns file metadata plus raw content so you can reference it with @path, " <>
        "but does NOT write to disk. Call persist_file with the returned data to save it.",
    schema: [
      filename: [type: :string, required: true, doc: "Filename (e.g. report.pdf, notes.txt)"],
      mime_type: [type: :string, required: true, doc: "MIME type (e.g. text/markdown)"],
      data: [type: :string, required: true, doc: "File content as plain text"],
      path: [
        type: :string,
        required: false,
        doc: "Optional directory to write into (e.g. archives)"
      ]
    ],
    output_schema: [
      name: [type: :string, required: true, doc: "Saved filename (.md extension)"],
      path: [type: :string, required: true, doc: "Relative path from base directory"],
      mime_type: [type: :string, required: true, doc: "MIME type"],
      url: [type: :string, required: true, doc: "Download URL"],
      size: [type: :integer, required: true, doc: "File size in bytes"],
      data: [type: :string, required: true, doc: "Raw file content (plain text)"]
    ]

  @impl Jido.Action
  def run(params, _context) do
    ext = mime_to_ext(params.mime_type)
    out_name = Path.rootname(params.filename) <> ext
    out_mime = ext_to_mime(ext)

    rel_path =
      if params[:path] do
        Path.join(params[:path], out_name)
      else
        "generated/#{out_name}"
      end

    {:ok,
     %{
       name: out_name,
       path: rel_path,
       mime_type: out_mime,
       url: "/bo/files/#{rel_path}",
       size: byte_size(params.data),
       data: params.data
     }}
  end

  defp mime_to_ext("text/plain"), do: ".txt"
  defp mime_to_ext(_), do: ".md"

  defp ext_to_mime(".txt"), do: "text/plain"
  defp ext_to_mime(_), do: "text/markdown"
end
