defmodule Zaq.Event do
  @moduledoc """
  Canonical cross-node envelope used by `Zaq.NodeRouter.dispatch/1`.

  Payload structs (for example `%Zaq.Engine.Messages.Incoming{}` and
  `%Zaq.Engine.Messages.Outgoing{}`) travel inside this envelope as
  `request` and `response`.
  """

  alias Zaq.EventHop

  @enforce_keys [:request, :next_hop]
  defstruct [
    :request,
    assigns: %{},
    response: nil,
    hops: [],
    next_hop: nil,
    trace_id: nil,
    opts: [],
    version: 1,
    actor: nil
  ]

  @type t :: %__MODULE__{
          request: term(),
          assigns: map(),
          response: term() | nil,
          hops: [EventHop.t()],
          next_hop: EventHop.t(),
          trace_id: String.t() | nil,
          opts: keyword(),
          version: integer(),
          actor: term() | nil
        }

  @spec new(term(), atom(), keyword()) :: t()
  def new(request, destination, opts \\ []) when is_atom(destination) and is_list(opts) do
    hop_type = Keyword.get(opts, :type, :sync)
    timestamp = Keyword.get(opts, :timestamp, DateTime.utc_now())
    trace_id = Keyword.get(opts, :trace_id, Ecto.UUID.generate())
    actor = Keyword.get(opts, :actor)
    event_opts = Keyword.get(opts, :opts, [])
    version = Keyword.get(opts, :version, 1)

    %__MODULE__{
      request: request,
      next_hop: EventHop.new(destination, hop_type, timestamp),
      trace_id: trace_id,
      opts: event_opts,
      version: version,
      actor: actor
    }
  end
end
