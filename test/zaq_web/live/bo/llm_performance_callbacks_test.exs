defmodule ZaqWeb.Live.BO.LLMPerformanceCallbacksTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias Phoenix.Component
  alias Phoenix.LiveView.Socket
  alias ZaqWeb.Live.BO.LLMPerformanceLive

  test "invalid usage sort events preserve the disconnected socket" do
    socket = callback_socket()

    for params <- [
          %{},
          %{"sort" => "tokens"},
          %{"ranking" => "models"},
          %{"ranking" => "agents", "sort" => "tokens"},
          %{"ranking" => "models", "sort" => "invalid"},
          %{"ranking" => nil, "sort" => nil}
        ] do
      assert {:noreply, ^socket} =
               LLMPerformanceLive.handle_event("set_usage_sort", params, socket)
    end
  end

  property "invalid JSON-compatible usage sort maps preserve every selection" do
    check all(params <- invalid_usage_sort_params(), max_runs: 100) do
      socket = callback_socket()

      assert {:noreply, ^socket} =
               LLMPerformanceLive.handle_event("set_usage_sort", params, socket)
    end
  end

  test "usage table renders person labels without model fields" do
    html =
      render_component(&LLMPerformanceLive.usage_table/1,
        id: "people",
        entity: :person,
        rows: [%{name: "Ada Example", total_tokens: 42, total_calls: 3}]
      )

    document = LazyHTML.from_fragment(html)

    assert document
           |> LazyHTML.query("#people thead th")
           |> Enum.map(&LazyHTML.text/1)
           |> Enum.map(&String.trim/1) == [
             "Person",
             "Total tokens",
             "Total calls"
           ]

    rows = LazyHTML.query(document, "#people tbody tr")
    assert Enum.count(rows) == 1

    assert document
           |> LazyHTML.query("#people tbody tr td")
           |> Enum.map(&LazyHTML.text/1)
           |> Enum.map(&String.trim/1) == ["Ada Example", "42", "3"]
  end

  defp callback_socket do
    %Socket{}
    |> Component.assign(:range, "30d")
    |> Component.assign(:model_sort, "calls")
    |> Component.assign(:people_sort, "tokens")
    |> Component.assign(:selected_agent_id, "10")
  end

  defp invalid_usage_sort_params do
    value =
      StreamData.one_of([
        StreamData.string(:alphanumeric, max_length: 12),
        StreamData.integer(-10..10),
        StreamData.boolean(),
        StreamData.constant(nil)
      ])

    StreamData.optional_map(%{
      "ranking" => value,
      "sort" => value,
      "extra" => value
    })
    |> StreamData.filter(&(not valid_usage_sort_params?(&1)))
  end

  defp valid_usage_sort_params?(params) do
    Map.get(params, "ranking") in ["models", "people"] and
      Map.get(params, "sort") in ["tokens", "calls"]
  end
end
