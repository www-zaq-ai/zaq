defmodule Zaq.Contracts.Sheets.SpreadsheetRef do
  @moduledoc "Provider-agnostic spreadsheet identity and metadata."

  @derive {Jason.Encoder, only: [:id, :provider, :title, :revision]}

  @enforce_keys [:id]
  defstruct [:id, :provider, :title, :revision]

  @type t :: %__MODULE__{
          id: String.t(),
          provider: String.t() | nil,
          title: String.t() | nil,
          revision: String.t() | nil
        }
end
