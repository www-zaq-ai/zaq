defmodule ZaqWeb.Live.BO.System.SystemConfig.ConnectEventsTest do
  use ExUnit.Case, async: true

  alias ZaqWeb.Live.BO.System.SystemConfig.ConnectEvents

  test "run_grant_action/3 returns :not_found when grant missing" do
    assert ConnectEvents.run_grant_action([], "1", fn _ -> {:ok, :noop} end) == :not_found
  end

  test "run_grant_action/3 executes action and returns tagged ok" do
    grants = [%{id: 3}]

    assert {:ok, %{id: 3}, {:ok, :done}} =
             ConnectEvents.run_grant_action(grants, "3", fn _grant -> {:ok, :done} end)
  end

  test "run_grant_action/3 surfaces error and other responses" do
    grants = [%{id: 4}]

    assert {:error, %{id: 4}, {:error, :bad}} =
             ConnectEvents.run_grant_action(grants, 4, fn _grant -> {:error, :bad} end)

    assert {:other, %{id: 4}, :unexpected} =
             ConnectEvents.run_grant_action(grants, 4, fn _grant -> :unexpected end)
  end
end
