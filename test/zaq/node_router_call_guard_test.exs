defmodule Zaq.NodeRouterCallGuardTest do
  use ExUnit.Case, async: true

  @baseline_files MapSet.new([
                    "lib/zaq/engine/conversations.ex",
                    "lib/zaq/ingestion/ingestion.ex",
                    "lib/zaq/people/identity_plug.ex",
                    "lib/zaq_web/live/bo/ai/ingestion_live.ex",
                    "lib/zaq_web/live/bo/communication/chat_live.ex",
                    "lib/zaq_web/live/bo/communication/conversation_detail_live.ex",
                    "lib/zaq_web/live/bo/communication/history_live.ex",
                    "lib/zaq_web/live/bo/conversations_metrics_live.ex",
                    "lib/zaq_web/live/bo/dashboard_live.ex",
                    "lib/zaq_web/live/bo/llm_performance_live.ex",
                    "lib/zaq_web/live/shared_conversation_live.ex"
                  ])

  test "does not introduce new NodeRouter.call usage in lib" do
    files =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(fn path ->
        File.regular?(path) and
          path
          |> File.read!()
          |> String.contains?("NodeRouter.call(")
      end)
      |> MapSet.new()

    extra = MapSet.difference(files, @baseline_files) |> MapSet.to_list() |> Enum.sort()

    assert extra == [],
           "New NodeRouter.call usage detected in: #{Enum.join(extra, ", ")}. Use NodeRouter.dispatch/1 with Zaq.Event."
  end
end
