defmodule Zaq.Ingestion.ExternalSidecarStore do
  @moduledoc """
  Stores ZAQ-owned markdown sidecars for external data-source records.
  """

  alias Zaq.Ingestion.{ExternalSource, FileExplorer}

  @spec write_markdown(Zaq.Contracts.Record.t(), String.t()) ::
          {:ok, %{absolute_path: String.t(), relative_path: String.t()}} | {:error, term()}
  def write_markdown(record, content) when is_binary(content) do
    relative_path = ExternalSource.sidecar_relative_path(record, ".md")
    write(relative_path, content)
  end

  @spec write_original(Zaq.Contracts.Record.t(), binary(), String.t()) ::
          {:ok, %{absolute_path: String.t(), relative_path: String.t()}} | {:error, term()}
  def write_original(record, content, ext) when is_binary(content) do
    relative_path = ExternalSource.sidecar_relative_path(record, ext)
    write(relative_path, content)
  end

  defp write(relative_path, content) do
    with {:ok, absolute_path} <- FileExplorer.resolve_path(relative_path),
         :ok <- File.mkdir_p(Path.dirname(absolute_path)),
         :ok <- File.write(absolute_path, content) do
      {:ok, %{absolute_path: absolute_path, relative_path: relative_path}}
    end
  end
end
