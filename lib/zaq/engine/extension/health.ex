defmodule Zaq.Engine.Extension.Health do
  @moduledoc """
  Safe gateway connectivity snapshot shared with BO. It carries no license or TLS material.
  """

  @enforce_keys [:status]
  defstruct [:status, :reason, :checked_at]

  @type t :: %__MODULE__{
          status: :unconfigured | :checking | :healthy | :unreachable | :error,
          reason: atom() | nil,
          checked_at: DateTime.t() | nil
        }
end
