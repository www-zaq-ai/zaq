defmodule Zaq.Agent.Tools.Files.PersistFile do
  @moduledoc "Persist file tool — writes a staged file to disk"
  use Zaq.Engine.Workflows.Action,
    name: "persist_file",
    description:
      "Persist a file to disk. Provide the filename, content as plain text, and optionally a directory path. " <>
        "The file is saved as markdown. Reference it in your response with @path so the user can click to preview.",
    schema: [
      filename: [type: :string, required: true, doc: "Filename (e.g. report.pdf, notes.txt)"],
      mime_type: [type: :string, required: false, doc: "MIME type (e.g. text/markdown)"],
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
      size: [type: :integer, required: true, doc: "File size in bytes"]
    ]

  alias Zaq.Event
  alias Zaq.NodeRouter

  @impl Jido.Action
  def run(params, _context) do
    encoded_params =
      params
      |> Map.put(:content, Base.encode64(params.data))
      |> Map.drop([:data])

    event =
      encoded_params
      |> Event.new(:channels, opts: [action: :disk_persist_file])
      |> NodeRouter.dispatch()

    Map.fetch!(event, :response)
  end
end
