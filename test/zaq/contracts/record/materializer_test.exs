defmodule Zaq.Contracts.Record.MaterializerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Materializer
  alias Zaq.Event

  @download_event Event.new(%{provider: "disk", params: %{"file_id" => "42"}}, :channels,
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

  # Counts the `:hop` messages a router left in the mailbox, so a hop-limit test can assert
  # how many dispatches actually happened rather than only that the call failed.
  defp drain_hops(count \\ 0) do
    receive do
      :hop -> drain_hops(count + 1)
    after
      0 -> count
    end
  end

  describe "already-materialized records" do
    test "returns a record with binary content untouched, without dispatching" do
      rec = record(content: "already here", materializing_event: @download_event)

      assert {:ok, ^rec} = Materializer.materialize(rec, node_router: ForbiddenRouter)
    end

    # D4: an empty file legitimately materializes to "". Treating "" as unmaterialized would
    # re-dispatch on every call, forever.
    test "treats empty-string content as materialized" do
      rec = record(content: "", materializing_event: @download_event)

      assert {:ok, ^rec} = Materializer.materialize(rec, node_router: ForbiddenRouter)
    end

    # Exercises the arity-1 default. Safe without a router double precisely because an
    # already-materialized record must not reach a dispatch.
    test "defaults to the real node router and never reaches it" do
      rec = record(content: "already here", materializing_event: @download_event)

      assert {:ok, ^rec} = Materializer.materialize(rec)
    end

    test "treats list and map content as materialized" do
      list_rec = record(content: [], materializing_event: @download_event)
      map_rec = record(content: %{}, materializing_event: @download_event)

      assert {:ok, ^list_rec} = Materializer.materialize(list_rec, node_router: ForbiddenRouter)
      assert {:ok, ^map_rec} = Materializer.materialize(map_rec, node_router: ForbiddenRouter)
    end
  end

  describe "dispatching" do
    test "dispatches when content is nil and merges the returned content" do
      rec = record(content: nil, materializing_event: @download_event)

      assert {:ok, materialized} = Materializer.materialize(rec, node_router: ContentRouter)
      assert materialized.content == "bytes"
      assert materialized.id == "42"
      assert_received {:dispatched, :data_source_download_document}
    end

    test "clears the materializing_event once spent" do
      rec = record(content: nil, materializing_event: @download_event)

      assert {:ok, materialized} = Materializer.materialize(rec, node_router: ContentRouter)
      assert materialized.materializing_event == nil
    end

    test "accepts a bare map response with an atom content key" do
      rec = record(content: nil, materializing_event: @download_event)

      assert {:ok, %Record{content: "from-map"}} =
               Materializer.materialize(rec, node_router: MapResponseRouter)
    end

    test "accepts a bare map response with a string content key" do
      rec = record(content: nil, materializing_event: @download_event)

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

      rec = record(content: nil, materializing_event: @download_event)

      assert {:ok, %Record{content: "wrapped"}} =
               Materializer.materialize(rec, node_router: BridgeShapeRouter)
    end

    test "unwraps a %{record: ...} response carrying a plain map" do
      defmodule BridgeMapShapeRouter do
        def dispatch(%Event{} = event) do
          %{event | response: {:ok, %{record: %{"content" => "plain"}}}}
        end
      end

      rec = record(content: nil, materializing_event: @download_event)

      assert {:ok, %Record{content: "plain"}} =
               Materializer.materialize(rec, node_router: BridgeMapShapeRouter)
    end

    # The record carries whichever event can fetch it; the ingestion path is a different
    # role and action from the datasource one and goes through the same code.
    test "dispatches the ingestion materialize_record event" do
      event =
        Event.new(%{file_id: "42"}, :ingestion, opts: [action: :materialize_record])

      rec = record(content: nil, materializing_event: event)

      assert {:ok, %Record{content: "bytes"}} =
               Materializer.materialize(rec, node_router: ContentRouter)

      assert_received {:dispatched, :materialize_record}
    end
  end

  # An internal provider is fronting a role that does not hold the file: `disk` is asked
  # through Channels, but the bytes live on an ingestion volume. Its honest answer is
  # metadata plus the event that fetches them, and that answer must be followed, not
  # treated as a contentless failure.
  describe "redirects" do
    # Records every action it saw, so the test asserts the *order* of the chain rather than
    # just the final content — a single hop returning "bytes" would otherwise look identical.
    defmodule RedirectRouter do
      def dispatch(%Event{opts: opts} = event) do
        send(self(), {:dispatched, opts[:action]})

        case opts[:action] do
          :data_source_download_document ->
            %{
              event
              | response:
                  {:ok,
                   %{
                     record: %Zaq.Contracts.Record{
                       id: "42",
                       kind: :file,
                       name: "guide.md",
                       mime_type: "text/markdown",
                       content: nil,
                       materializing_event:
                         Event.new(%{file_id: "42"}, :ingestion,
                           opts: [action: :materialize_record]
                         )
                     }
                   }}
            }

          :materialize_record ->
            %{
              event
              | response: {:ok, %Zaq.Contracts.Record{id: "42", kind: :file, content: "on disk"}}
            }
        end
      end
    end

    test "follows a record that answers with a fresh event instead of content" do
      rec = record(content: nil, materializing_event: @download_event)

      assert {:ok, %Record{content: "on disk", materializing_event: nil}} =
               Materializer.materialize(rec, node_router: RedirectRouter)

      assert_received {:dispatched, :data_source_download_document}
      assert_received {:dispatched, :materialize_record}
    end

    test "keeps metadata the redirecting hop supplied" do
      rec = record(content: nil, materializing_event: @download_event)

      assert {:ok, materialized} = Materializer.materialize(rec, node_router: RedirectRouter)
      assert materialized.name == "guide.md"
      assert materialized.mime_type == "text/markdown"
    end

    # A provider handing back the event it was given, or two pointing at each other, must
    # fail rather than dispatch forever.
    test "stops at the hop limit when a provider keeps redirecting" do
      defmodule EchoRouter do
        def dispatch(%Event{} = event) do
          send(self(), :hop)

          %{
            event
            | response:
                {:ok,
                 %Zaq.Contracts.Record{
                   id: "42",
                   kind: :file,
                   content: nil,
                   materializing_event:
                     Event.new(%{file_id: "42"}, :ingestion, opts: [action: :materialize_record])
                 }}
          }
        end
      end

      rec = record(content: nil, materializing_event: @download_event)

      assert {:error, :materialize_hop_limit} =
               Materializer.materialize(rec, node_router: EchoRouter, max_hops: 3)

      # The budget is spent, not exceeded: exactly three dispatches happened.
      assert 3 == drain_hops()
    end

    test "a contentless response with no next event is still an error" do
      defmodule DeadEndRouter do
        def dispatch(%Event{} = event) do
          %{event | response: {:ok, %Zaq.Contracts.Record{id: "42", kind: :file, content: nil}}}
        end
      end

      rec = record(content: nil, materializing_event: @download_event)

      assert {:error, {:unexpected_materialize_response, _}} =
               Materializer.materialize(rec, node_router: DeadEndRouter)
    end

    test "propagates an error raised on the second hop" do
      defmodule SecondHopErrorRouter do
        def dispatch(%Event{opts: opts} = event) do
          case opts[:action] do
            :data_source_download_document ->
              %{
                event
                | response:
                    {:ok,
                     %Zaq.Contracts.Record{
                       id: "42",
                       kind: :file,
                       content: nil,
                       materializing_event:
                         Event.new(%{file_id: "42"}, :ingestion,
                           opts: [action: :materialize_record]
                         )
                     }}
              }

            :materialize_record ->
              %{event | response: {:error, :forbidden}}
          end
        end
      end

      rec = record(content: nil, materializing_event: @download_event)

      assert {:error, :forbidden} =
               Materializer.materialize(rec, node_router: SecondHopErrorRouter)
    end
  end

  # The entry point for a caller that dispatched the provider command itself and holds the
  # payload. It reads an event off the answer; it never mints one — that distinction is what
  # keeps a tool from choosing a dispatch and calling it data.
  describe "materialize_response/3" do
    defp stub, do: %Record{id: "42", kind: :file}

    test "returns a provider's already-materialized record without dispatching" do
      payload = %{record: %Record{id: "42", kind: :file, content: "bytes", name: "a.md"}}

      assert {:ok, %Record{content: "bytes", name: "a.md"}} =
               Materializer.materialize_response(payload, stub(), node_router: ForbiddenRouter)
    end

    test "normalizes a plain provider map onto the stub" do
      payload = %{record: %{"content" => "plain", "name" => "b.md"}}

      assert {:ok, %Record{id: "42", content: "plain", name: "b.md"}} =
               Materializer.materialize_response(payload, stub(), node_router: ForbiddenRouter)
    end

    test "follows an event the provider attached to its answer" do
      payload = %{
        record: %Record{
          id: "42",
          kind: :file,
          name: "guide.md",
          content: nil,
          materializing_event:
            Event.new(%{file_id: "42"}, :ingestion, opts: [action: :materialize_record])
        }
      }

      assert {:ok, %Record{content: "bytes", name: "guide.md"}} =
               Materializer.materialize_response(payload, stub(), node_router: ContentRouter)

      assert_received {:dispatched, :materialize_record}
    end

    # The stub is the caller's own knowledge, not a source of truth to be preferred: it fills
    # only what the provider left blank.
    test "falls back to the stub for fields the provider omitted" do
      payload = %{record: %{"content" => "plain"}}

      assert {:ok, %Record{id: "42", name: "known.md"}} =
               Materializer.materialize_response(payload, %{stub() | name: "known.md"},
                 node_router: ForbiddenRouter
               )
    end

    test "reports a payload carrying neither content nor an event as an error" do
      assert {:error, {:unexpected_materialize_response, _}} =
               Materializer.materialize_response(%{status: "done"}, stub(),
                 node_router: ForbiddenRouter
               )
    end

    # The caller already spent one dispatch getting this payload, so the budget it passes
    # covers that hop too — `max_hops: 1` leaves no follow-up.
    test "counts the caller's own dispatch against the hop budget" do
      payload = %{
        record: %Record{
          id: "42",
          kind: :file,
          content: nil,
          materializing_event:
            Event.new(%{file_id: "42"}, :ingestion, opts: [action: :materialize_record])
        }
      }

      assert {:error, :materialize_hop_limit} =
               Materializer.materialize_response(payload, stub(),
                 node_router: ForbiddenRouter,
                 max_hops: 1
               )
    end
  end

  describe "guards" do
    test "errors when content is nil and there is no event to dispatch" do
      rec = record(content: nil, materializing_event: nil)

      assert {:error, :not_materializable} =
               Materializer.materialize(rec, node_router: ForbiddenRouter)
    end
  end

  describe "failure propagation" do
    test "propagates a dispatch error unchanged" do
      rec = record(content: nil, materializing_event: @download_event)

      assert {:error, :timeout} = Materializer.materialize(rec, node_router: ErrorRouter)
    end

    test "reports an unrecognised response shape rather than crashing" do
      rec = record(content: nil, materializing_event: @download_event)

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

      rec = record(content: nil, materializing_event: @download_event)

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
        rec = record(id: id, content: content, materializing_event: @download_event)

        assert {:ok, once} = Materializer.materialize(rec, node_router: ContentRouter)
        assert {:ok, twice} = Materializer.materialize(once, node_router: ForbiddenRouter)

        assert twice == once
      end
    end
  end
end
