defmodule Zaq.Contracts.Sheets.SheetTabRef do
  @moduledoc "Provider-agnostic sheet tab identity and metadata."

  @derive {Jason.Encoder, only: [:sheet_id, :title, :index]}

  @enforce_keys [:sheet_id]
  defstruct [:sheet_id, :title, :index]

  @type t :: %__MODULE__{
          sheet_id: String.t(),
          title: String.t() | nil,
          index: non_neg_integer() | nil
        }
end
