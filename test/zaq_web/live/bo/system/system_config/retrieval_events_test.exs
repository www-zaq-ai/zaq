defmodule ZaqWeb.Live.BO.System.SystemConfig.RetrievalEventsTest do
  use ExUnit.Case, async: true

  alias ZaqWeb.Live.BO.System.SystemConfig.RetrievalEvents

  test "adjusting either fusion weight mirrors the opposite weight" do
    assert %{"fusion_bm25_weight" => 0.8, "fusion_vector_weight" => 0.2} =
             RetrievalEvents.adjust_fusion_weights(
               %{"fusion_bm25_weight" => "0.8", "fusion_vector_weight" => "0.5"},
               "0.5",
               "0.5",
               fn _ -> 0.8 end
             )

    assert %{"fusion_bm25_weight" => 0.2, "fusion_vector_weight" => 0.8} =
             RetrievalEvents.adjust_fusion_weights(
               %{"fusion_bm25_weight" => "0.5", "fusion_vector_weight" => "0.8"},
               "0.5",
               "0.5",
               fn _ -> 0.8 end
             )
  end

  test "unchanged or invalid inputs remain unchanged" do
    params = %{"fusion_bm25_weight" => "0.5", "fusion_vector_weight" => "0.5"}
    assert RetrievalEvents.adjust_fusion_weights(params, "0.5", "0.5", & &1) == params
    assert RetrievalEvents.adjust_fusion_weights(params, "0.5", "0.5", :invalid) == params
    assert RetrievalEvents.adjust_fusion_weights("invalid", "0.5", "0.5", & &1) == "invalid"
  end
end
