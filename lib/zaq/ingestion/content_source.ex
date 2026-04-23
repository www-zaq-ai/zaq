defmodule Zaq.Ingestion.ContentSource do
  @moduledoc """
  Plain struct representing a filterable content source for the @ mention system.

  Not persisted — used as ephemeral filter state in the chat UI and pipeline.
  Travels across the NodeRouter boundary as serialized `source_prefix` strings;
  the struct itself is only used on the BO LiveView side.

  ## Connector prefix convention

  `Document.source` encodes the connector as its first path segment:

    * Filesystem volume `"documents"` → `"documents/hr/policy.md"`
    * SharePoint (future)             → `"sharepoint/sites/hr/policy.docx"`
    * Google Drive (future)           → `"gdrive/shared/reports/q4.pdf"`

  The first segment is the connector identifier used for grouping and display.
  """

  @enforce_keys [:connector, :source_prefix, :label, :type]

  defstruct [:connector, :source_prefix, :label, :type]

  @type t :: %__MODULE__{
          connector: String.t(),
          source_prefix: String.t(),
          label: String.t(),
          type: :connector | :folder | :file
        }

  @doc """
  Parses a raw `Document.source` string into a `%ContentSource{}`.
  Returns `nil` for blank or malformed input.

  ## Examples

      iex> ContentSource.from_source("documents/hr/policy.md")
      %ContentSource{connector: "documents", source_prefix: "documents/hr/policy.md",
                     label: "policy.md", type: :file}

      iex> ContentSource.from_source("sharepoint/sites/hr")
      %ContentSource{connector: "sharepoint", source_prefix: "sharepoint/sites/hr",
                     label: "hr", type: :folder}
  """
  @spec from_source(String.t()) :: t() | nil
  def from_source(source) when is_binary(source) and source != "" do
    parts = String.split(source, "/", trim: true)

    case parts do
      [] ->
        nil

      [connector] ->
        %__MODULE__{
          connector: connector,
          source_prefix: connector,
          label: connector,
          type: :connector
        }

      _ ->
        connector = List.first(parts)
        label = List.last(parts)
        type = if String.contains?(label, "."), do: :file, else: :folder

        %__MODULE__{
          connector: connector,
          source_prefix: source,
          label: label,
          type: type
        }
    end
  end

  def from_source(_), do: nil
end
