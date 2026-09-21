defmodule ZaqWeb.Components.DesignSystem.StatusPillTest do
  use ExUnit.Case, async: true

  alias ZaqWeb.Components.DesignSystem.StatusPill

  describe "status_pill_classes/1" do
    test "skipped status uses the elevated pill style" do
      assert StatusPill.status_pill_classes("skipped") == [
               "zaq-pill",
               "zaq-text-caption",
               "zaq-pill--elevated"
             ]
    end
  end

  describe "tone_pill_classes/1" do
    test "accent tone uses the accent pill style" do
      assert StatusPill.tone_pill_classes(:accent) == [
               "zaq-pill",
               "zaq-text-caption",
               "zaq-pill--accent"
             ]
    end

    test "warning tone uses the warning pill style" do
      assert StatusPill.tone_pill_classes(:warning) == [
               "zaq-pill",
               "zaq-text-caption",
               "zaq-pill--warning"
             ]
    end
  end
end
