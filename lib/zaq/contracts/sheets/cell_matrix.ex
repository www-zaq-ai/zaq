defmodule Zaq.Contracts.Sheets.CellMatrix do
  @moduledoc "Canonical matrix payload for sheet value operations."

  @derive {Jason.Encoder, only: [:values, :value_input_option]}

  @enforce_keys [:values]
  defstruct values: [], value_input_option: "USER_ENTERED"

  @type scalar :: String.t() | number() | boolean() | nil
  @type t :: %__MODULE__{values: [[scalar()]], value_input_option: String.t()}
end
