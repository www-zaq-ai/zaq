defmodule Zaq.Records.Materializer do
  @moduledoc """
  Moves a record's bytes from whichever node owns them to the caller.

  This is the entry point every caller uses and the only one they need. A caller holds a
  record and says `materialize(record)`; it never names a node, an action atom, a volume or a
  path. **The record routes itself** — `materialization.role` says which node owns the bytes,
  and that is read from the record, never from a default or an option.

  That property is what makes this a backbone rather than a skills helper: a skill resource on
  an ingestion volume and an image hosted by a chat adapter travel identical calling code, and
  a caller written today keeps working when the bytes move somewhere new.

  ## One verb, for now

  `materialize/2` — **pull**. Fills `content` from wherever the descriptor points.

  The descriptor is deliberately direction-agnostic (see `Zaq.Contracts.Materialization`), so
  a `persist/2` push verb fits without reshaping anything here. It is not in this module yet
  because nothing writes: the skills surface reads its bundle and never adds to it.

  ## What a caller may and may not say

  `opts` may narrow `:as` and `:max_bytes` — statements about what *this* caller can accept.
  It may not touch `:role`, `:kind` or `:params`; those come from whoever minted the
  record, which is the role that owns the bytes. A caller able to rewrite `params` could read
  or write anywhere its role can reach, which is the whole class of bug the descriptor exists
  to prevent, so the narrowing is enforced here rather than documented and hoped for.

  ## The transport ceiling

  The `:transport_max_bytes` ceiling in `Zaq.Records.Limits` applies regardless of what a
  caller asked for. It is pushed down into the dispatched descriptor, so the reader on the far
  side refuses before it reads — far better than shipping a payload across a node boundary in
  order to reject it — with a check on the response as a backstop for a reader that ignores
  the cap.

  ## Failures

  A downed node, a call timeout and a reader error all read the same to a caller:
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
  # that at the data level, so no amount of extra keys here can reach role, kind or params.
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

  # A backstop, not the primary guard: `narrow/3` already pushed the ceiling down so the
  # reader refuses before reading. This catches one that did not honour it.
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
