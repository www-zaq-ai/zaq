defmodule Zaq.Ingestion.TemporaryMaterializationStore do
  @moduledoc """
  Writes private temporary files for downloaded documents.

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

  @doc "Stages content for the callback and removes the entire scratch directory afterward."
  @spec with_original(Zaq.Contracts.Record.t(), binary(), String.t(), (map() -> term())) :: term()
  def with_original(record, content, ext, convert) when is_function(convert, 1) do
    with {:ok, stored} <- write_original(record, content, ext) do
      try do
        convert.(stored)
      after
        File.rm_rf(stored.root_path)
      end
    end
  end

  defp write(record, content, ext) do
    root_path = materialization_root()
    relative_path = filename(record, ext)
    absolute_path = Path.join(root_path, relative_path)

    with :ok <- File.mkdir_p(base_path()),
         :ok <- File.mkdir(root_path) do
      case write_private(root_path, absolute_path, content) do
        :ok ->
          {:ok,
           %{absolute_path: absolute_path, relative_path: relative_path, root_path: root_path}}

        {:error, _} = error ->
          File.rm_rf(root_path)
          error
      end
    end
  end

  defp write_private(root_path, absolute_path, content) do
    with :ok <- File.chmod(root_path, 0o700), do: File.write(absolute_path, content, [:exclusive])
  end

  defp filename(record, ext) do
    base = record |> ExternalSource.file_id() |> :erlang.phash2() |> Integer.to_string(36)
    base <> ext
  end

  defp materialization_root do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    Path.join(base_path(), suffix)
  end

  defp base_path do
    Path.join(System.tmp_dir!(), "zaq_temporary_materializations")
  end
end
