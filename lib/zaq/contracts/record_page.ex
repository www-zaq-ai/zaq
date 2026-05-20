defmodule Zaq.Contracts.RecordPage do
  @moduledoc "Canonical multi-record page wrapper with pagination metadata."

  alias Zaq.Contracts.Record

  @derive {Jason.Encoder, only: [:resource_type, :records, :pagination, :stats]}

  @enforce_keys [:resource_type, :records]
  defstruct [
    :resource_type,
    records: [],
    pagination: %{
      cursor: nil,
      has_more?: false,
      page_size: nil,
      pages_loaded: nil,
      truncated?: false
    },
    stats: %{scanned: nil, returned: nil},
    filters: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          resource_type: atom(),
          records: [Record.t()],
          pagination: map(),
          stats: map(),
          filters: map(),
          metadata: map()
        }
end
