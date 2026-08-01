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

  ## Two guards on the carried event

  `materializing_event` is a dispatchable event travelling inside a data payload, which is a
  confused-deputy risk: whoever holds the record would otherwise choose what fires, where,
  and with what params.

    1. The field is excluded from `Record`'s `Jason.Encoder` `only:` list, so it cannot
       survive a round trip through an LLM tool result or persisted workflow state.
    2. `@allowed_events` here is checked **before** dispatch, so even an in-process record
       built by unexpected code cannot reach an arbitrary role and action.

  A record whose event is not whitelisted is refused without dispatching.

  ## Only `nil` means unmaterialized

  An empty file materializes to `""`, which is a legitimate result. Treating `""` as
  "still empty" would re-dispatch on every call and never converge, so the check is
  strictly `nil`. The event is cleared once spent, making `materialize/2` idempotent:
  materializing an already-materialized record is a no-op that dispatches nothing.
  """

  alias Zaq.Contracts.Record
  alias Zaq.Event
  alias Zaq.EventHop
  alias Zaq.NodeRouter

  # The complete set of destinations a record may pull its content from. Extend
  # deliberately: every entry here is a role+action any holder of a record can cause to run.
  @allowed_events [
    {:channels, :data_source_download_document},
    {:ingestion, :materialize_record}
  ]

  @doc """
  Returns the record with its content populated.

  A record that already has content is returned untouched and nothing is dispatched. A
  record with `content: nil` dispatches its `materializing_event` — provided that event is
  whitelisted — and returns the record with the fetched content and the event cleared.

  ## Options

    * `:node_router` — module used to dispatch, defaults to `Zaq.NodeRouter`.
  """
  @spec materialize(Record.t(), keyword()) :: {:ok, Record.t()} | {:error, term()}
  def materialize(record, opts \\ [])

  def materialize(%Record{content: nil, materializing_event: %Event{} = event} = record, opts) do
    case event_key(event) do
      key when key in @allowed_events ->
        opts
        |> Keyword.get(:node_router, NodeRouter)
        |> dispatch(event)
        |> apply_content(record)

      key ->
        {:error, {:event_not_allowed, key}}
    end
  end

  def materialize(%Record{content: nil}, _opts), do: {:error, :not_materializable}

  def materialize(%Record{} = record, _opts), do: {:ok, record}

  defp dispatch(node_router, event) do
    event |> node_router.dispatch() |> Map.fetch!(:response)
  end

  # A fetched record is richer than the stub that asked for it — it carries the name, size
  # and mime type the source actually holds — so it wins outright, keeping only the
  # original's id if the response left one out.
  defp apply_content({:ok, %Record{content: content} = fetched}, record)
       when not is_nil(content) do
    {:ok, %{fetched | id: fetched.id || record.id, materializing_event: nil}}
  end

  # Datasource bridges answer `download_document` with `%{record: …}` — see
  # `Zaq.Channels.JidoConnectBridge` and `Zaq.Channels.DiskBridge`. Unwrap one level so a
  # materializing event can target that callback directly.
  defp apply_content({:ok, %{record: inner}}, record), do: apply_content({:ok, inner}, record)

  # A provider that answers with a plain map rather than a `%Record{}`. Recognised fields
  # are lifted onto the record so the normalization the tool promises still happens, instead
  # of the caller receiving a record carrying only content.
  defp apply_content({:ok, payload}, record) when is_map(payload) do
    case payload_content(payload) do
      nil -> {:error, {:unexpected_materialize_response, {:ok, payload}}}
      content -> {:ok, record |> merge_payload(payload) |> materialized(content)}
    end
  end

  # A success carrying no content is treated as a failure: it would otherwise report
  # success while leaving the record unmaterialized, which loops any caller that retries
  # until content is present.
  defp apply_content({:error, reason}, _record), do: {:error, reason}

  defp apply_content(other, _record), do: {:error, {:unexpected_materialize_response, other}}

  @merged_fields ~w(id name mime_type path url size description)a

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

  defp event_key(%Event{next_hop: %EventHop{destination: role}, opts: opts}),
    do: {role, Keyword.get(opts, :action)}

  defp event_key(%Event{opts: opts}), do: {nil, Keyword.get(opts, :action)}
end
