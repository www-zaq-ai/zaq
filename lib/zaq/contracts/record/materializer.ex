defmodule Zaq.Contracts.Record.Materializer do
  @moduledoc """
  Fetches the content of an unmaterialized `Zaq.Contracts.Record`.

  Records cross node boundaries carrying full metadata and `content: nil`; the bytes are
  pulled only when a service actually needs to consume them. `materialize/2` is that pull.

  ## Why this is not a function on `Zaq.Contracts.Record`

  `Record` is the canonical *payload* struct — pure data, held by every role. Giving it a
  function that calls `Zaq.NodeRouter` would make every node that merely holds a record
  compile against the router, and would put cross-node routing inside a contract. The
  struct stays data; the behaviour lives here.

  ## The carried event cannot be attacker-chosen

  `materializing_event` is a dispatchable event travelling inside a data payload. The field
  is excluded from `Record`'s `Jason.Encoder` `only:` list and from `to_map/1`, so it cannot
  survive a round trip through an LLM tool result or persisted workflow state — a record
  rebuilt from JSON always carries `materializing_event: nil` and is simply not
  materializable. Only in-process Elixir code can set one, and such code could call
  `Zaq.NodeRouter` directly anyway.

  ## Only `nil` means unmaterialized

  An empty file materializes to `""`, which is a legitimate result. Treating `""` as
  "still empty" would re-dispatch on every call and never converge, so the check is
  strictly `nil`. The event is cleared once spent, making `materialize/2` idempotent:
  materializing an already-materialized record is a no-op that dispatches nothing.

  ## A dispatch may answer with another unmaterialized record

  Where the bytes live is the *provider's* business, and the answer differs by provider:

    * an external provider (Google Drive via `Zaq.Channels.JidoConnectBridge`) holds the
      file itself, so its `download_document` answers with content in hand — one hop, done;
    * an internal provider fronts a role that is not the one being asked. `disk` is
      addressed through Channels but the file lives on an ingestion volume, so the honest
      answer is the record's metadata plus the event that fetches its bytes from Ingestion.

  The second case is not a failure — it is a *redirect*. A response carrying `content: nil`
  **and** a fresh `materializing_event` is followed: the returned event is dispatched in
  turn, until a hop produces content. A response with neither content nor a next event is
  still an error, since nothing about it can converge.

  `:max_hops` bounds the chain so a provider that keeps handing back an event — echoing the
  one it was given, or two providers pointing at each other — fails with
  `{:error, :materialize_hop_limit}` instead of looping.
  """

  alias Zaq.Contracts.Record
  alias Zaq.Event
  alias Zaq.NodeRouter

  # Two is what the `disk` provider needs (Channels, then Ingestion). The headroom lets a
  # provider add one indirection of its own without a code change here; anything beyond that
  # is a loop, not a topology.
  @default_max_hops 4

  @doc """
  Returns the record with its content populated.

  A record that already has content is returned untouched and nothing is dispatched. A
  record with `content: nil` dispatches its `materializing_event`; if that answers with
  another unmaterialized record the chain is followed, and the record is returned with the
  fetched content and the event cleared.

  ## Options

    * `:node_router` — module used to dispatch, defaults to `Zaq.NodeRouter`.
    * `:max_hops` — how many dispatches a single call may chain, defaults to
      `#{@default_max_hops}`.
  """
  @spec materialize(Record.t(), keyword()) :: {:ok, Record.t()} | {:error, term()}
  def materialize(record, opts \\ [])

  def materialize(%Record{content: nil, materializing_event: %Event{}} = record, opts) do
    hop(record, opts, Keyword.get(opts, :max_hops, @default_max_hops))
  end

  def materialize(%Record{content: nil}, _opts), do: {:error, :not_materializable}

  def materialize(%Record{} = record, _opts), do: {:ok, record}

  # Each hop asks the record's current event for content. A hop that answers with a record
  # still lacking content but carrying a new event is a redirect, and is followed against
  # the remaining budget.
  defp hop(%Record{}, _opts, hops) when hops <= 0, do: {:error, :materialize_hop_limit}

  defp hop(%Record{materializing_event: event} = record, opts, hops) do
    opts
    |> Keyword.get(:node_router, NodeRouter)
    |> dispatch(event)
    |> apply_content(record)
    |> follow(opts, hops - 1)
  end

  defp follow({:ok, %Record{content: nil, materializing_event: %Event{}} = record}, opts, hops),
    do: hop(record, opts, hops)

  defp follow(result, _opts, _hops), do: result

  defp dispatch(node_router, event) do
    event |> node_router.dispatch() |> Map.fetch!(:response)
  end

  @merged_fields ~w(id name mime_type path url size description)a

  # A fetched record is richer than the stub that asked for it — it carries the name, size
  # and mime type the source actually holds — so it wins field by field.
  defp apply_content({:ok, %Record{content: content} = fetched}, record)
       when not is_nil(content) do
    {:ok, %{carry_over(fetched, record) | materializing_event: nil}}
  end

  # A redirect: the provider answered with metadata and a fresh event rather than bytes,
  # because the role holding the file is not the one that was asked. The fetched record
  # wins for the same reason as above, and its event — not the spent one — drives the next
  # hop. Distinct from the clause below: content is absent, but convergence is still possible.
  defp apply_content({:ok, %Record{materializing_event: %Event{}} = fetched}, record) do
    {:ok, carry_over(fetched, record)}
  end

  # Datasource bridges answer `download_document` with `%{record: …}` — see
  # `Zaq.Channels.JidoConnectBridge` and `Zaq.Channels.DiskBridge`. Unwrap one level so a
  # materializing event can target that callback directly.
  defp apply_content({:ok, %{record: inner}}, record), do: apply_content({:ok, inner}, record)

  # A provider that answers with a plain map rather than a `%Record{}`. Recognised fields
  # are lifted onto the record so the normalization the tool promises still happens, instead
  # of the caller receiving a record carrying only content.
  #
  # A success with neither content nor a next event is a dead end, so it is reported as an
  # error: returning `{:ok, record}` would claim success while leaving the record
  # unmaterialized, looping any caller that retries until content is present. Note a plain
  # map can never be a redirect — `materializing_event` lives only on the struct.
  defp apply_content({:ok, payload}, record) when is_map(payload) do
    case payload_content(payload) do
      nil -> {:error, {:unexpected_materialize_response, {:ok, payload}}}
      content -> {:ok, record |> merge_payload(payload) |> materialized(content)}
    end
  end

  defp apply_content({:error, reason}, _record), do: {:error, reason}

  defp apply_content(other, _record), do: {:error, {:unexpected_materialize_response, other}}

  # The hop that returns the bytes is not always the hop that knows the file's name. A
  # redirecting provider answers with metadata and points elsewhere for content, and the
  # role it points at may hold nothing but bytes. Filling only the blanks keeps what the
  # chain already established without ever overwriting a value the newer hop did supply.
  defp carry_over(%Record{} = fetched, %Record{} = previous) do
    Enum.reduce(@merged_fields, fetched, fn field, acc ->
      case Map.fetch!(acc, field) do
        nil -> Map.put(acc, field, Map.fetch!(previous, field))
        _present -> acc
      end
    end)
  end

  defp merge_payload(%Record{} = record, payload) do
    Enum.reduce(@merged_fields, record, fn field, acc ->
      case payload_field(payload, field) do
        nil -> acc
        value -> Map.put(acc, field, value)
      end
    end)
  end

  defp payload_content(payload), do: payload_field(payload, :content)

  defp payload_field(payload, field) do
    Map.get(payload, field) || Map.get(payload, Atom.to_string(field))
  end

  defp materialized(%Record{} = record, content),
    do: %{record | content: content, materializing_event: nil}
end
