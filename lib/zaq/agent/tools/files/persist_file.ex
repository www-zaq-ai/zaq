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
      url: [type: :string, required: true, doc: "Download URL"],
      size: [type: :integer, required: true, doc: "File size in bytes"]
    ]

  alias Zaq.Event
  alias Zaq.NodeRouter

  @impl Jido.Action
  def run(params, _context) do
    case params[:provider] do
      "google_drive" ->
        gdrive_params = %{
          "name" => params.filename,
          "content" => params.data,
          "mime_type" => params.mime_type
        }

        event =
          %{provider: "google_drive", params: gdrive_params}
          |> Event.new(:channels, opts: [action: :data_source_create_file])
          |> NodeRouter.dispatch()

        case Map.fetch!(event, :response) do
          {:ok, %{status: "created", record: record}} ->
            {:ok,
             %{
               name: record.name,
               path: record.id,
               mime_type: record.mime_type,
               url: record.url,
               size: record.size
             }}

          {:error, _} = err ->
            err
        end

      _ ->
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
end
