defmodule Zaq.Channels.Materializers.DataSourceDocumentCallbackTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.Materializers.DataSourceDocument

  test "do_materialize rejects a non-map locator" do
    assert DataSourceDocument.do_materialize(nil, %{}, %{}) ==
             {:error, :invalid_materialization_locator}
  end

  test "do_materialize rejects a non-map context" do
    assert DataSourceDocument.do_materialize(
             %{"provider" => "google_drive", "file_id" => "f1"},
             nil,
             %{}
           ) == {:error, :invalid_materialization_locator}
  end

  test "do_materialize rejects non-map options" do
    assert DataSourceDocument.do_materialize(
             %{"provider" => "google_drive", "file_id" => "f1"},
             %{},
             []
           ) == {:error, :invalid_materialization_locator}
  end

  test "do_materialize rejects non-map arguments in every position" do
    non_map =
      StreamData.one_of([
        StreamData.constant(nil),
        StreamData.boolean(),
        StreamData.integer(),
        StreamData.binary(max_length: 32),
        StreamData.list_of(StreamData.integer(), max_length: 4),
        StreamData.tuple({StreamData.integer(), StreamData.integer()})
      ])

    check all(value <- non_map, max_runs: 100) do
      assert DataSourceDocument.do_materialize(value, %{}, %{}) ==
               {:error, :invalid_materialization_locator},
             "locator position accepted non-map value #{inspect(value)}"

      assert DataSourceDocument.do_materialize(
               %{"provider" => "google_drive", "file_id" => "f1"},
               value,
               %{}
             ) == {:error, :invalid_materialization_locator},
             "context position accepted non-map value #{inspect(value)}"

      assert DataSourceDocument.do_materialize(
               %{"provider" => "google_drive", "file_id" => "f1"},
               %{},
               value
             ) == {:error, :invalid_materialization_locator},
             "options position accepted non-map value #{inspect(value)}"
    end
  end
end
