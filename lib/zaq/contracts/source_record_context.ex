defmodule Zaq.Contracts.SourceRecordContext do
  @moduledoc """
  Internal authorized source metadata and nearest-first folder ancestry.

  References contain only canonical provider/config/record identity. Every ancestor
  is readable by the trusted actor; permission evidence belongs to the source
  record. This contract carries no content materialization or persistence command.
  """

  alias Zaq.Contracts.Record

  @enforce_keys [:reference, :record, :permissions, :ancestors]
  defstruct [:reference, :record, :permissions, :ancestors]

  @type source_reference :: %{provider: String.t(), config_id: String.t(), record_id: String.t()}
  @type t :: %__MODULE__{
          reference: source_reference(),
          record: Record.t(),
          permissions: [Record.t()],
          ancestors: [%{reference: source_reference(), record: Record.t(), depth: pos_integer()}]
        }
end
