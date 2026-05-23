defmodule Zaq.Contracts.Sheets.SheetMutationResult do
  @moduledoc "Normalized result for sheet write operations."

  @derive {
    Jason.Encoder,
    only: [
      :spreadsheet_id,
      :updated_range,
      :updated_rows,
      :updated_columns,
      :updated_cells,
      :revision,
      :metadata
    ]
  }

  defstruct [
    :spreadsheet_id,
    :updated_range,
    :updated_rows,
    :updated_columns,
    :updated_cells,
    :revision,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          spreadsheet_id: String.t() | nil,
          updated_range: String.t() | nil,
          updated_rows: non_neg_integer() | nil,
          updated_columns: non_neg_integer() | nil,
          updated_cells: non_neg_integer() | nil,
          revision: String.t() | nil,
          metadata: map()
        }
end
