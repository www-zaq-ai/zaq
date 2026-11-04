defmodule ZaqWeb.Live.BO.System.SystemConfig.RetrievalEvents do
  @moduledoc """
  Helpers for retrieval tuning event transformations.
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
end
