defmodule Zaq.Storage.FileExplorer.Entry do
  @moduledoc """
  One file or folder on a mounted storage volume, as read from disk.

  `id` is the entry's `source` — volume plus normalized relative path — so a file is named
  without consulting the `documents` table and a file that was never ingested is addressable
  exactly like one that was.

  `type` is `:directory`, not `:folder`. Callers pattern-match `%{type: :directory}` to
  branch on it; `Zaq.Contracts.Record`'s `:folder` naming is applied by the data-source
  bridge when it maps an entry into a record.
  """

  @enforce_keys [:name, :type]
  defstruct [
    :id,
    :parent_id,
    :name,
    :type,
    :size,
    :modified_at,
    :volume,
    :relative_path,
    :source
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          parent_id: String.t() | nil,
          name: String.t(),
          type: :file | :directory,
          size: non_neg_integer() | nil,
          modified_at: DateTime.t() | nil,
          volume: String.t() | nil,
          relative_path: String.t() | nil,
          source: String.t() | nil
        }
end
