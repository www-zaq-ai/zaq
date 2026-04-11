defmodule Zaq.ApplicationTest do
  use ExUnit.Case, async: false

  setup do
    prev_roles = System.get_env("ROLES")
    prev_app_roles = Application.get_env(:zaq, :roles)
    prev_e2e_routes = Application.get_env(:zaq, :e2e_routes)
    prev_e2e = Application.get_env(:zaq, :e2e)

    on_exit(fn ->
      if prev_roles do
        System.put_env("ROLES", prev_roles)
      else
        System.delete_env("ROLES")
      end

      Application.put_env(:zaq, :roles, prev_app_roles)
      Application.put_env(:zaq, :e2e_routes, prev_e2e_routes)
      Application.put_env(:zaq, :e2e, prev_e2e)
    end)

    :ok
  end

  test "config_change/3 returns :ok" do
    assert :ok = Zaq.Application.config_change(%{}, %{}, [])
  end

  test "prep_stop/1 returns same state" do
    state = %{foo: :bar}
    assert Zaq.Application.prep_stop(state) == state
  end

  test "start/2 handles ROLES from app config when env var is missing" do
    System.delete_env("ROLES")
    Application.put_env(:zaq, :roles, [:agent])
    Application.put_env(:zaq, :e2e_routes, false)
    Application.put_env(:zaq, :e2e, false)

    assert {:error, {:already_started, _pid}} = Zaq.Application.start(:normal, [])
  end

  test "start/2 parses ROLES env and handles e2e flags enabled" do
    System.put_env("ROLES", "agent, channels")
    Application.put_env(:zaq, :roles, [:bo])
    Application.put_env(:zaq, :e2e_routes, true)
    Application.put_env(:zaq, :e2e, true)

    assert {:error, {:already_started, _pid}} = Zaq.Application.start(:normal, [])
  end
end
