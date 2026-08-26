defmodule Zaq.Ingestion.ApiTest do
  use Zaq.DataCase, async: true

  alias Zaq.Event
  alias Zaq.Ingestion.Api

  defp handle(request, action) do
    request
    |> Event.new(:ingestion, opts: [action: action])
    |> Api.handle_event(action, nil)
    |> Map.fetch!(:response)
  end

  test "delegates invoke to shared helper" do
    event = Event.new(%{module: String, function: :upcase, args: ["hi"]}, :ingestion)
    result = Api.handle_event(event, :invoke, nil)

    assert result.response == "HI"
  end

  test "returns unsupported action" do
    event = Event.new(%{module: String, function: :upcase, args: ["hi"]}, :ingestion)
    result = Api.handle_event(event, :unknown, nil)

    assert result.response == {:error, {:unsupported_action, :unknown}}
  end

  describe "retired storage actions" do
    test "document CRUD and volume actions are no longer served by ingestion" do
      actions = [
        :describe_document,
        :list_documents,
        :materialize_document,
        :persist_document,
        :update_document,
        :delete_document,
        :list_document_grants,
        :search_documents,
        :volume_stats
      ]

      for action <- actions do
        assert handle(%{}, action) == {:error, {:unsupported_action, action}}
      end
    end

    test "the retired :materialize_record action fails loudly rather than silently" do
      assert handle(%{file_id: "archives/guide.md"}, :materialize_record) ==
               {:error, {:unsupported_action, :materialize_record}}
    end
  end
end
