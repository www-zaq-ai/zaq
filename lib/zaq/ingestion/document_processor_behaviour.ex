defmodule Zaq.DocumentProcessorBehaviour do
  @moduledoc """
  Behaviour module defining the contract for document processing implementations.
  This allows for different processing strategies (e.g., local, external service) to be used interchangeably in the ingestion pipeline.
  """
  @callback process_single_file(String.t()) :: {:ok, map()} | {:error, any()}
  @callback read_as_markdown(String.t()) :: {:ok, String.t()} | {:error, any()}
  @callback prepare_file_chunks(String.t()) :: {:ok, map(), list()} | {:error, any()}
  @callback store_chunk_with_metadata(map(), any(), non_neg_integer()) ::
              {:ok, any()} | {:error, any()}
end
