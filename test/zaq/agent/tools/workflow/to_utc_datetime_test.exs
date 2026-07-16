defmodule Zaq.Agent.Tools.Workflow.ToUtcDateTimeTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Tools.Workflow.ToUtcDateTime

  test "converts an offset datetime to UTC" do
    assert {:ok, %{datetime: "2026-07-15T10:00:00Z"}} =
             ToUtcDateTime.run(%{datetime: "2026-07-15T12:00:00+02:00"}, %{})
  end

  test "converts a UTC naive datetime when timezone is explicit" do
    assert {:ok, %{datetime: "2026-07-15T12:00:00Z"}} =
             ToUtcDateTime.run(%{datetime: "2026-07-15T12:00:00", timezone: "UTC"}, %{})
  end

  test "converts a delay from the provided context time" do
    now = ~U[2026-07-15 12:00:00Z]

    assert {:ok, %{datetime: "2026-07-15T12:15:00Z"}} =
             ToUtcDateTime.run(%{delay: %{amount: 15, unit: "minutes"}}, %{now: now})
  end

  test "documents delay input with an example" do
    delay_doc = ToUtcDateTime.schema() |> Keyword.fetch!(:delay) |> Keyword.fetch!(:doc)

    assert delay_doc =~ "%{amount: 15, unit: \"minutes\"}"
  end

  test "requires exactly one supported input" do
    assert {:error, "provide either datetime or delay"} = ToUtcDateTime.run(%{}, %{})

    assert {:error, "provide only one of datetime or delay"} =
             ToUtcDateTime.run(
               %{datetime: "2026-07-15T12:00:00Z", delay: %{amount: 1, unit: "hour"}},
               %{}
             )
  end

  test "rejects ambiguous local datetime and invalid delay units" do
    assert {:error, "datetime must include a timezone offset or timezone must be UTC"} =
             ToUtcDateTime.run(%{datetime: "2026-07-15T12:00:00"}, %{})

    assert {:error, "delay.unit must be second, minute, hour, or day"} =
             ToUtcDateTime.run(%{delay: %{amount: 1, unit: "fortnight"}}, %{})
  end
end
