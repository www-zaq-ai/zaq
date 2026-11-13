defmodule Zaq.Ingestion.PreparationOutcome do
  @moduledoc """
  Pure classification of empty document-preparation results.

  Callers classify **only when indexed payloads are empty**. Non-empty
  payloads are always success — optional image-to-text skip must not fail
  text-bearing PDFs.

  Provenance is Elixir-observed only (`:skipped` / `:completed` from the
  PDF pipeline callback). Missing outcome (non-PDF / alternate path) maps
  to `:no_searchable_content`.
  """

  @type image_to_text :: :skipped | :completed | nil
  @type input :: %{
          required(:payloads_empty?) => boolean(),
          optional(:image_to_text) => image_to_text()
        }
  @type reason :: :image_extraction_skipped | :no_searchable_content

  @doc """
  Classifies an empty-or-not preparation result.

  Returns `:ok` when payloads are non-empty. When empty, returns a stable
  atom error — never credentials or provider payloads.
  """
  @spec classify(input()) :: :ok | {:error, reason()}
  def classify(%{payloads_empty?: false}), do: :ok

  def classify(%{payloads_empty?: true, image_to_text: :skipped}),
    do: {:error, :image_extraction_skipped}

  def classify(%{payloads_empty?: true}), do: {:error, :no_searchable_content}
end
