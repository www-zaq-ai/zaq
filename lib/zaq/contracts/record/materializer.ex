defmodule Zaq.Contracts.Record.Materializer do
  @moduledoc """
  Fetches the content of an unmaterialized `Zaq.Contracts.Record`.

  A record crosses node boundaries with full metadata and `content: nil`, carrying a
  `materializing_event` that fetches its bytes. This module dispatches that event:

    * `materialize/2` — takes a record and returns it with `content` populated.
    * `materialize_response/3` — takes the payload a datasource provider answered with and
      returns a materialized record.

  Neither function creates a `materializing_event`; only the datasource bridge that went
  looking for the file sets one (`Zaq.Channels.DiskBridge` does, because the bytes live on
  an ingestion volume rather than in Channels).

  ## Rules

    * Only `content: nil` means unmaterialized. An empty file materializes to `""`, which
      is a valid result and is not re-fetched.
    * The event is cleared once dispatched, so materializing an already-materialized record
      is a no-op that dispatches nothing.
    * A dispatch may answer with another unmaterialized record — `content: nil` plus a
      fresh `materializing_event`. That is a redirect, not a failure: the new event is
      dispatched in turn until a hop returns content. `disk` uses this (Channels, then
      Ingestion); providers that hold the file themselves answer in one hop.
    * A response with neither content nor a next event is `{:error, :not_materializable}`.
    * `:max_hops` bounds the chain; exceeding it is `{:error, :materialize_hop_limit}`.
    * `materializing_event` is excluded from `Zaq.Contracts.Record`'s `Jason.Encoder` and
      from `Zaq.Contracts.Record.to_map/1`, so a record rebuilt from JSON always has
      `materializing_event: nil` and cannot be materialized.
  """

  alias Zaq.Contracts.Record
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.Utils

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

  @doc """
  Normalizes a datasource provider's successful answer into a materialized record.

  For callers that dispatched a provider command themselves (an agent tool calling
  `download_document`, say) and hold the returned payload rather than a record. The payload
  may carry content already or only metadata plus a `materializing_event`; this accepts
  either and returns a record with content, so the caller does not branch on the provider.

  `payload` is the value from a `{:ok, payload}` response — error responses are the
  caller's to handle and never reach here.

  `stub` supplies the fields the caller already knows, typically the id it asked for.
  Fields the provider leaves blank fall back to `stub`; fields it fills win.

  ## Options

  Same as `materialize/2`. `:max_hops` counts the caller's own dispatch, so the default
  leaves #{@default_max_hops - 1} follow-ups.
  """
  @spec materialize_response(term(), Record.t(), keyword()) ::
          {:ok, Record.t()} | {:error, term()}
  def materialize_response(payload, stub, opts \\ [])

  def materialize_response(payload, %Record{} = stub, opts) do
    {:ok, payload}
    |> apply_content(stub)
    |> follow(opts, Keyword.get(opts, :max_hops, @default_max_hops) - 1)
  end

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

  # Deliberately not `carry_over/2` with a different reader: the precedence is the opposite
  # way round. There the *fetched* record wins and the previous one only fills its blanks;
  # here the payload is the fetched side, so a field it supplies overwrites the stub's.
  defp merge_payload(%Record{} = record, payload) do
    Enum.reduce(@merged_fields, record, fn field, acc ->
      case payload_field(payload, field) do
        nil -> acc
        value -> Map.put(acc, field, value)
      end
    end)
  end

  defp payload_content(payload), do: payload_field(payload, :content)

  defp payload_field(payload, field), do: Utils.Map.present_value(payload, field)

  defp materialized(%Record{} = record, content),
    do: %{record | content: content, materializing_event: nil}
end
