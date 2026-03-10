defmodule Zaq.ApplicationTest do
  use ExUnit.Case, async: true

  test "config_change/3 returns :ok" do
    assert :ok = Zaq.Application.config_change(%{}, %{}, [])
  end
end
