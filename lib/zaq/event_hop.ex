defmodule Zaq.EventHop do
  @moduledoc """
  Describes one routing hop for a `Zaq.Event`.

  `destination` is the node role, `type` indicates sync vs async intent,
  and `timestamp` captures when the hop was created.
  """

  @enforce_keys [:destination, :type, :timestamp]
  defstruct [:destination, :type, :timestamp]

  @type hop_type :: :sync | :async

  @type t :: %__MODULE__{
          destination: atom(),
          type: hop_type(),
          timestamp: DateTime.t()
        }

  @spec new(atom(), hop_type(), DateTime.t()) :: t()
  def new(destination, type, %DateTime{} = timestamp)
      when is_atom(destination) and type in [:sync, :async] do
    %__MODULE__{destination: destination, type: type, timestamp: timestamp}
  end
end
