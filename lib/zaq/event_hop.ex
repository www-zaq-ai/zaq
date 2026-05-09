defmodule Zaq.EventHop do
  @moduledoc """
  Describes one routing hop for a `Zaq.Event`.

  - `destination`: target service role (`:agent`, `:channels`, `:engine`, ...)
  - `type`: dispatch mode (`:sync` or `:async`)
  - `timestamp`: hop creation time used for traceability
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
