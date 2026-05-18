defmodule Zaq.NodeRoles do
  @moduledoc """
  Runtime role resolution for multi-node deployments.

  `ROLES` env takes precedence over `:zaq, :roles` config.
  """

  @spec current() :: [atom()]
  def current do
    case System.get_env("ROLES") do
      nil -> Application.get_env(:zaq, :roles, [:all])
      roles_str -> parse(roles_str)
    end
  end

  @spec has_any?([atom()]) :: boolean()
  def has_any?(required_roles) when is_list(required_roles) do
    roles = current()
    :all in roles or Enum.any?(required_roles, &(&1 in roles))
  end

  @spec parse(String.t()) :: [atom()]
  def parse(roles_str) when is_binary(roles_str) do
    roles_str
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.to_atom()))
  end
end
