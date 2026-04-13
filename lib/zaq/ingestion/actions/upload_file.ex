defmodule Zaq.Ingestion.Actions.UploadFile do
  @moduledoc """
  Validates the file exists on the configured volume and resolves its absolute path.

  This is the entry point for every ingestion pipeline run. It mirrors the path
  resolution logic in `IngestWorker` so the rest of the pipeline always receives
  a fully-resolved, verified path.
  """

  use Jido.Action,
    name: "upload_file",
    description: "Validates the file exists on the volume and resolves its absolute path.",
    schema: [
      file_path: [
        type: :string,
        required: true,
        doc: "Relative or absolute path to the file"
      ],
      volume_name: [
        type: :any,
        default: nil,
        doc: "Optional volume name for multi-volume setups"
      ]
    ]

  alias Zaq.Ingestion.FileExplorer

  require Logger

  @impl true
  def run(%{file_path: file_path, volume_name: volume_name}, _context) do
    resolved = resolve_path(file_path, volume_name)

    if File.exists?(resolved) do
      Logger.info("[UploadFile] File validated: #{resolved}")
      {:ok, %{file_path: resolved}}
    else
      {:error, "File not found: #{resolved}"}
    end
  end

  defp resolve_path(path, nil) do
    if Path.type(path) == :absolute do
      path
    else
      case FileExplorer.resolve_path(path) do
        {:ok, full_path} -> full_path
        _ -> path
      end
    end
  end

  defp resolve_path(path, volume_name) do
    case FileExplorer.resolve_path(volume_name, path) do
      {:ok, full_path} -> full_path
      _ -> path
    end
  end
end
