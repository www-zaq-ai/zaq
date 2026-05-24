defmodule ZaqWeb.Live.BO.System.SystemConfig.LLMEvents do
  @moduledoc """
  Helpers for LLM config event transformations.
  """

  def adjust_fusion_weights(params, prev_bm25, prev_vector, clamp_weight_fun)
      when is_map(params) and is_function(clamp_weight_fun, 1) do
    cond do
      params["fusion_bm25_weight"] != prev_bm25 ->
        w = clamp_weight_fun.(params["fusion_bm25_weight"])

        params
        |> Map.put("fusion_bm25_weight", w)
        |> Map.put("fusion_vector_weight", Float.round(1.0 - w, 2))

      params["fusion_vector_weight"] != prev_vector ->
        w = clamp_weight_fun.(params["fusion_vector_weight"])

        params
        |> Map.put("fusion_vector_weight", w)
        |> Map.put("fusion_bm25_weight", Float.round(1.0 - w, 2))

      true ->
        params
    end
  end

  def adjust_fusion_weights(params, _prev_bm25, _prev_vector, _clamp_weight_fun), do: params

  def maybe_update_path(params, provider_id, previous_provider, model_id, provider_path_fun)
      when is_map(params) and is_function(provider_path_fun, 2) do
    if provider_id != previous_provider do
      Map.put(params, "path", provider_path_fun.(provider_id, model_id))
    else
      params
    end
  end

  def maybe_update_path(params, _provider_id, _previous_provider, _model_id, _provider_path_fun),
    do: params

  def resolve_capabilities(
        provider_id,
        model_id,
        previous_provider,
        previous_model,
        current_caps,
        caps_fun
      )
      when is_function(caps_fun, 2) do
    if provider_id != previous_provider or model_id != previous_model do
      caps_fun.(provider_id, model_id)
    else
      current_caps
    end
  end
end
