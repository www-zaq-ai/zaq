defmodule Zaq.Contracts.MaterializedRecord do
  @moduledoc """
  Result of a successfully downloaded channel attachment.

  """

  @enforce_keys [:id, :content]
  defstruct [
    :id,
    :content,
    :name,
    :mime_type,
    :size
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          content: binary() | nil,
          name: String.t() | nil,
          mime_type: String.t() | nil,
          size: non_neg_integer() | nil
        }

  def new(fields) do
    struct!(__MODULE__, fields)
  end
end
