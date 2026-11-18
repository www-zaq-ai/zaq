defmodule Zaq.Ingestion.EventsTest do
  use ExUnit.Case, async: true

  alias Zaq.Event
  alias Zaq.EventHop
  alias Zaq.Ingestion.Api
  alias Zaq.Ingestion.Events

  defmodule ProjectionReceiver do
    def sync_data_source_permission_projection(_provider, _config, _ids, context) do
      send(self(), {:projection_context, context})
      :ok
    end
  end

  test "source mutation confirmation comes only from trusted event opts" do
    request = %{
      provider: "disk",
      config_id: 12,
      affected_file_ids: ["file"],
      source_acl_mutation_committed: true
    }

    event =
      Event.new(request, :ingestion,
        actor: %{person_id: 7},
        opts: [ingestion_module: ProjectionReceiver]
      )

    assert %{response: :ok} =
             Api.handle_event(event, :sync_data_source_permission_projection, nil)

    assert_received {:projection_context, %{source_acl_mutation_committed: false}}

    confirmed = %{event | opts: Keyword.put(event.opts, :source_acl_mutation_committed, true)}

    assert %{response: :ok} =
             Api.handle_event(confirmed, :sync_data_source_permission_projection, nil)

    assert_received {:projection_context,
                     %{source_acl_mutation_committed: true, actor: %{person_id: 7}}}
  end

  defmodule StubNodeRouter do
    def dispatch(event) do
      send(self(), {:node_router_dispatch, event})
      %{event | response: {:ok, :materialized}}
    end
  end

  test "build_materialize_document_event/2 builds the fixed ingestion event" do
    event = Events.build_materialize_document_event(%{file_id: "documents:guide.md"})

    assert %Event{
             request: %{file_id: "documents:guide.md"},
             next_hop: %EventHop{destination: :ingestion, type: :sync},
             opts: [action: :materialize_document],
             response: nil
           } = event
  end

  test "build_and_dispatch_materialize_document_event/2 dispatches the configured ingestion event" do
    request = %{file_id: "documents:guide.md"}

    returned_event =
      Events.build_and_dispatch_materialize_document_event(request,
        node_router: StubNodeRouter,
        type: :async,
        actor: %{id: "person-1"},
        event_opts: [reply_to: :caller]
      )

    assert returned_event.response == {:ok, :materialized}

    assert_receive {:node_router_dispatch,
                    %Event{
                      request: ^request,
                      next_hop: %EventHop{destination: :ingestion, type: :async},
                      actor: %{id: "person-1"},
                      opts: [action: :materialize_document, reply_to: :caller],
                      response: nil
                    }}
  end
end
