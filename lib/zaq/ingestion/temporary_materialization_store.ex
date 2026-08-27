defmodule Zaq.Ingestion.TemporaryMaterializationStore do
  @moduledoc """
  Writes job-scoped temporary files for external data-source record materialization.

  Python converters may create `.md` outputs next to these temporary files. The
  caller owns deleting the returned `root_path` after ingestion finishes.
  """

  alias Zaq.Ingestion.ExternalSource

  @spec write_markdown(Zaq.Contracts.Record.t(), String.t()) ::
          {:ok, %{absolute_path: String.t(), relative_path: String.t(), root_path: String.t()}}
          | {:error, term()}
  def write_markdown(record, content) when is_binary(content) do
    write(record, content, ".md")
  end

  @spec write_original(Zaq.Contracts.Record.t(), binary(), String.t()) ::
          {:ok, %{absolute_path: String.t(), relative_path: String.t(), root_path: String.t()}}
          | {:error, term()}
  def write_original(record, content, ext) when is_binary(content) do
    write(record, content, ext)
  end

  defp write(record, content, ext) do
    root_path = materialization_root()
    relative_path = filename(record, ext)
    absolute_path = Path.join(root_path, relative_path)

    with :ok <- File.mkdir_p(Path.dirname(absolute_path)),
         :ok <- File.write(absolute_path, content) do
      {:ok, %{absolute_path: absolute_path, relative_path: relative_path, root_path: root_path}}
    end
  end

  defp filename(record, ext) do
    base = record |> ExternalSource.file_id() |> :erlang.phash2() |> Integer.to_string(36)
    base <> ext
  end

  defp materialization_root do
    Path.join(base_path(), System.unique_integer([:positive]) |> Integer.to_string())
  end

  defp base_path do
    Path.join(System.tmp_dir!(), "zaq_temporary_materializations")
  end
end
