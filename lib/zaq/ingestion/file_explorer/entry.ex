defmodule Zaq.Ingestion.FileExplorer.Entry do
  @moduledoc """
  One file or folder on a mounted ingestion volume, as read from disk.

  `Zaq.Ingestion.FileExplorer` builds these from `File.stat/2` and fills everything but
  `document_id`. `id` is the entry's `source` — volume plus normalized relative path — so a
  file is named without consulting the `documents` table and a file that was never ingested
  is addressable exactly like one that was.

  `document_id` is the one field a database answers: it says whether this source has been
  ingested, and is `nil` on an entry straight out of `FileExplorer`.

  `type` is `:directory`, not `:folder`. Callers pattern-match `%{type: :directory}` to
  branch on it; `Zaq.Contracts.Record`'s `:folder` naming is applied by the data-source
  bridge when it maps an entry into a record.

  `bound` is the one exception to "as read from disk": volume roots are listed whether or not
  their path is there, so only they answer it. It is `nil` on every other entry.
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
    :document_id,
    :bound
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
          document_id: integer() | nil,
          bound: boolean() | nil
        }
end
