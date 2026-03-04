defmodule Zaq.DocumentProcessor.Behaviour do
  @moduledoc """
  Behaviour module defining the contract for document processing implementations.
  This allows for different processing strategies (e.g., local, external service) to be used interchangeably in the ingestion pipeline.
  """
  @callback process_single_file(String.t()) :: {:ok, map()} | {:error, any()}
end
