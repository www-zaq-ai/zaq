defmodule Zaq.Ingestion.ExternalSidecarStore do
  @moduledoc """
  Writes job-scoped temporary materialization files for external data-source records.
  """

  alias Zaq.Ingestion.ExternalSource

  @spec write_markdown(Zaq.Contracts.Record.t(), String.t()) ::
          {:ok, %{absolute_path: String.t(), relative_path: String.t()}} | {:error, term()}
  def write_markdown(record, content) when is_binary(content) do
    write(record, content, ".md")
  end

  @spec write_original(Zaq.Contracts.Record.t(), binary(), String.t()) ::
          {:ok, %{absolute_path: String.t(), relative_path: String.t()}} | {:error, term()}
  def write_original(record, content, ext) when is_binary(content) do
    write(record, content, ext)
  end

  def delete(relative_path) when is_binary(relative_path) do
    relative_path
    |> absolute_path()
    |> File.rm()
    |> case do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
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
    Path.join(System.tmp_dir!(), "zaq_external_sidecars")
  end

  defp absolute_path(relative_path), do: Path.join(base_path(), relative_path)
end
