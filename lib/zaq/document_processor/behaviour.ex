defmodule Zaq.DocumentProcessorBehaviour do
  @moduledoc """
  Behaviour module defining the contract for document processing implementations.
  This allows for different processing strategies (e.g., local, external service) to be used interchangeably in the ingestion pipeline.
  """
  @callback process_single_file(
              String.t(),
              role_id :: integer() | nil,
              shared_role_ids :: list()
            ) ::
              {:ok, map()} | {:error, any()}
end
