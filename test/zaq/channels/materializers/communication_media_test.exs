defmodule Zaq.Channels.Materializers.CommunicationMediaTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Channels.Api
  alias Zaq.Channels.Materializers.CommunicationMedia
  alias Zaq.Contracts.Record
  alias Zaq.Event
  alias Zaq.Materialization.Handle

  property "hydration preserves native identifiers and signed provenance after JSON storage" do
    check all(
            reference <- string(:alphanumeric, min_length: 1, max_length: 300),
            channel <- integer(-1_000_000..-1),
            message <- integer(1..1_000_000)
          ) do
      source =
        CommunicationMedia.source_metadata("telegram", reference, %{
          "channel_config_id" => 3,
          "source_author_id" => "author-1",
          "source_channel_id" => channel,
          "source_message_id" => message
        })

      stored =
        Record.attachment_metadata(%Record{
          id: reference,
          kind: :file,
          attributes: %{"materialization_source" => source}
        })

      stored = Jason.decode!(Jason.encode!(stored))
      assert {:ok, record} = CommunicationMedia.hydrate(stored, %{actor: %{id: "author-1"}})
      assert {:ok, %{locator: locator}} = Handle.verify(record.materialization_handle)
      assert locator == source["locator"]
      assert record.content == nil
    end
  end

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

  test "canonical redemption reads the exact message before fetching and strips runtime scope" do
    {descriptor, scope, record} = canonical_attachment()
    actor = %{person: %{id: 9}}
    context = %{actor: actor, node_router: Zaq.NodeRouterMock}

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      assert event.next_hop.destination == :engine
      assert event.opts[:action] == :conversation
      assert event.opts[:confidential]
      assert event.actor == actor

      assert event.request == %{
               action: :canonical_message,
               transcript_id: scope["transcript_id"],
               message_id: scope["message_id"]
             }

      %{
        event
        | response:
            {:ok,
             %{
               transcript_id: scope["transcript_id"],
               message_id: scope["message_id"],
               attachments: [descriptor]
             }}
      }
    end)

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      assert event.next_hop.destination == :channels
      assert event.opts[:action] == :materialize_record
      refute Map.has_key?(event.request, "canonical_attachment")
      %{event | response: {:ok, %Record{id: descriptor["id"], kind: :file, content: "bytes"}}}
    end)

    assert {:ok, %Record{content: "bytes"}} =
             CommunicationMedia.materialize(
               verified_locator(record),
               context
             )
  end

  test "canonical denial cannot fall back to author equality or trusted legacy bypass" do
    {_descriptor, _scope, record} = canonical_attachment()

    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      assert event.opts[:action] == :conversation
      %{event | response: {:error, :unauthorized}}
    end)

    assert {:error, :unauthorized_materialization_handle} =
             CommunicationMedia.materialize(verified_locator(record), %{
               actor: %{id: "author-1"},
               skip_permissions: true,
               node_router: Zaq.NodeRouterMock
             })
  end

  test "canonical unavailable or malformed message responses fail before fetching" do
    {_descriptor, _scope, record} = canonical_attachment()

    for response <- [
          {:error, :history_unavailable},
          :unexpected,
          {:ok, %{}},
          {:ok, %Record{id: "unexpected", kind: :file}}
        ] do
      expect(Zaq.NodeRouterMock, :dispatch, fn event -> %{event | response: response} end)

      assert {:error, _} =
               CommunicationMedia.materialize(verified_locator(record), %{
                 node_router: Zaq.NodeRouterMock
               })
    end
  end

  property "altered canonical source bindings cannot authorize unrelated attachment bytes" do
    check all(other <- string(:alphanumeric, min_length: 1, max_length: 30)) do
      {descriptor, scope, record} = canonical_attachment()

      mismatched =
        put_in(
          descriptor,
          ["attributes", "materialization_source", "locator", "source_channel_id"],
          "other-" <> other
        )

      expect(Zaq.NodeRouterMock, :dispatch, fn event ->
        %{
          event
          | response:
              {:ok,
               %{
                 transcript_id: scope["transcript_id"],
                 message_id: scope["message_id"],
                 attachments: [mismatched]
               }}
        }
      end)

      assert {:error, :unauthorized_materialization_handle} =
               CommunicationMedia.materialize(verified_locator(record), %{
                 node_router: Zaq.NodeRouterMock
               })
    end
  end

  test "canonical placement mismatch, missing descriptors and duplicate identities deny" do
    {descriptor, scope, record} = canonical_attachment()

    message = %{
      transcript_id: scope["transcript_id"],
      message_id: scope["message_id"],
      attachments: [descriptor]
    }

    for altered <- [
          %{message | transcript_id: Ecto.UUID.generate()},
          %{message | message_id: Ecto.UUID.generate()},
          %{message | attachments: []},
          %{message | attachments: [descriptor, descriptor]}
        ] do
      expect(Zaq.NodeRouterMock, :dispatch, fn event -> %{event | response: {:ok, altered}} end)

      assert {:error, :unauthorized_materialization_handle} =
               CommunicationMedia.materialize(verified_locator(record), %{
                 node_router: Zaq.NodeRouterMock
               })
    end
  end

  test "present invalid canonical scope never downgrades to legacy author authorization" do
    {_descriptor, scope, record} = canonical_attachment()

    for invalid <- [
          nil,
          %{},
          %{scope | "version" => 2},
          Map.delete(scope, "message_id"),
          Map.put(scope, "extra", "value")
        ] do
      locator = Map.put(verified_locator(record), "canonical_attachment", invalid)
      assert {:ok, handle} = Zaq.Materialization.issue("communication_media", locator)

      assert {:error, error} =
               Zaq.Materialization.materialize(
                 handle,
                 %{
                   actor: %{id: "author-1"},
                   skip_permissions: true,
                   node_router: Zaq.NodeRouterMock
                 },
                 "Download failed"
               )

      assert error =~ "unauthorized_materialization_handle"
    end
  end

  defp canonical_attachment do
    source =
      CommunicationMedia.source_metadata("mattermost", "canonical-file", %{
        "channel_config_id" => 3,
        "source_author_id" => "author-1",
        "source_channel_id" => "room",
        "source_message_id" => "message"
      })

    descriptor = %{
      "id" => "canonical-file",
      "kind" => "file",
      "attributes" => %{"materialization_source" => source}
    }

    scope = %{
      "version" => 1,
      "transcript_id" => Ecto.UUID.generate(),
      "message_id" => Ecto.UUID.generate()
    }

    assert {:ok, record} =
             CommunicationMedia.hydrate(
               %{
                 descriptor: descriptor,
                 transcript_id: scope["transcript_id"],
                 message_id: scope["message_id"]
               },
               %{actor: %{person: %{id: 9}}}
             )

    {descriptor, scope, record}
  end

  defp verified_locator(record) do
    assert {:ok, %{locator: locator}} = Handle.verify(record.materialization_handle)
    locator
  end

  test "hydrates a lazy Record from durable metadata and newly signs the stored source" do
    source =
      CommunicationMedia.source_metadata("telegram", "provider-file-id", %{
        "channel_config_id" => 3,
        "source_author_id" => "author-1",
        "source_channel_id" => "-100",
        "source_message_id" => "12",
        "size" => 4,
        "name" => "photo.png",
        "mime_type" => "image/png"
      })

    descriptor = %{
      "id" => "provider-file-id",
      "kind" => "file",
      "name" => "photo.png",
      "size" => 4,
      "attributes" => %{"materialization_source" => source},
      "materialization_handle" => "stale"
    }

    assert {:ok, %Record{content: nil} = record} =
             CommunicationMedia.hydrate(descriptor, %{actor: %{id: "author-1"}})

    assert record.materialization_handle != "stale"
    assert {:ok, %{locator: locator}} = Handle.verify(record.materialization_handle)
    assert locator == source["locator"]
    refute_received {:dispatch, _, _, _, _, _}

    assert {:error, :unauthorized_materialization_handle} =
             CommunicationMedia.hydrate(descriptor, %{actor: %{id: "other"}})

    assert {:error, :unauthorized_materialization_handle} =
             CommunicationMedia.hydrate(descriptor, %{})
  end

  test "rejects legacy, mismatched, unsupported and malformed hydration sources" do
    source =
      CommunicationMedia.source_metadata("mattermost", "file", %{
        "channel_config_id" => 3,
        "source_author_id" => "author-1",
        "source_channel_id" => "room",
        "source_message_id" => "message"
      })

    descriptor = %{
      "id" => "file",
      "kind" => "file",
      "attributes" => %{"materialization_source" => source}
    }

    for invalid <- [
          nil,
          %{"id" => "file"},
          Map.put(descriptor, "id", "other"),
          put_in(descriptor, ["attributes", "materialization_source", "version"], 2),
          put_in(
            descriptor,
            ["attributes", "materialization_source", "locator", "reference"],
            %{}
          ),
          put_in(
            descriptor,
            ["attributes", "materialization_source", "locator", "channel_config_id"],
            nil
          )
        ] do
      assert {:error, :invalid_materialization_source} =
               CommunicationMedia.hydrate(invalid, %{actor: %{id: "author-1"}})
    end
  end

  test "hydration API requires confidential dispatch and preserves batch result order" do
    descriptor = %{"id" => "legacy", "name" => "display-only.png"}

    event =
      Event.new(%{attachments: [descriptor]}, :channels,
        actor: %{id: "author-1"},
        opts: [action: :hydrate_attachments]
      )

    assert %{response: {:error, :confidential_event_required}} =
             Api.handle_event(event, :hydrate_attachments, %{})

    assert %{response: {:ok, [{:error, :invalid_materialization_source}]}} =
             Api.handle_event(
               %{event | opts: [confidential: true]},
               :hydrate_attachments,
               %{}
             )
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
