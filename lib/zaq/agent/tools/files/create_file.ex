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
    md_name = Path.rootname(params.filename) <> ".md"

    rel_path =
      if params[:path] do
        Path.join(params[:path], md_name)
      else
        "generated/#{md_name}"
      end

    {:ok,
     %{
       name: md_name,
       path: rel_path,
       mime_type: "text/markdown",
       url: "/bo/files/#{rel_path}",
       size: byte_size(params.data),
       data: params.data
     }}
  end
end
