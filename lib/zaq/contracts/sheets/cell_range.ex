defmodule Zaq.Contracts.Sheets.CellRange do
  @moduledoc "Canonical range representation for sheet values operations."

  @derive {Jason.Encoder, only: [:a1, :major_dimension]}

  @enforce_keys [:a1]
  defstruct [:a1, major_dimension: "ROWS"]

  @type t :: %__MODULE__{a1: String.t(), major_dimension: String.t()}
end
