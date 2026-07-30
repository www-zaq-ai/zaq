defmodule Zaq.Records.Materializer do
  @moduledoc """
  Moves a record's bytes, in either direction, to or from whichever node owns them.

  This is the entry point every caller uses and the only one they need. A caller holds a
  record and says `materialize(record)` or `persist(record)`; it never names a node, an action
  atom, a volume or a path. **The record routes itself** — `materialization.role` says which
  node owns the bytes, and that is read from the record, never from a default or an option.

  That property is what makes this a backbone rather than a skills helper: a skill resource on
  an ingestion volume and an image hosted by a chat adapter travel identical calling code, and
  a caller written today keeps working when the bytes move somewhere new.

  ## Two verbs

    * `materialize/2` — **pull**. Fills `content` from wherever the descriptor points.
    * `persist/2` — **push**. Writes `content` to where the descriptor points and returns the
      handle the owning role minted, with `content` dropped. That handle is an ordinary source
      descriptor: the output of a write is the input of a read.

  ## What a caller may and may not say

  `opts` may narrow `:as` and `:max_bytes` — statements about what *this* caller can accept.
  It may not touch `:role`, `:strategy` or `:params`; those come from whoever minted the
  record, which is the role that owns the bytes. A caller able to rewrite `params` could read
  or write anywhere its role can reach, which is the whole class of bug the descriptor exists
  to prevent, so the narrowing is enforced here rather than documented and hoped for.

  ## The transport ceiling

  The `:transport_max_bytes` ceiling in `Zaq.Records.Limits` applies in both directions
  regardless of what a caller asked for. On the way out it is checked **before** dispatch, against the raw bytes.
  On the way in it is pushed down into the dispatched descriptor, so the strategy on the far
  side refuses before it reads — far better than shipping a payload across a node boundary in
  order to reject it — with a check on the response as a backstop for strategies that ignore
  the cap.

  ## Failures

  A downed node, a call timeout and a strategy error all read the same to a caller:
  `{:error, reason}`. Nothing here raises, because every caller is a tool call or a LiveView
  that has to degrade rather than crash.
  """

  alias Zaq.Contracts.Materialization
  alias Zaq.Contracts.Record
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.Records.Content
  alias Zaq.Records.Limits

  @type opts :: keyword()

  @doc """
  Fills the record's content from wherever its descriptor points.

  Returns `{:error, :not_materializable}` for a record with no descriptor — without
  dispatching, because there is no role to guess.
  """
  @spec materialize(Record.t(), opts()) :: {:ok, Record.t()} | {:error, term()}
  def materialize(record, opts \\ [])

  def materialize(%Record{materialization: %Materialization{}} = record, opts) do
    ceiling = ceiling(opts)

    record
    |> narrow(opts, ceiling)
    |> dispatch(:materialize_record, opts)
    |> verify_incoming_size(ceiling)
  end

  def materialize(%Record{}, _opts), do: {:error, :not_materializable}

  @doc """
  Writes the record's content to where its descriptor points.

  Returns the handle the owning role minted — the same record with the destination resolved
  and `content` dropped. Oversize payloads are refused **before** dispatch: there is no point
  copying bytes across a node boundary to have them rejected there.
  """
  @spec persist(Record.t(), opts()) :: {:ok, Record.t()} | {:error, term()}
  def persist(record, opts \\ [])

  def persist(%Record{materialization: %Materialization{}} = record, opts) do
    ceiling = ceiling(opts)

    with :ok <- verify_outgoing_size(record, ceiling) do
      record
      |> narrow(opts, ceiling)
      |> dispatch(:persist_record, opts)
    end
  end

  def persist(%Record{}, _opts), do: {:error, :not_materializable}

  # --- Dispatch ---

  # A raise or an exit (a downed node, a call timeout) must read the same as a returned
  # error — the caller decides what to do about it either way.
  defp dispatch(%Record{materialization: %Materialization{role: role}} = record, action, opts) do
    node_router = Keyword.get(opts, :node_router, NodeRouter)

    %{record: record}
    |> Event.new(role, opts: [action: action])
    |> node_router.dispatch()
    |> Map.get(:response)
    |> case do
      {:ok, %Record{} = materialized} -> {:ok, materialized}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :unavailable}
    end
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # --- Acceptance ---

  # Only `:as` and `:max_bytes` are ever taken from opts. `Materialization.narrow/2` enforces
  # that at the data level, so no amount of extra keys here can reach role, strategy or params.
  defp narrow(%Record{materialization: materialization} = record, opts, ceiling) do
    narrowed =
      Materialization.narrow(materialization,
        as: Keyword.get(opts, :as, materialization.as),
        max_bytes: cap(Keyword.get(opts, :max_bytes, materialization.max_bytes), ceiling)
      )

    %Record{record | materialization: narrowed}
  end

  defp cap(nil, ceiling), do: ceiling
  defp cap(max_bytes, ceiling), do: min(max_bytes, ceiling)

  # --- Size ---

  defp ceiling(opts), do: Limits.get(:transport_max_bytes, Keyword.get(opts, :limits_opts, []))

  defp verify_outgoing_size(%Record{content: nil}, _ceiling), do: :ok

  defp verify_outgoing_size(%Record{} = record, ceiling) do
    case Content.raw_size(record) do
      {:ok, size} when size > ceiling -> {:error, {:too_large, size}}
      {:ok, _size} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # A backstop, not the primary guard: `narrow/3` already pushed the ceiling down so the
  # strategy refuses before reading. This catches one that did not honour it.
  defp verify_incoming_size({:ok, %Record{content: nil} = record}, _ceiling), do: {:ok, record}

  defp verify_incoming_size({:ok, %Record{} = record}, ceiling) do
    case Content.raw_size(record) do
      {:ok, size} when size > ceiling -> {:error, {:too_large, size}}
      {:ok, _size} -> {:ok, record}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_incoming_size({:error, reason}, _ceiling), do: {:error, reason}
end
