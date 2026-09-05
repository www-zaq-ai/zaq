defmodule Zaq.Channels.Materializers.CommunicationMediaCallbackTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.Materializers.CommunicationMedia

  test "do_materialize rejects each non-map argument independently" do
    locator = %{
      "provider" => "mattermost",
      "reference" => "file-1",
      "source_author_id" => "author-1"
    }

    context = %{actor: %{id: "author-1"}}
    options = %{}

    for invalid <- [nil, false, 0, 1.5, "", "invalid", [], [actor: %{id: "author-1"}], {:invalid}] do
      assert CommunicationMedia.do_materialize(invalid, context, options) ==
               {:error, :invalid_materialization_locator},
             "locator argument accepted non-map #{inspect(invalid)}"

      assert CommunicationMedia.do_materialize(locator, invalid, options) ==
               {:error, :invalid_materialization_locator},
             "context argument accepted non-map #{inspect(invalid)}"

      assert CommunicationMedia.do_materialize(locator, context, invalid) ==
               {:error, :invalid_materialization_locator},
             "options argument accepted non-map #{inspect(invalid)}"
    end
  end

  property "do_materialize rejects non-map values in every argument position" do
    non_map = StreamData.term() |> StreamData.filter(&(not is_map(&1)))

    check all(invalid <- non_map, max_runs: 100) do
      locator = %{
        "provider" => "mattermost",
        "reference" => "file-1",
        "source_author_id" => "author-1"
      }

      context = %{actor: %{id: "author-1"}}
      options = %{}

      assert CommunicationMedia.do_materialize(invalid, context, options) ==
               {:error, :invalid_materialization_locator},
             "locator argument accepted non-map #{inspect(invalid)}"

      assert CommunicationMedia.do_materialize(locator, invalid, options) ==
               {:error, :invalid_materialization_locator},
             "context argument accepted non-map #{inspect(invalid)}"

      assert CommunicationMedia.do_materialize(locator, context, invalid) ==
               {:error, :invalid_materialization_locator},
             "options argument accepted non-map #{inspect(invalid)}"
    end
  end
end
