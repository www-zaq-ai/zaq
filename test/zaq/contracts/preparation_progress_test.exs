defmodule Zaq.Contracts.PreparationProgressTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Contracts.PreparationProgress

  property "integer counters remain renderable across JSON persistence" do
    check all(current <- integer(), total <- integer()) do
      payload = %{
        "stage" => "image_to_text",
        "status" => "processing",
        "label" => nil,
        "current" => current,
        "total" => total
      }

      assert PreparationProgress.valid?(payload)
      assert payload |> Jason.encode!() |> Jason.decode!() |> PreparationProgress.valid?()
    end
  end

  property "non-integer counters are rejected" do
    check all(
            field <- member_of(["current", "total"]),
            value <-
              one_of([
                constant(nil),
                boolean(),
                float(),
                string(:alphanumeric),
                constant(%{}),
                list_of(integer())
              ])
          ) do
      refute PreparationProgress.valid?(%{field => value})
    end
  end

  test "accepts partial events and rejects malformed text fields and non-JSON keys" do
    for payload <- [%{}, %{"status" => "started"}, %{"current" => 1}, %{"future" => true}] do
      assert PreparationProgress.valid?(payload)
    end

    for field <- ["stage", "status", "label"], value <- [%{}, [], 6, false] do
      refute PreparationProgress.valid?(%{field => value})
    end

    for payload <- [nil, [], "progress", %{current: 1}, %URI{}] do
      refute PreparationProgress.valid?(payload)
    end
  end
end
