defmodule Zaq.Channels.Materializers.CommunicationMediaTest do
  use Zaq.DataCase, async: true

  alias Zaq.Channels.Materializers.CommunicationMedia
  alias Zaq.Event
  alias Zaq.Materialization.Handle

  defmodule StubNodeRouter do
    def dispatch(%Event{request: request, opts: opts} = event) do
      send(
        self(),
        {:dispatch, event.next_hop.destination, opts[:action], request, event.actor, opts}
      )

      %{
        event
        | response: {:ok, %{record: %{id: request["reference"], kind: :file, content: "bytes"}}}
      }
    end
  end

  defmodule StubCommunicationBridge do
  end

  test "issues communication-media handles with stable locator fields" do
    assert {:ok, handle} =
             CommunicationMedia.issue("mattermost", "file-1", %{
               "name" => "photo.png",
               "mime_type" => "image/png",
               "size" => 4,
               "source_author_id" => "author-1"
             })

    assert {:ok, %{type: "communication_media", locator: locator}} = Handle.verify(handle)
    assert locator["provider"] == "mattermost"
    assert locator["reference"] == "file-1"
    assert locator["source_author_id"] == "author-1"
  end

  test "materializes through the existing materialize_record action" do
    assert {:ok, %{record: _record}} =
             CommunicationMedia.materialize(
               %{
                 "provider" => "mattermost",
                 "reference" => "file-1",
                 "source_author_id" => "author-1"
               },
               %{node_router: StubNodeRouter, actor: %{id: "author-1"}}
             )

    assert_received {:dispatch, :channels, :materialize_record, request, %{id: "author-1"}, opts}
    assert request["provider"] == "mattermost"
    assert request["reference"] == "file-1"
    assert opts[:materialization_verified] == true
  end

  test "rejects actor mismatches and nil actors" do
    locator = %{
      "provider" => "mattermost",
      "reference" => "file-1",
      "source_author_id" => "author-1"
    }

    assert {:error, :unauthorized_materialization_handle} =
             CommunicationMedia.materialize(locator, %{
               node_router: StubNodeRouter,
               actor: %{id: "other"}
             })

    assert {:error, :unauthorized_materialization_handle} =
             CommunicationMedia.materialize(locator, %{node_router: StubNodeRouter})
  end

  test "rejects invalid handle issue arguments" do
    for {provider, reference, attrs} <- [
          {[:mattermost], "file-1", %{}},
          {"mattermost", nil, %{}},
          {"mattermost", "file-1", []}
        ] do
      assert {:error, :invalid_materialization_handle} =
               CommunicationMedia.issue(provider, reference, attrs)
    end
  end

  test "rejects non-map materialization arguments" do
    assert {:error, :invalid_materialization_locator} = CommunicationMedia.materialize(nil, %{})
    refute_received {:dispatch, _, _, _, _, _}

    assert {:error, :invalid_materialization_locator} = CommunicationMedia.materialize(%{}, nil)
    refute_received {:dispatch, _, _, _, _, _}

    assert {:error, :invalid_materialization_locator} =
             CommunicationMedia.materialize(%{}, %{}, [])

    refute_received {:dispatch, _, _, _, _, _}
  end

  test "rejects unsupported provider value types as blank providers" do
    assert {:error, :invalid_materialization_locator} =
             CommunicationMedia.materialize(
               %{"provider" => [:mattermost], "reference" => "file-1"},
               %{node_router: StubNodeRouter, skip_permissions: true}
             )

    refute_received {:dispatch, _, _, _, _, _}
  end

  test "normalizes atom locator identities before dispatch" do
    assert {:ok, %{record: _record}} =
             CommunicationMedia.materialize(
               %{
                 "provider" => :mattermost,
                 "reference" => :file_1,
                 "source_author_id" => "author-1"
               },
               %{node_router: StubNodeRouter, actor: %{id: "author-1"}}
             )

    assert_received {:dispatch, :channels, :materialize_record, request, _, _opts}
    assert request["provider"] == "mattermost"
    assert request["reference"] == "file_1"
  end

  test "normalizes integer locator identities before dispatch" do
    assert {:ok, %{record: _record}} =
             CommunicationMedia.materialize(
               %{"provider" => 123, "reference" => 456, "source_author_id" => "author-1"},
               %{node_router: StubNodeRouter, actor: %{id: "author-1"}}
             )

    assert_received {:dispatch, :channels, :materialize_record, request, _, _opts}
    assert request["provider"] == "123"
    assert request["reference"] == "456"
  end

  test "authorizes from incoming author when actor is absent" do
    assert {:ok, %{record: _record}} =
             CommunicationMedia.materialize(
               %{
                 "provider" => "mattermost",
                 "reference" => "file-1",
                 "source_author_id" => "author-1"
               },
               %{node_router: StubNodeRouter, incoming: %{author_id: "author-1"}}
             )

    assert_received {:dispatch, :channels, :materialize_record, _request, nil, _opts}
  end

  test "forwards communication bridge override in event options" do
    assert {:ok, %{record: _record}} =
             CommunicationMedia.materialize(
               %{
                 "provider" => "mattermost",
                 "reference" => "file-1",
                 "source_author_id" => "author-1"
               },
               %{
                 node_router: StubNodeRouter,
                 actor: %{id: "author-1"},
                 communication_bridge_module: StubCommunicationBridge
               }
             )

    assert_received {:dispatch, :channels, :materialize_record, _request, _actor, opts}
    assert opts[:materialization_verified] == true
    assert opts[:communication_bridge_module] == StubCommunicationBridge
  end

  test "allows explicit permission bypass for trusted internal callers" do
    locator = %{
      "provider" => "mattermost",
      "reference" => "file-1",
      "source_author_id" => "author-1"
    }

    assert {:ok, %{record: _record}} =
             CommunicationMedia.materialize(locator, %{
               node_router: StubNodeRouter,
               skip_permissions: true
             })
  end

  test "rejects runtime options because communication media declares none" do
    locator = %{
      "provider" => "mattermost",
      "reference" => "file-1",
      "source_author_id" => "author-1"
    }

    assert {:error, :invalid_materialization_options} =
             CommunicationMedia.materialize(
               locator,
               %{node_router: StubNodeRouter, actor: %{id: "author-1"}},
               %{"reference" => "other"}
             )
  end
end
