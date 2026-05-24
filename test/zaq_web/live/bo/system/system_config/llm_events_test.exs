defmodule ZaqWeb.Live.BO.System.SystemConfig.LLMEventsTest do
  use ExUnit.Case, async: true

  alias ZaqWeb.Live.BO.System.SystemConfig.LLMEvents

  test "maybe_update_path/5 updates path when provider changes" do
    params = %{"path" => "/old"}

    updated =
      LLMEvents.maybe_update_path(params, "openai", "anthropic", "gpt-x", fn p, m ->
        "/#{p}/#{m}"
      end)

    assert updated["path"] == "/openai/gpt-x"
  end

  test "adjust_fusion_weights/4 mirrors opposite weight" do
    params = %{"fusion_bm25_weight" => "0.8", "fusion_vector_weight" => "0.2"}

    updated = LLMEvents.adjust_fusion_weights(params, "0.5", "0.5", fn _ -> 0.8 end)
    assert updated["fusion_bm25_weight"] == 0.8
    assert updated["fusion_vector_weight"] == 0.2
  end

  test "resolve_capabilities/6 uses current when unchanged" do
    current = %{json_mode: true}

    result =
      LLMEvents.resolve_capabilities("openai", "gpt-4", "openai", "gpt-4", current, fn _, _ ->
        %{json_mode: false}
      end)

    assert result == current
  end
end
