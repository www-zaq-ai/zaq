defmodule Zaq.Ingestion.Materializers.DiskDocumentTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Event
  alias Zaq.Ingestion.Materializers.DiskDocument
  alias Zaq.Materialization
  alias Zaq.Materialization.Handle

  defmodule StubNodeRouter do
    def dispatch(%Event{request: request, opts: opts} = event) do
      send(self(), {:dispatch, event.next_hop.destination, opts[:action], request})
      %{event | response: {:ok, %{content: "# guide", encoding: nil}}}
    end
  end

  test "issues disk document handles naming the volume source" do
    assert {:ok, handle} = DiskDocument.issue("disk:archives:loose.md")

    assert {:ok, %{type: "disk_document", locator: locator}} = Handle.verify(handle)
    assert locator == %{"file_id" => "disk:archives:loose.md"}
  end

  test "refuses to issue a handle for anything but a source string" do
    assert {:error, :invalid_materialization_locator} = DiskDocument.issue(nil)
  end

  test "materializes through the fixed Ingestion materialize action" do
    assert {:ok, %{content: "# guide", encoding: nil}} =
             DiskDocument.materialize(%{"file_id" => "guide.md"}, %{node_router: StubNodeRouter})

    assert_received {:dispatch, :ingestion, :materialize_record, %{file_id: "guide.md"}}
  end

  test "passes the encoding runtime option through to ingestion" do
    assert {:ok, _answer} =
             DiskDocument.materialize(
               %{"file_id" => "guide.md"},
               %{node_router: StubNodeRouter},
               %{"encoding" => "base64"}
             )

    assert_received {:dispatch, :ingestion, :materialize_record,
                     %{file_id: "guide.md", encoding: "base64"}}
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

  property "only the signed source reaches ingestion, whatever else the locator carries" do
    check all(
            file_id <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
            smuggled <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
          ) do
      assert {:ok, _answer} =
               DiskDocument.materialize(
                 %{"file_id" => file_id, "action" => smuggled, "volume" => smuggled},
                 %{node_router: StubNodeRouter}
               )

      assert_received {:dispatch, :ingestion, :materialize_record, request}
      assert request == %{file_id: file_id}
    end
  end
end
