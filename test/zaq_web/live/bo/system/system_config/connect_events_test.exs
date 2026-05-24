defmodule ZaqWeb.Live.BO.System.SystemConfig.ConnectEventsTest do
  use ExUnit.Case, async: true

  alias ZaqWeb.Live.BO.System.SystemConfig.ConnectEvents

  test "find_grant/2 returns nil for non-list grants" do
    grants_values = [nil, %{id: 1}, "not-a-list", 123]

    Enum.each(grants_values, fn grants ->
      assert ConnectEvents.find_grant(grants, 1) == nil
    end)
  end

  test "run_grant_action/3 returns :not_found when grant missing" do
    assert ConnectEvents.run_grant_action([], "1", fn _ -> {:ok, :noop} end) == :not_found
  end

  test "run_grant_action/3 returns :not_found and does not invoke action for non-list grants" do
    action_fun = fn _grant ->
      send(self(), :action_invoked)
      {:ok, :done}
    end

    assert ConnectEvents.run_grant_action(nil, 42, action_fun) == :not_found
    refute_receive :action_invoked
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
