defmodule Zaq.MaterializationTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Event
  alias Zaq.Materialization

  defmodule OkNodeRouter do
    def dispatch(%Event{request: %{provider: "google_drive", params: params}, opts: opts} = event) do
      send(self(), {:dispatch, event.next_hop.destination, opts[:action], params})
      %{event | response: {:ok, %{content: "hello", attributes: %{"encoding" => "base64"}}}}
    end
  end

  defmodule TopLevelEncodingNodeRouter do
    def dispatch(%Event{} = event) do
      %{event | response: {:ok, %{content: "aGVsbG8=", encoding: "base64"}}}
    end
  end

  defmodule PlainNodeRouter do
    def dispatch(%Event{} = event), do: %{event | response: {:ok, %{content: "plain text"}}}
  end

  defmodule StringPayloadNodeRouter do
    def dispatch(%Event{} = event),
      do: %{event | response: {:ok, %{"content" => "aGVsbG8=", "encoding" => "base64"}}}
  end

  defmodule AtomRecordNodeRouter do
    def dispatch(%Event{} = event),
      do: %{
        event
        | response:
            {:ok,
             %{
               record: %Record{
                 id: "downloaded",
                 kind: :file,
                 content: "downloaded",
                 attributes: %{"encoding" => "base64"}
               }
             }}
      }
  end

  defmodule StringRecordNodeRouter do
    def dispatch(%Event{} = event),
      do: %{event | response: {:ok, %{"record" => Process.get(:materialization_record_payload)}}}
  end

  defmodule ChainNodeRouter do
    def dispatch(%Event{} = event) do
      file_id = get_in(event.request, [:params, "file_id"])

      %{
        event
        | response: {:ok, %{record: Map.fetch!(Process.get(:materialization_chain), file_id)}}
      }
    end
  end

  defmodule ErrorNodeRouter do
    def dispatch(%Event{} = event), do: %{event | response: {:error, :timeout}}
  end

  defmodule StringErrorNodeRouter do
    def dispatch(%Event{} = event),
      do: %{event | response: {:error, "upstream unavailable"}}
  end

  defmodule OptionNodeRouter do
    def dispatch(%Event{request: %{params: params}} = event) do
      send(self(), {:option_params, params})
      %{event | response: {:ok, %{content: "downloaded"}}}
    end
  end

  defmodule UnexpectedNodeRouter do
    def dispatch(%Event{} = event), do: %{event | response: {:ok, %{bytes: "hello"}}}
  end

  test "materializes a handle through an allowlisted handler" do
    assert {:ok, handle} =
             Materialization.issue("data_source_document", %{
               "provider" => "google_drive",
               "file_id" => "f1"
             })

    assert {:ok, %{record: %Record{} = record}} =
             Materialization.materialize(handle, %{node_router: OkNodeRouter}, "failed")

    assert record.content == "hello"
    assert record.attributes["encoding"] == "base64"
    assert_received {:dispatch, :channels, :data_source_download_document, %{"file_id" => "f1"}}
  end

  test "copies top-level encoding onto materialized record attributes" do
    assert {:ok, handle} =
             Materialization.issue("data_source_document", %{
               "provider" => "google_drive",
               "file_id" => "f1"
             })

    assert {:ok, %{record: %Record{} = record}} =
             Materialization.materialize(
               handle,
               %{node_router: TopLevelEncodingNodeRouter},
               "failed"
             )

    assert record.content == "aGVsbG8="
    assert record.attributes["encoding"] == "base64"
  end

  test "uses the injected router for plain content without encoding" do
    assert {:ok, handle} = issue_handle("f1")

    assert {:ok, %{record: %Record{content: "plain text"} = record}} =
             Materialization.materialize(handle, %{node_router: PlainNodeRouter})

    refute Map.has_key?(record.attributes, "encoding")
  end

  test "normalizes string-keyed content payloads" do
    assert {:ok, handle} = issue_handle("f1")

    assert {:ok, %{record: %Record{id: "materialized", kind: :file} = record}} =
             Materialization.materialize(handle, %{node_router: StringPayloadNodeRouter})

    assert record.content == "aGVsbG8="
    assert record.attributes == %{"encoding" => "base64"}
  end

  test "formats invalid handles and unknown materializer types" do
    assert {:error, "Materialization failed: :invalid_materialization_handle"} =
             Materialization.materialize("not-a-real-handle")

    assert {:error, "failed: :invalid_materialization_handle"} =
             Materialization.materialize("not-a-real-handle", %{}, "failed")

    assert {:ok, handle} = Materialization.issue("unknown_materializer", %{})

    assert {:error, "failed: {:unknown_materializer, \"unknown_materializer\"}"} =
             Materialization.materialize(handle, %{}, "failed")
  end

  test "merges an atom-keyed nested record and clears its handle" do
    assert {:ok, nested_handle} = issue_handle("nested")
    assert {:ok, outer_handle} = issue_handle("outer")

    Process.put(:materialization_chain, %{
      "outer" => %Record{
        id: "outer",
        kind: :file,
        content: nil,
        attributes: %{"source" => "original"},
        materialization_handle: nested_handle
      },
      "nested" => %Record{
        id: "nested",
        kind: :file,
        content: "downloaded",
        attributes: %{"encoding" => "base64"}
      }
    })

    assert {:ok, %{record: record}} =
             Materialization.materialize(outer_handle, %{node_router: ChainNodeRouter})

    assert record.content == "downloaded"
    assert record.materialization_handle == nil
    assert record.attributes == %{"source" => "original", "encoding" => "base64"}
  end

  test "defaults attributes to an empty map when nested records have no encoding" do
    nested_handle = issue_handle!("nested")
    outer_handle = issue_handle!("outer")

    Process.put(:materialization_chain, %{
      "outer" => %Record{
        id: "outer",
        kind: :file,
        content: nil,
        attributes: nil,
        materialization_handle: nested_handle
      },
      "nested" => %Record{
        id: "nested",
        kind: :file,
        content: "plain text",
        attributes: nil
      }
    })

    assert {:ok, %{record: %Record{} = record}} =
             Materialization.materialize(outer_handle, %{node_router: ChainNodeRouter})

    assert record.content == "plain text"
    assert record.attributes == %{}
    assert record.materialization_handle == nil
  end

  test "normalizes string-keyed records and binary kinds" do
    for {kind, expected_kind, attributes} <- [
          {"file", :file, nil},
          {"folder", :folder, nil},
          {"permission", :permission, %{}},
          {"spreadsheet", :spreadsheet, nil}
        ] do
      {:ok, record} =
        %Record{id: "f1", kind: kind, content: "x", attributes: attributes}
        |> Provenance.seal(%{"provider" => "disk", "config_id" => "1"})

      payload = record |> Jason.encode!() |> Jason.decode!()
      Process.put(:materialization_record_payload, payload)

      assert {:ok, %{record: %Record{kind: ^expected_kind, content: "x", attributes: %{}}}} =
               Materialization.materialize(issue_handle!("f1"), %{
                 node_router: StringRecordNodeRouter
               })
    end
  end

  test "returns an error when nested materialization depth is exceeded" do
    handles = Enum.map(["f1", "f2", "f3", "f4"], &issue_handle!/1)
    [h1, h2, h3, h4] = handles

    Process.put(:materialization_chain, %{
      "f1" => %Record{id: "f1", kind: :file, content: nil, materialization_handle: h2},
      "f2" => %Record{id: "f2", kind: :file, content: nil, materialization_handle: h3},
      "f3" => %Record{id: "f3", kind: :file, content: nil, materialization_handle: h4},
      "f4" => %Record{id: "f4", kind: :file, content: "done"}
    })

    assert {:error, "failed: materialization depth exceeded"} =
             Materialization.materialize(h1, %{node_router: ChainNodeRouter}, "failed")
  end

  test "clears a handle from a directly materialized record" do
    assert {:ok, handle} = issue_handle("f1")

    Process.put(:materialization_record_payload, %Record{
      id: "done",
      kind: :file,
      content: "done",
      materialization_handle: handle
    })

    assert {:ok, %{record: %Record{content: "done", materialization_handle: nil}}} =
             Materialization.materialize(handle, %{node_router: StringRecordNodeRouter})
  end

  test "formats handler and response errors" do
    assert {:ok, handle} =
             Materialization.issue("data_source_document", %{
               "provider" => "google_drive",
               "file_id" => "f1"
             })

    assert {:error, "failed: :timeout"} =
             Materialization.materialize(handle, %{node_router: ErrorNodeRouter}, "failed")

    assert {:error, "failed: unexpected materialize response %{bytes: \"hello\"}"} =
             Materialization.materialize(handle, %{node_router: UnexpectedNodeRouter}, "failed")
  end

  test "preserves binary handler error messages without inspection quotes" do
    handle = issue_handle!("f1")

    result =
      Materialization.materialize(
        handle,
        %{node_router: StringErrorNodeRouter},
        "failed"
      )

    assert {:error, "failed: upstream unavailable"} = result
  end

  test "normalizes declared atom-keyed runtime options before handler dispatch" do
    assert {:ok, _record} =
             Materialization.materialize(
               issue_handle!("f1"),
               %{node_router: OptionNodeRouter},
               "failed",
               %{document_mime_type: "application/pdf", export_mime_type: "text/plain"}
             )

    assert_received {:option_params,
                     %{
                       "file_id" => "f1",
                       "document_mime_type" => "application/pdf",
                       "export_mime_type" => "text/plain"
                     }}
  end

  test "does not generate absent runtime option keys before handler dispatch" do
    assert {:ok, _record} =
             Materialization.materialize(
               issue_handle!("f1"),
               %{node_router: OptionNodeRouter},
               "failed"
             )

    assert_received {:option_params, %{"file_id" => "f1"} = params}
    refute Map.has_key?(params, "document_mime_type")
    refute Map.has_key?(params, "export_mime_type")
  end

  test "rejects duplicate runtime option spellings before dispatch" do
    assert {:error, "failed: :invalid_materialization_options"} =
             Materialization.materialize(
               issue_handle!("f1"),
               %{node_router: OptionNodeRouter},
               "failed",
               %{"document_mime_type" => "application/pdf", document_mime_type: "text/plain"}
             )

    refute_received {:option_params, _params}
  end

  property "rejects undeclared runtime options before dispatch" do
    check all(suffix <- StreamData.string(:alphanumeric, min_length: 1, max_length: 20)) do
      key = "unsupported_#{suffix}"

      assert {:error, "failed: :invalid_materialization_options"} =
               Materialization.materialize(
                 issue_handle!("f1"),
                 %{node_router: OptionNodeRouter},
                 "failed",
                 %{key => "value"}
               )

      refute_received {:option_params, _params}
    end
  end

  defp issue_handle(file_id) do
    Materialization.issue("data_source_document", %{
      "provider" => "google_drive",
      "file_id" => file_id
    })
  end

  defp issue_handle!(file_id) do
    assert {:ok, handle} = issue_handle(file_id)
    handle
  end
end
