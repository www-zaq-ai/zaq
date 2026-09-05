defmodule Zaq.Storage.Materializers.DiskDocumentTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Event
  alias Zaq.Materialization
  alias Zaq.Materialization.Handle
  alias Zaq.Storage.Materializers.DiskDocument

  defmodule StubNodeRouter do
    def dispatch(%Event{request: request, opts: opts} = event) do
      send(self(), {:dispatch, event.next_hop.destination, opts[:action], request})
      send(self(), {:dispatch_actor, event.next_hop.destination, opts[:action], event.actor})
      send(self(), {:dispatch_opts, event.next_hop.destination, opts[:action], opts})
      %{event | response: {:ok, %{content: "# guide", encoding: nil}}}
    end
  end

  test "issues disk document handles naming the volume source" do
    assert {:ok, handle} = DiskDocument.issue("disk:archives:loose.md")

    assert {:ok, %{type: "disk_document", locator: locator}} = Handle.verify(handle)
    assert locator == %{"file_id" => "disk:archives:loose.md"}
  end

  test "issues disk document handles with keyword signing options" do
    opts = [secret_key_base: "disk-document-custom-test-secret"]

    assert {:ok, handle} = DiskDocument.issue("disk:archives:loose.md", opts)
    assert is_binary(handle)

    assert {:ok,
            %{
              type: "disk_document",
              locator: %{"file_id" => "disk:archives:loose.md"},
              version: 1
            }} =
             Handle.verify(handle, opts)

    assert {:error, :invalid_materialization_handle} = Handle.verify(handle)
  end

  test "issues disk document handles with the current disk config id when present" do
    assert {:ok, handle} = DiskDocument.issue("guide.md", %{"config_id" => 42})

    assert {:ok, %{type: "disk_document", locator: locator}} = Handle.verify(handle)
    assert locator == %{"file_id" => "guide.md", "config_id" => 42}
  end

  test "refuses to issue a handle for anything but a source string" do
    assert {:error, :invalid_materialization_locator} = DiskDocument.issue(nil)
  end

  test "materializes through the fixed Storage materialize action" do
    assert {:ok, %{content: "# guide", encoding: nil}} =
             DiskDocument.materialize(%{"file_id" => "guide.md"}, %{node_router: StubNodeRouter})

    assert_received {:dispatch, :storage, :materialize_document, %{file_id: "guide.md"}}
  end

  test "passes the signed config id through to storage" do
    assert {:ok, _answer} =
             DiskDocument.materialize(
               %{"file_id" => "guide.md", "config_id" => 42},
               %{node_router: StubNodeRouter}
             )

    assert_received {:dispatch, :storage, :materialize_document,
                     %{"config_id" => 42, file_id: "guide.md"}}
  end

  test "passes the materialization actor through to storage" do
    actor = %{person_id: 123}

    assert {:ok, _answer} =
             DiskDocument.materialize(%{"file_id" => "guide.md"}, %{
               node_router: StubNodeRouter,
               actor: actor
             })

    assert_received {:dispatch_actor, :storage, :materialize_document, ^actor}
  end

  test "passes only an explicit trusted permission bypass through to storage" do
    assert {:ok, _answer} =
             DiskDocument.materialize(%{"file_id" => "guide.md"}, %{
               node_router: StubNodeRouter,
               skip_permissions: true,
               event_opts: [skip_permissions: false, action: :delete_document]
             })

    assert_received {:dispatch_opts, :storage, :materialize_document, opts}
    assert opts[:skip_permissions] == true
    assert opts[:action] == :materialize_document
  end

  test "accepts shared MIME runtime options for cross-source compatibility" do
    assert {:ok, _answer} =
             DiskDocument.materialize(
               %{"file_id" => "guide.md"},
               %{node_router: StubNodeRouter},
               %{"document_mime_type" => "text/markdown", "export_mime_type" => "text/plain"}
             )

    assert_received {:dispatch, :storage, :materialize_document, %{file_id: "guide.md"}}
  end

  test "rejects atom-key shared MIME runtime options" do
    assert {:error, :invalid_materialization_options} =
             DiskDocument.materialize(
               %{"file_id" => "guide.md"},
               %{node_router: StubNodeRouter},
               %{document_mime_type: "text/markdown"}
             )
  end

  test "rejects obsolete encoding runtime option" do
    assert {:error, :invalid_materialization_options} =
             DiskDocument.materialize(
               %{"file_id" => "guide.md"},
               %{node_router: StubNodeRouter},
               %{"encoding" => "base64"}
             )
  end

  test "rejects runtime options that try to override locator identity" do
    assert {:error, :invalid_materialization_options} =
             DiskDocument.materialize(
               %{"file_id" => "guide.md"},
               %{node_router: StubNodeRouter},
               %{"file_id" => "other.md"}
             )
  end

  test "refuses a handle whose source was swapped after signing" do
    assert {:ok, handle} = DiskDocument.issue("archives/hello.md")
    [header, _payload, signature] = String.split(handle, ".")

    forged_payload =
      %{"v" => 1, "type" => "disk_document", "locator" => %{"file_id" => "archives/secret.md"}}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    forged = Enum.join([header, forged_payload, signature], ".")

    assert {:error, :invalid_materialization_handle} = Handle.verify(forged)

    assert {:error, "Materialization failed: :invalid_materialization_handle"} =
             Materialization.materialize(forged, %{node_router: StubNodeRouter})

    refute_received {:dispatch, _destination, _action, _request}
  end

  test "rejects locators without a usable source" do
    assert {:error, :invalid_materialization_locator} =
             DiskDocument.materialize(%{}, %{node_router: StubNodeRouter})

    assert {:error, :invalid_materialization_locator} =
             DiskDocument.materialize(%{"file_id" => "  "}, %{node_router: StubNodeRouter})

    assert {:error, :invalid_materialization_locator} =
             DiskDocument.materialize(%{"file_id" => 42}, %{node_router: StubNodeRouter})
  end

  test "refuses a redemption whose locator, context, or options is not a map" do
    assert {:error, :invalid_materialization_locator} =
             DiskDocument.materialize("disk:archives:guide.md", %{node_router: StubNodeRouter})

    assert {:error, :invalid_materialization_locator} =
             DiskDocument.materialize(%{"file_id" => "guide.md"}, nil)

    assert {:error, :invalid_materialization_locator} =
             DiskDocument.materialize(%{"file_id" => "guide.md"}, %{}, "base64")

    refute_received {:dispatch, _destination, _action, _request}
  end

  test "rejects non-map inputs through the materialization handler callback" do
    valid_locator = %{"file_id" => "guide.md"}
    valid_context = %{node_router: StubNodeRouter}
    valid_options = %{}

    for {locator, context, options} <- [
          {"disk:archives:guide.md", valid_context, valid_options},
          {valid_locator, nil, valid_options},
          {valid_locator, valid_context, "base64"}
        ] do
      assert {:error, :invalid_materialization_locator} =
               DiskDocument.do_materialize(locator, context, options)
    end

    refute_received {:dispatch, _destination, _action, _request}
  end

  test "fails closed when no current disk config can be resolved" do
    assert {:error, :disk_channel_config_not_found} =
             DiskDocument.materialize(%{"file_id" => "disk:missing.md"}, %{})

    refute_received {:dispatch, _destination, _action, _request}
  end

  property "only the signed source reaches storage, whatever else the locator carries" do
    check all(
            file_id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
            smuggled <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
          ) do
      assert {:ok, _answer} =
               DiskDocument.materialize(
                 %{"file_id" => file_id, "action" => smuggled, "volume" => smuggled},
                 %{node_router: StubNodeRouter}
               )

      assert_received {:dispatch, :storage, :materialize_document, request}
      assert request == %{file_id: file_id}
    end
  end
end
