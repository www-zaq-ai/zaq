defmodule Zaq.Contracts.RecordHydratorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Contracts.{Record, RecordCapability, RecordHydrator}
  alias Zaq.Event

  defmodule HydrationNodeRouter do
    def dispatch(%Event{request: %Record{} = record, next_hop: %{destination: :channels}} = event) do
      send(self(), {:hydrate_record, event})

      materializing_event =
        Event.new(%{provider: record.attributes["provider"], media_id: record.id}, :channels,
          opts: [action: :materialize_record]
        )

      %{event | response: {:ok, materializing_event}}
    end
  end

  defmodule RejectDispatchNodeRouter do
    def dispatch(_event), do: raise("unexpected hydration dispatch")
  end

  test "reconstructs a persisted communication media record and asks its owning role for an event" do
    stored =
      signed_record()
      |> Record.metadata()
      |> Map.merge(%{
        "content" => "must not survive",
        "raw" => %{"token" => "must not survive"},
        "materializing_event" => %{"action" => "untrusted"}
      })

    assert {:ok, %Record{} = record} =
             RecordHydrator.hydrate(stored, %{
               node_router: HydrationNodeRouter,
               actor: %{id: "author-1"}
             })

    assert record.id == "media-1"
    assert record.kind == :file
    assert record.name == "photo.png"
    assert record.content == nil
    assert record.raw == %{}

    assert %Event{request: %{provider: "mattermost", media_id: "media-1"}} =
             record.materializing_event

    assert_received {:hydrate_record,
                     %Event{request: %Record{materializing_event: nil}, opts: opts}}

    assert opts[:action] == :hydrate_record
  end

  test "rejects a signed communication record when fetch metadata is changed" do
    stored =
      signed_record()
      |> Record.metadata()
      |> put_in(["attributes", "source_id"], "https://internal.example/secret")

    assert {:error, :invalid_record_capability} =
             RecordHydrator.hydrate(stored, %{node_router: RejectDispatchNodeRouter})
  end

  test "returns an already hydrated record unchanged" do
    event = Event.new(%{id: "media-1"}, :channels, opts: [action: :materialize_record])
    record = %Record{id: "media-1", kind: :file, materializing_event: event}

    assert {:ok, ^record} =
             RecordHydrator.hydrate(record, %{node_router: RejectDispatchNodeRouter})
  end

  test "returns an already materialized record unchanged" do
    record = %Record{id: "media-1", kind: :file, content: "bytes"}

    assert {:ok, ^record} =
             RecordHydrator.hydrate(record, %{node_router: RejectDispatchNodeRouter})
  end

  test "rejects malformed persisted records before dispatch" do
    assert {:error, {:invalid_record, :missing_id}} =
             RecordHydrator.hydrate(%{"kind" => "file"}, %{
               node_router: RejectDispatchNodeRouter
             })

    assert {:error, {:invalid_record, {:unsupported_kind, "executable"}}} =
             RecordHydrator.hydrate(%{"id" => "1", "kind" => "executable"}, %{
               node_router: RejectDispatchNodeRouter
             })
  end

  property "persisted source metadata cannot select an arbitrary destination" do
    check all(
            source_type <- string(:alphanumeric, min_length: 1),
            source_type != "communication_media"
          ) do
      record = %{
        "id" => "media-1",
        "kind" => "file",
        "attributes" => %{
          "source_type" => source_type,
          "destination" => "engine",
          "action" => "delete_everything"
        }
      }

      assert {:error, {:unsupported_source_type, ^source_type}} =
               RecordHydrator.hydrate(record, %{node_router: RejectDispatchNodeRouter})
    end
  end

  defp signed_record do
    %Record{
      id: "media-1",
      kind: :file,
      name: "photo.png",
      mime_type: "image/png",
      size: 42,
      attributes: %{
        "source_type" => "communication_media",
        "provider" => "mattermost",
        "source_id" => "media-1",
        "source_author_id" => "author-1"
      }
    }
    |> RecordCapability.sign!()
  end
end
