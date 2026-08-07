defmodule Zaq.Agent.Tools.Helpers.ChannelToolTest do
  use Zaq.DataCase, async: true

  alias Zaq.Agent.Tools.Helpers.ChannelTool
  alias Zaq.Contracts.Record
  alias Zaq.Event

  defmodule OkNodeRouter do
    def dispatch(%Event{request: request, opts: opts}) do
      send(self(), {:dispatch, opts[:action], request})
      %{Event.new(%{}, :channels) | response: {:ok, %{record: %{"id" => "f1"}}}}
    end
  end

  defmodule ErrorNodeRouter do
    def dispatch(%Event{}), do: %{Event.new(%{}, :channels) | response: {:error, :timeout}}
  end

  defmodule UnexpectedNodeRouter do
    def dispatch(%Event{}), do: %{Event.new(%{}, :channels) | response: :weird_response}
  end

  test "dispatch/5 returns ok payload by default" do
    request = %{provider: "google_drive", params: %{"file_id" => "f1"}}

    assert {:ok, %{record: %{"id" => "f1"}}} =
             ChannelTool.dispatch(
               :data_source_get_file,
               request,
               %{node_router: OkNodeRouter},
               "Data source document request failed"
             )

    assert_received {:dispatch, :data_source_get_file, ^request}
  end

  test "dispatch/5 applies custom on_ok formatter" do
    request = %{provider: "google_drive", params: %{"query" => "invoice"}}

    assert {:ok, %{record: %{"id" => "f1"}, count: 1}} =
             ChannelTool.dispatch(
               :data_source_search_files,
               request,
               %{node_router: OkNodeRouter},
               "Data source document search failed",
               fn payload -> {:ok, Map.put(payload, :count, 1)} end
             )
  end

  test "dispatch/5 formats error tuples" do
    assert {:error, "Data source document request failed: :timeout"} =
             ChannelTool.dispatch(
               :data_source_get_file,
               %{provider: "google_drive", params: %{"file_id" => "f1"}},
               %{node_router: ErrorNodeRouter},
               "Data source document request failed"
             )
  end

  test "dispatch/5 formats unexpected responses" do
    assert {:error, "Unexpected data source response: :weird_response"} =
             ChannelTool.dispatch(
               :data_source_get_file,
               %{provider: "google_drive", params: %{"file_id" => "f1"}},
               %{node_router: UnexpectedNodeRouter},
               "Data source document request failed"
             )
  end

  test "put_if_present/3 only adds non-nil values" do
    assert %{"file_id" => "f1", "config_id" => "7"} =
             %{"file_id" => "f1"}
             |> ChannelTool.put_if_present("config_id", "7")
             |> ChannelTool.put_if_present("path", nil)
  end

  test "put_many_if_present/2 adds only present values" do
    assert %{"file_id" => "f1", "config_id" => "7", "range" => "Sheet1!A1"} =
             %{"file_id" => "f1"}
             |> ChannelTool.put_many_if_present([
               {"config_id", "7"},
               {"range", "Sheet1!A1"},
               {"path", nil}
             ])
  end

  test "merge_optional/3 only merges keys the params carry" do
    params = %{document_mime_type: "application/pdf", export_mime_type: nil}

    assert ChannelTool.merge_optional(%{"file_id" => "f1"}, params, [
             :document_mime_type,
             :export_mime_type,
             :config_id
           ]) == %{"file_id" => "f1", "document_mime_type" => "application/pdf"}
  end

  test "wrap_request/2 nests the params under the provider" do
    assert ChannelTool.wrap_request(%{"file_id" => "f1"}, "disk") ==
             %{provider: "disk", params: %{"file_id" => "f1"}}
  end

  # ── the second hop ──────────────────────────────────────────────────────────

  describe "materialize/2" do
    defmodule MaterializingRouter do
      @moduledoc false

      def dispatch(%Event{request: request, opts: opts} = event) do
        send(self(), {:materialize, event.next_hop.destination, opts[:action], request})

        %{
          event
          | response:
              {:ok,
               %{
                 record: %Record{
                   id: request.file_id,
                   kind: :file,
                   content: "# materialized",
                   attributes: %{"encoding" => "base64"}
                 }
               }}
        }
      end
    end

    defmodule MaterializeErrorRouter do
      @moduledoc false

      def dispatch(%Event{} = event), do: %{event | response: {:error, :enoent}}
    end

    defmodule MaterializeShapeRouter do
      @moduledoc false

      def dispatch(%Event{} = event), do: %{event | response: {:ok, %{status: "ok"}}}
    end

    defp unmaterialized(id \\ "42") do
      %Record{
        id: id,
        kind: :file,
        content: nil,
        materializing_event:
          Event.new(%{file_id: id}, :ingestion, opts: [action: :materialize_record])
      }
    end

    test "dispatches the event and returns the record with content" do
      payload = %{record: unmaterialized(), extra: :kept}

      assert {:ok, %{record: %Record{content: "# materialized"} = record, extra: :kept}} =
               ChannelTool.materialize(payload, %{node_router: MaterializingRouter}, "Failed")

      assert record.attributes["encoding"] == "base64"
      assert_received {:materialize, :ingestion, :materialize_record, %{file_id: "42"}}
    end

    test "passes a record that already has content through untouched" do
      payload = %{record: %{unmaterialized() | content: "already here"}}

      assert {:ok, ^payload} =
               ChannelTool.materialize(payload, %{node_router: MaterializingRouter}, "Failed")

      refute_received {:materialize, _destination, _action, _request}
    end

    test "passes a record with no event through untouched" do
      payload = %{record: %{unmaterialized() | materializing_event: nil}}

      assert {:ok, ^payload} =
               ChannelTool.materialize(payload, %{node_router: MaterializingRouter}, "Failed")

      refute_received {:materialize, _destination, _action, _request}
    end

    test "passes a payload that is not a record through untouched" do
      payload = %{status: "ok", bytes: 12}

      assert {:ok, ^payload} =
               ChannelTool.materialize(payload, %{node_router: MaterializingRouter}, "Failed")

      refute_received {:materialize, _destination, _action, _request}
    end

    test "passes a plain-map record through untouched" do
      payload = %{record: %{"id" => "42", "content" => nil}}

      assert {:ok, ^payload} =
               ChannelTool.materialize(payload, %{node_router: MaterializingRouter}, "Failed")
    end

    test "formats a second-hop error with the same prefix as the first" do
      payload = %{record: unmaterialized()}

      assert {:error, "Download failed: :enoent"} =
               ChannelTool.materialize(
                 payload,
                 %{node_router: MaterializeErrorRouter},
                 "Download failed"
               )
    end

    test "reports an unexpected second-hop shape rather than crashing" do
      payload = %{record: unmaterialized()}

      assert {:error, message} =
               ChannelTool.materialize(
                 payload,
                 %{node_router: MaterializeShapeRouter},
                 "Download failed"
               )

      assert message =~ "Download failed: unexpected materialize response"
      assert message =~ ~s(%{status: "ok"})
    end
  end
end
