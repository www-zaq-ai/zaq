defmodule Zaq.Contracts.Record.MaterializerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Materializer
  alias Zaq.Event

  @allowed_event Event.new(%{provider: "disk", params: %{"file_id" => "42"}}, :channels,
                   opts: [action: :data_source_download_document]
                 )

  # Raises if dispatched. Any test asserting "no dispatch happened" uses this rather than a
  # flag, so a stray dispatch fails loudly instead of silently passing.
  defmodule ForbiddenRouter do
    def dispatch(%Event{}), do: raise("dispatch must not be called")
  end

  defmodule ContentRouter do
    def dispatch(%Event{opts: opts} = event) do
      send(self(), {:dispatched, opts[:action]})
      %{event | response: {:ok, %Zaq.Contracts.Record{id: "42", kind: :file, content: "bytes"}}}
    end
  end

  defmodule MapResponseRouter do
    def dispatch(%Event{} = event), do: %{event | response: {:ok, %{content: "from-map"}}}
  end

  defmodule StringKeyResponseRouter do
    def dispatch(%Event{} = event), do: %{event | response: {:ok, %{"content" => "from-string"}}}
  end

  defmodule ErrorRouter do
    def dispatch(%Event{} = event), do: %{event | response: {:error, :timeout}}
  end

  defmodule GarbageRouter do
    def dispatch(%Event{} = event), do: %{event | response: :nonsense}
  end

  defp record(attrs) do
    struct!(%Record{id: "42", kind: :file}, attrs)
  end

  describe "already-materialized records" do
    test "returns a record with binary content untouched, without dispatching" do
      rec = record(content: "already here", materializing_event: @allowed_event)

      assert {:ok, ^rec} = Materializer.materialize(rec, node_router: ForbiddenRouter)
    end

    # D4: an empty file legitimately materializes to "". Treating "" as unmaterialized would
    # re-dispatch on every call, forever.
    test "treats empty-string content as materialized" do
      rec = record(content: "", materializing_event: @allowed_event)

      assert {:ok, ^rec} = Materializer.materialize(rec, node_router: ForbiddenRouter)
    end

    # Exercises the arity-1 default. Safe without a router double precisely because an
    # already-materialized record must not reach a dispatch.
    test "defaults to the real node router and never reaches it" do
      rec = record(content: "already here", materializing_event: @allowed_event)

      assert {:ok, ^rec} = Materializer.materialize(rec)
    end

    test "treats list and map content as materialized" do
      list_rec = record(content: [], materializing_event: @allowed_event)
      map_rec = record(content: %{}, materializing_event: @allowed_event)

      assert {:ok, ^list_rec} = Materializer.materialize(list_rec, node_router: ForbiddenRouter)
      assert {:ok, ^map_rec} = Materializer.materialize(map_rec, node_router: ForbiddenRouter)
    end
  end

  describe "dispatching" do
    test "dispatches when content is nil and merges the returned content" do
      rec = record(content: nil, materializing_event: @allowed_event)

      assert {:ok, materialized} = Materializer.materialize(rec, node_router: ContentRouter)
      assert materialized.content == "bytes"
      assert materialized.id == "42"
      assert_received {:dispatched, :data_source_download_document}
    end

    test "clears the materializing_event once spent" do
      rec = record(content: nil, materializing_event: @allowed_event)

      assert {:ok, materialized} = Materializer.materialize(rec, node_router: ContentRouter)
      assert materialized.materializing_event == nil
    end

    test "accepts a bare map response with an atom content key" do
      rec = record(content: nil, materializing_event: @allowed_event)

      assert {:ok, %Record{content: "from-map"}} =
               Materializer.materialize(rec, node_router: MapResponseRouter)
    end

    test "accepts a bare map response with a string content key" do
      rec = record(content: nil, materializing_event: @allowed_event)

      assert {:ok, %Record{content: "from-string"}} =
               Materializer.materialize(rec, node_router: StringKeyResponseRouter)
    end

    # The shape every datasource bridge returns from download_document.
    test "unwraps a %{record: ...} bridge response" do
      defmodule BridgeShapeRouter do
        def dispatch(%Event{} = event) do
          %{
            event
            | response:
                {:ok, %{record: %Zaq.Contracts.Record{id: "42", kind: :file, content: "wrapped"}}}
          }
        end
      end

      rec = record(content: nil, materializing_event: @allowed_event)

      assert {:ok, %Record{content: "wrapped"}} =
               Materializer.materialize(rec, node_router: BridgeShapeRouter)
    end

    test "unwraps a %{record: ...} response carrying a plain map" do
      defmodule BridgeMapShapeRouter do
        def dispatch(%Event{} = event) do
          %{event | response: {:ok, %{record: %{"content" => "plain"}}}}
        end
      end

      rec = record(content: nil, materializing_event: @allowed_event)

      assert {:ok, %Record{content: "plain"}} =
               Materializer.materialize(rec, node_router: BridgeMapShapeRouter)
    end

    test "accepts the ingestion materialize_record event" do
      event =
        Event.new(%{file_id: "42"}, :ingestion, opts: [action: :materialize_record])

      rec = record(content: nil, materializing_event: event)

      assert {:ok, %Record{content: "bytes"}} =
               Materializer.materialize(rec, node_router: ContentRouter)
    end
  end

  describe "guards" do
    # D3: whoever holds a record must not control which event fires on which node.
    test "refuses a non-whitelisted action without dispatching" do
      event = Event.new(%{}, :channels, opts: [action: :data_source_delete_file])
      rec = record(content: nil, materializing_event: event)

      assert {:error, {:event_not_allowed, {:channels, :data_source_delete_file}}} =
               Materializer.materialize(rec, node_router: ForbiddenRouter)
    end

    test "refuses a whitelisted action aimed at the wrong role" do
      event = Event.new(%{}, :engine, opts: [action: :materialize_record])
      rec = record(content: nil, materializing_event: event)

      assert {:error, {:event_not_allowed, {:engine, :materialize_record}}} =
               Materializer.materialize(rec, node_router: ForbiddenRouter)
    end

    test "refuses an event carrying no action" do
      event = Event.new(%{}, :channels)
      rec = record(content: nil, materializing_event: event)

      assert {:error, {:event_not_allowed, {:channels, nil}}} =
               Materializer.materialize(rec, node_router: ForbiddenRouter)
    end

    # `Event`'s @enforce_keys requires next_hop to be *given*, not to be an EventHop, so a
    # malformed event is constructible. It must be refused, not crash the caller.
    test "refuses an event with no routable destination" do
      event = %Event{request: %{}, next_hop: nil, opts: [action: :materialize_record]}
      rec = record(content: nil, materializing_event: event)

      assert {:error, {:event_not_allowed, {nil, :materialize_record}}} =
               Materializer.materialize(rec, node_router: ForbiddenRouter)
    end

    test "errors when content is nil and there is no event to dispatch" do
      rec = record(content: nil, materializing_event: nil)

      assert {:error, :not_materializable} =
               Materializer.materialize(rec, node_router: ForbiddenRouter)
    end
  end

  describe "failure propagation" do
    test "propagates a dispatch error unchanged" do
      rec = record(content: nil, materializing_event: @allowed_event)

      assert {:error, :timeout} = Materializer.materialize(rec, node_router: ErrorRouter)
    end

    test "reports an unrecognised response shape rather than crashing" do
      rec = record(content: nil, materializing_event: @allowed_event)

      assert {:error, {:unexpected_materialize_response, :nonsense}} =
               Materializer.materialize(rec, node_router: GarbageRouter)
    end

    # A response that succeeds but carries no content would otherwise leave the record
    # unmaterialized while reporting success — an infinite re-dispatch for any caller
    # that loops until content is present.
    test "rejects a success response that carries no content" do
      defmodule ContentlessRouter do
        def dispatch(%Event{} = event), do: %{event | response: {:ok, %{status: "done"}}}
      end

      rec = record(content: nil, materializing_event: @allowed_event)

      assert {:error, {:unexpected_materialize_response, _}} =
               Materializer.materialize(rec, node_router: ContentlessRouter)
    end
  end

  describe "idempotence" do
    property "materializing twice equals materializing once" do
      check all(
              content <-
                one_of([
                  constant(nil),
                  constant(""),
                  string(:printable),
                  constant([]),
                  list_of(string(:printable), max_length: 3),
                  constant(%{}),
                  map_of(string(:alphanumeric), integer(), max_length: 3)
                ]),
              id <- string(:alphanumeric, min_length: 1)
            ) do
        rec = record(id: id, content: content, materializing_event: @allowed_event)

        assert {:ok, once} = Materializer.materialize(rec, node_router: ContentRouter)
        assert {:ok, twice} = Materializer.materialize(once, node_router: ForbiddenRouter)

        assert twice == once
      end
    end
  end
end
