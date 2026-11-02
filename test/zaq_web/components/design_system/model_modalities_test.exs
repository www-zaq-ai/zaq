defmodule ZaqWeb.Components.DesignSystem.ModelModalitiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias LLMDB.Generated.ValidModalities
  alias ZaqWeb.Components.DesignSystem.ModelModalities

  test "renders input icons, direction arrow and output icons with accessible tooltips" do
    html = render_modalities(%{input: [:image, :text], output: [:text]})

    assert Regex.scan(~r/aria-label="((?:Input|Output): [^"]+)"/, html, capture: :all_but_first)
           |> List.flatten() == [
             "Input: Text",
             "Input: Image",
             "Output: Text"
           ]

    assert length(Regex.scan(~r/role="tooltip"\s+popover="manual"/, html)) == 3
    assert length(Regex.scan(~r/hero-arrow-right/, html)) == 1
    assert length(Regex.scan(~r/type="button"/, html)) == 3

    for [_, tooltip_id] <- Regex.scan(~r/aria-describedby="([^"]+)"/, html) do
      assert html =~ ~s(id="#{tooltip_id}")
    end
  end

  test "shows unknown independently for missing and empty directions" do
    assert render_modalities(nil) =~ "Input: Unknown"
    assert render_modalities(%{input: [], output: [:text]}) =~ "Input: Unknown"
    html = render_modalities(%{input: [:image]})
    assert html =~ "Input: Image"
    assert html =~ "Output: Unknown"
  end

  test "an unselected model has a prompt rather than a capability claim" do
    html = render_component(&ModelModalities.model_modalities/1, id: "empty", selected: false)
    assert html =~ "Select a model to view modalities"
    refute html =~ "hero-arrow-right"
  end

  test "every catalog modality has an icon and readable label, with an extensible fallback" do
    modalities = ValidModalities.list()
    html = render_modalities(%{input: modalities ++ [:future_modality], output: modalities})
    assert html =~ "Input: Future modality"
    refute html =~ "Unknown"
    assert length(Regex.scan(~r/<button/, html)) == length(modalities) * 2 + 1
  end

  property "ordering is stable and duplicates never add icons" do
    check all(input <- list_of(member_of([:image, :text, :pdf, :audio, :video]), max_length: 25)) do
      assert render_modalities(%{input: input, output: [:text]}) ==
               render_modalities(%{
                 input: input |> Enum.reverse() |> Enum.uniq(),
                 output: [:text]
               })
    end
  end

  defp render_modalities(modalities) do
    render_component(&ModelModalities.model_modalities/1,
      id: "test-modalities",
      modalities: modalities
    )
  end
end
