defmodule Zaq.Ingestion.FileExplorer.Entry do
  @moduledoc """
  One file or folder on a mounted ingestion volume, as read from disk.

  `Zaq.Ingestion.FileExplorer` builds these from `File.stat/2`, so it fills only filesystem
  state. `id`, `source`, and `document_id` need a database lookup and are filled by
  `Zaq.Ingestion.VolumeEntries.resolve/1` — on an entry straight out of `FileExplorer` they
  are `nil`.

  `type` is `:directory`, not `:folder`. Callers pattern-match `%{type: :directory}` to
  branch on it; `Zaq.Contracts.Record`'s `:folder` naming is applied by the data-source
  bridge when it maps an entry into a record.

  `relative_path` out of `FileExplorer` is as-given by the caller, joined with the entry
  name — it is not passed through `Zaq.Ingestion.SourcePath.normalize_relative/1`, which
  aliases `FileExplorer` and cannot be called from here. `resolve/1` normalizes it.
  """

  @enforce_keys [:name, :type]
  defstruct [
    :id,
    :name,
    :type,
    :size,
    :modified_at,
    :volume,
    :relative_path,
    :source,
    :document_id
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t(),
          type: :file | :directory,
          size: non_neg_integer() | nil,
          modified_at: DateTime.t() | nil,
          volume: String.t() | nil,
          relative_path: String.t() | nil,
          source: String.t() | nil,
          document_id: integer() | nil
        }
end
