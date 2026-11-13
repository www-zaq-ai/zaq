defmodule Zaq.Ingestion.PreparationOutcomeTest do
  use ExUnit.Case, async: true

  alias Zaq.Ingestion.PreparationOutcome

  describe "classify/1" do
    test "non-empty payloads always succeed regardless of image_to_text" do
      for image_to_text <- [:skipped, :completed, nil] do
        assert :ok =
                 PreparationOutcome.classify(%{
                   payloads_empty?: false,
                   image_to_text: image_to_text
                 })
      end
    end

    test "empty + skipped maps to image_extraction_skipped" do
      assert {:error, :image_extraction_skipped} =
               PreparationOutcome.classify(%{
                 payloads_empty?: true,
                 image_to_text: :skipped
               })
    end

    test "empty + completed maps to no_searchable_content" do
      assert {:error, :no_searchable_content} =
               PreparationOutcome.classify(%{
                 payloads_empty?: true,
                 image_to_text: :completed
               })
    end

    test "empty + missing outcome maps to no_searchable_content" do
      assert {:error, :no_searchable_content} =
               PreparationOutcome.classify(%{payloads_empty?: true})

      assert {:error, :no_searchable_content} =
               PreparationOutcome.classify(%{
                 payloads_empty?: true,
                 image_to_text: nil
               })
    end
  end
end
