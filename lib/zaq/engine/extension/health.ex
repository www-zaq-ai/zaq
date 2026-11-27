defmodule Zaq.Engine.Extension.Health do
  @moduledoc """
  Safe gateway connectivity snapshot shared with BO. It carries no license or TLS material.
  """

  @enforce_keys [:status]
  defstruct [:status, :reason, :checked_at, :response_time_ms]

  @type t :: %__MODULE__{
          status: :unconfigured | :checking | :healthy | :unreachable | :error,
          reason: atom() | nil,
          checked_at: DateTime.t() | nil,
          response_time_ms: non_neg_integer() | nil
        }
end
