defmodule Zaq.System.LLMConfigTest do
  use ExUnit.Case, async: true

  alias Zaq.System.LLMConfig

  @base_attrs %{
    "credential_id" => "1",
    "model" => "gpt-4o",
    "temperature" => "0.1",
    "top_p" => "0.9",
    "max_context_window" => "5000",
    "distance_threshold" => "1.0"
  }

  test "cosine threshold has an independent inclusive range; L2 threshold is retained" do
    assert %LLMConfig{max_cosine_distance: 0.45, distance_threshold: 1.2} = %LLMConfig{}

    for valid <- ["0", "2"] do
      assert LLMConfig.changeset(%LLMConfig{}, Map.put(@base_attrs, "max_cosine_distance", valid)).valid?
    end

    for invalid <- ["-0.01", "2.01"] do
      refute LLMConfig.changeset(
               %LLMConfig{},
               Map.put(@base_attrs, "max_cosine_distance", invalid)
             ).valid?
    end
  end

  describe "validate_fusion_weight_sum/1" do
    test "adds error when bm25 + vector sum is below 0.1" do
      attrs =
        Map.merge(@base_attrs, %{
          "fusion_bm25_weight" => "0.04",
          "fusion_vector_weight" => "0.05"
        })

      changeset = LLMConfig.changeset(%LLMConfig{}, attrs)

      refute changeset.valid?

      assert %{
               fusion_bm25_weight: ["combined fusion weights must sum to at least 0.1"]
             } = errors_on(changeset)
    end

    test "is valid when bm25 + vector sum equals exactly 0.1" do
      attrs =
        Map.merge(@base_attrs, %{
          "fusion_bm25_weight" => "0.05",
          "fusion_vector_weight" => "0.05"
        })

      changeset = LLMConfig.changeset(%LLMConfig{}, attrs)

      assert changeset.valid?
      assert changeset.errors[:fusion_bm25_weight] == nil
    end

    test "is valid with default weights 0.5 + 0.5" do
      changeset = LLMConfig.changeset(%LLMConfig{}, @base_attrs)

      assert changeset.valid?
      assert changeset.errors[:fusion_bm25_weight] == nil
    end
  end

  # Helper that mirrors Zaq.DataCase.errors_on/1 without requiring DB
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
