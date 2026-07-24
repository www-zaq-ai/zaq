defmodule Zaq.Agent.Tools.Files.PersistFile do
  @moduledoc "Persist file tool — writes a staged file to disk"
  use Zaq.Engine.Workflows.Action,
    name: "persist_file",
    description:
      "Persist a file to disk or a datasource provider. Provide the filename, content as plain text, " <>
        "and optionally a directory path. Use provider: \"google_drive\" to save to Google Drive instead of disk. " <>
        "Reference it in your response with @path so the user can click to preview.",
    schema: [
      filename: [type: :string, required: true, doc: "Filename (e.g. report.pdf, notes.txt)"],
      mime_type: [type: :string, required: false, doc: "MIME type (e.g. text/markdown)"],
      data: [type: :string, required: true, doc: "File content as plain text"],
      provider: [
        type: :string,
        required: false,
        doc: "Storage backend — 'disk' or 'google_drive'"
      ],
      path: [
        type: :string,
        required: false,
        doc: "Optional directory to write into (e.g. archives)"
      ]
    ],
    output_schema: [
      name: [type: :string, required: true, doc: "Saved filename"],
      path: [type: :string, required: true, doc: "Relative path or provider file ID"],
      mime_type: [type: :string, required: true, doc: "MIME type"],
      size: [type: :integer, required: true, doc: "File size in bytes"]
    ]

  alias Zaq.Event
  alias Zaq.NodeRouter

  @impl Jido.Action
  def run(params, context) do
    node_router = Map.get(context, :node_router, NodeRouter)

    event =
      params
      |> Event.new(:channels, opts: [action: :persist_file])
      |> node_router.dispatch()

    Map.fetch!(event, :response)
  end
end
