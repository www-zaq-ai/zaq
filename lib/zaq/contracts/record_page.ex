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

  @doc """
  A complete page wrapping `records`.

  Pagination and stats are derived from the list rather than asked for, so a caller that has
  all the records in hand cannot describe them inconsistently.
  """
  @spec new(atom(), [Record.t()]) :: t()
  def new(resource_type, records) when is_atom(resource_type) and is_list(records) do
    count = length(records)

    %__MODULE__{
      resource_type: resource_type,
      records: records,
      pagination: %{
        cursor: nil,
        has_more?: false,
        page_size: count,
        pages_loaded: 1,
        truncated?: false
      },
      stats: %{scanned: count, returned: count}
    }
  end

  @doc "An empty page. Not an error — a source with nothing in it is an ordinary state."
  @spec empty(atom()) :: t()
  def empty(resource_type), do: new(resource_type, [])

  @doc """
  Keeps at most `max` records, recording that the rest exist.

  `stats.scanned` keeps the real total while `stats.returned` and `pagination.page_size` drop
  to what survived, so a consumer can always tell "there are 137, here are 100" from "there
  are 100". Under the cap the page is returned untouched — including its existing
  `truncated?`, which a caller further upstream may already have set.
  """
  @spec truncate(t(), pos_integer()) :: t()
  def truncate(%__MODULE__{records: records} = page, max) when is_integer(max) and max > 0 do
    if length(records) > max do
      kept = Enum.take(records, max)

      %__MODULE__{
        page
        | records: kept,
          pagination: %{page.pagination | page_size: length(kept), truncated?: true},
          stats: %{page.stats | returned: length(kept)}
      }
    else
      page
    end
  end
end
